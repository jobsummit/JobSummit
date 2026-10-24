"""One discovery run for GitHub Actions (no server needed).

    python scripts/run_pipeline.py --out ../publish

crawl due sources -> open aggregator detail pages -> read new PDFs with Gemini
-> prune old rows -> write jobs.json, notices.json and status.json into --out.

The database is a throwaway Postgres on the runner, restored from (and dumped
back to) the `data` branch by .github/workflows/data-pipeline.yml. Without
GEMINI_API_KEY the run still crawls and publishes; PDFs wait for a later run.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys
import time
from collections.abc import Awaitable
from datetime import UTC, datetime, timedelta
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))

from sqlalchemy import delete, exists, func, or_, select, text, update  # noqa: E402
from sqlalchemy.orm import aliased  # noqa: E402

import app.models  # noqa: E402,F401  (registers tables)
from app.core.config import get_settings  # noqa: E402
from app.db.base import Base  # noqa: E402
from app.db.session import SessionLocal, engine  # noqa: E402
from app.domain.enums import ItemKind, ItemStatus  # noqa: E402
from app.models import DiscoveredItem, JobPost, Source  # noqa: E402
from app.services.discovery_pipeline import (  # noqa: E402
    MAX_ATTEMPTS,
    follow_detail_pages,
    ingest_pending_pdfs,
    resolve_notice_links,
    run_due_crawls,
)
from app.services.http_fetcher import Fetcher  # noqa: E402
from app.services.notice_labels import label_notices, previous_labels  # noqa: E402
from app.services.pdf_parser import quota_left, usage  # noqa: E402
from app.services.publish import SCHEMA_VERSION, build_jobs_file, build_notices_file  # noqa: E402
from app.services.scraper_service import (  # noqa: E402
    SECTION_FLAG,
    WATCHLIST,
    closing_date,
    local_today,
    section_milestone,
    watchlist_name,
)
from app.services.seeds import ensure_seed_sources  # noqa: E402

log = logging.getLogger("pipeline")

# Kept long enough that a link seen once is never "new" again on its source.
KEEP_ITEMS = timedelta(days=365)
KEEP_JOBS = timedelta(days=400)
# Undated links seen this recently may still be open: worth (re)reading.
REOPEN_UNDATED = timedelta(days=45)

# Columns added after the saved state was first created: create_all() makes new
# tables but never alters existing ones, and a fresh start would forget every link.
ADDED_COLUMNS = (
    "ALTER TABLE discovered_items ADD COLUMN IF NOT EXISTS apply_url VARCHAR(2000)",
    "ALTER TABLE job_posts ADD COLUMN IF NOT EXISTS apply_url VARCHAR(1000)",
    "ALTER TABLE discovered_items ADD COLUMN IF NOT EXISTS page_url VARCHAR(2000)",
    "ALTER TABLE job_posts ADD COLUMN IF NOT EXISTS employment_type VARCHAR(20)",
    "ALTER TABLE post_details ADD COLUMN IF NOT EXISTS pay_scale VARCHAR(300)",
    "ALTER TABLE post_details ADD COLUMN IF NOT EXISTS monthly_pay_min INTEGER",
    "ALTER TYPE parser_key ADD VALUE IF NOT EXISTS 'wordpress_posts'",
)


def gemini_configured() -> bool:
    key = get_settings().gemini_api_key.get_secret_value().strip()
    return bool(key) and key.lower() not in {"unset", "none", "changeme"}


async def pending_pdfs() -> int:
    async with SessionLocal() as session:
        return int(
            await session.scalar(
                select(func.count(DiscoveredItem.id)).where(
                    DiscoveredItem.kind == ItemKind.NOTIFICATION_PDF,
                    DiscoveredItem.status == ItemStatus.PENDING,
                    DiscoveredItem.attempts < MAX_ATTEMPTS,
                )
            )
            or 0
        )


# Failures caused by our Gemini setup (retired model, bad/missing key, quota), not by
# the PDF: they get another chance once the setup is fixed.
SETUP_ERRORS = (
    "Extraction: Gemini API error 400: API key%",
    "Extraction: Gemini API error 401%",
    "Extraction: Gemini API error 403%",
    "Extraction: Gemini API error 404%",
    "Extraction: Gemini API error 429%",
    # Official sites that time out from GitHub's US runners: retried, now with the
    # job page's text as a fallback.
    "%Timeout%",
    "%ConnectError%",
)


async def reclassify_section_notices() -> int:
    """Posts from Admit Card / Answer Key / Result sections that earlier runs filed as job
    pages become the notices they are (published in notices.json, links resolved).
    Idempotent: nothing left to change after the first run."""
    async with SessionLocal() as session:
        changed = 0
        for source in await session.scalars(select(Source)):
            section = section_milestone(source.url)
            if section is None:
                continue
            items = await session.scalars(
                select(DiscoveredItem).where(
                    DiscoveredItem.source_id == source.id, DiscoveredItem.kind == ItemKind.DETAIL_PAGE
                )
            )
            for item in items:
                item.kind = ItemKind.ALERT
                if item.status != ItemStatus.BASELINE:
                    item.status = ItemStatus.DONE
                item.keywords = [*(item.keywords or []), f"{SECTION_FLAG}{section}"]
                item.attempts = 0  # let resolve_notice_links open it for the official link
                item.apply_url = None
                changed += 1
        await session.commit()
        return changed


async def reopen_open_jobs(now: datetime) -> int:
    """Open jobs that an earlier version filed as "already seen" on a source's first
    visit (RRB NTPC, IBPS PO...) go back in the queue. Also re-opens job pages whose
    PDFs were queued before pages were remembered, so those PDFs learn their page."""
    today = local_today(get_settings(), now)
    reopened = 0
    async with SessionLocal() as session:
        baseline = await session.scalars(
            select(DiscoveredItem).where(
                DiscoveredItem.kind.in_([ItemKind.DETAIL_PAGE, ItemKind.NOTIFICATION_PDF]),
                DiscoveredItem.status == ItemStatus.BASELINE,
            )
        )
        for item in baseline:
            closes = closing_date(item.title or "")
            recent = item.published_at is not None and item.published_at >= now - REOPEN_UNDATED
            if (closes is not None and closes >= today) or (closes is None and recent):
                item.status, item.error = ItemStatus.PENDING, None
                reopened += 1
        child = aliased(DiscoveredItem)
        pages = await session.scalars(
            select(DiscoveredItem).where(
                DiscoveredItem.kind == ItemKind.DETAIL_PAGE,
                DiscoveredItem.status == ItemStatus.DONE,
                DiscoveredItem.created_at >= now - REOPEN_UNDATED,
                ~exists().where(child.page_url == DiscoveredItem.url),
                # A page read before the parsers learnt its layout ("no notification link")
                # gets a few more looks.
                or_(DiscoveredItem.error.is_(None), DiscoveredItem.attempts < MAX_ATTEMPTS),
            )
        )
        for page in pages:
            closes = closing_date(page.title or "")
            if closes is None or closes >= today:
                page.status = ItemStatus.PENDING
                reopened += 1
        await session.commit()
    return reopened


async def requeue_setup_failures() -> int:
    async with SessionLocal() as session:
        result = await session.execute(
            update(DiscoveredItem)
            .where(
                DiscoveredItem.kind == ItemKind.NOTIFICATION_PDF,
                DiscoveredItem.status == ItemStatus.FAILED,
                or_(*(DiscoveredItem.error.like(pattern) for pattern in SETUP_ERRORS)),
            )
            .values(status=ItemStatus.PENDING, attempts=0, error=None)
        )
        await session.commit()
        return result.rowcount or 0


async def prune(now: datetime) -> None:
    async with SessionLocal() as session:
        await session.execute(delete(DiscoveredItem).where(DiscoveredItem.created_at < now - KEEP_ITEMS))
        await session.execute(delete(JobPost).where(JobPost.application_deadline < now - KEEP_JOBS))
        await session.commit()


async def watchlist_missing(session, jobs: dict, now: datetime) -> list[str]:
    """Big recruitments the sources mention as open whose job isn't in jobs.json yet."""
    published = " ".join(f"{j['organization']} {j['exam_name']}" for j in jobs["jobs"])
    published_names = {name for name, pattern in WATCHLIST.items() if pattern.search(published)}
    today = local_today(get_settings(), now)
    rows = await session.scalars(
        select(DiscoveredItem.title).where(
            DiscoveredItem.kind.in_([ItemKind.DETAIL_PAGE, ItemKind.NOTIFICATION_PDF]),
            DiscoveredItem.created_at >= now - REOPEN_UNDATED,
            DiscoveredItem.status != ItemStatus.SKIPPED,
        )
    )
    missing: set[str] = set()
    for title in rows:
        name = watchlist_name(title or "")
        closes = closing_date(title or "")
        if name and name not in published_names and (closes is None or closes >= today):
            missing.add(name)
    return sorted(missing)


class Budget:
    """The run's clock. GitHub kills the job at its time limit, and a killed run
    publishes nothing, so every phase gets a share and stops when it runs out."""

    # Pruning and building the files once the work is done.
    RESERVE_S = 180.0

    def __init__(self, minutes: float) -> None:
        self.deadline = time.monotonic() + minutes * 60

    def left(self, cap_s: float | None = None) -> float:
        """Seconds a phase may take: what's left before the reserve, at most cap_s."""
        left = self.deadline - time.monotonic() - self.RESERVE_S
        return max(0.0, left if cap_s is None else min(left, cap_s))


# Phases that crashed this run, with the error: published in the status file
# (the Actions log needs a GitHub login to read).
ERRORS: list[str] = []


async def timeboxed(name: str, work: Awaitable[int], seconds: float, stopped: list[str]) -> int:
    """work's result, or 0 when it is still running after seconds (it is cancelled;
    what it saved so far stays saved, the rest is picked up next run). A phase that
    crashes is stopped the same way: the others still run and the files still go out."""
    if seconds <= 0:
        if asyncio.iscoroutine(work):
            work.close()
        stopped.append(name)
        return 0
    try:
        return await asyncio.wait_for(work, timeout=seconds)
    except TimeoutError:
        log.warning("%s: out of time after %.0f s; the rest waits for the next run", name, seconds)
        stopped.append(name)
        return 0
    except Exception as exc:
        log.exception("%s failed; the rest waits for the next run", name)
        stopped.append(name)
        ERRORS.append(f"{name}: {type(exc).__name__}: {exc}"[:300])
        return 0


def write_json(path: Path, data: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    tmp.replace(path)


async def run(
    out: Path,
    ingest_rounds: int,
    ingest_minutes: int = 25,
    budget_minutes: float = 36,
    previous: Path | None = None,
) -> dict[str, object]:
    settings = get_settings()
    started = datetime.now(UTC)
    budget = Budget(budget_minutes)
    stopped: list[str] = []
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        for ddl in ADDED_COLUMNS:
            await conn.execute(text(ddl))
    async with SessionLocal() as session:
        await ensure_seed_sources(session)

    fetcher = Fetcher(
        user_agent=settings.scraper_user_agent,
        timeout_s=settings.fetch_timeout_s,
        per_host_min_interval_s=settings.per_host_min_interval_s,
        respect_robots=settings.respect_robots_txt,
        extra_ca_bundle=settings.extra_ca_bundle,
        allow_legacy_tls_renegotiation=settings.tls_allow_legacy_renegotiation,
    )
    stats: dict[str, object] = {"schema": SCHEMA_VERSION, "started_at": started.isoformat()}
    try:
        stats["jobs_reopened"] = await reopen_open_jobs(started)
        stats["notices_reclassified"] = await reclassify_section_notices()
        # Each page phase is capped: one slow or hanging site must not eat the time
        # the PDFs (the new jobs) need.
        stats["sources_crawled"] = await timeboxed(
            "crawl", run_due_crawls(SessionLocal, fetcher, settings), budget.left(10 * 60), stopped
        )
        async with SessionLocal() as session:
            stats["detail_pages"] = await timeboxed(
                "detail_pages", follow_detail_pages(session, fetcher, settings), budget.left(8 * 60), stopped
            )
        async with SessionLocal() as session:
            stats["notice_links"] = await timeboxed(
                # The 30-minute notices run (notices.yml) does this; a minute here only
                # catches up if that run is off.
                "notice_links",
                resolve_notice_links(session, fetcher),
                budget.left(60),
                stopped,
            )

        ingested = 0
        stats["gemini_quota_exhausted"] = False
        if gemini_configured():
            stats["pdfs_requeued"] = await requeue_setup_failures()
            # Read until the queue is empty, every AI is out of quota, or time's up.
            # Each PDF gets one try per run; a round still running at the deadline
            # (Gemini slow and retrying) is cancelled.
            attempted: set = set()
            # Two minutes stay for Mistral's notice labels at the end.
            ingest_until = time.monotonic() + max(0.0, budget.left(ingest_minutes * 60) - 120)
            for _ in range(ingest_rounds):
                left = ingest_until - time.monotonic()
                if await pending_pdfs() <= len(attempted) or left <= 0:
                    break
                async with SessionLocal() as session:
                    ingested += await timeboxed(
                        "pdfs",
                        ingest_pending_pdfs(session, fetcher, settings, attempted=attempted),
                        left,
                        stopped,
                    )
                if "pdfs" in stopped:
                    break
                if not quota_left():
                    log.warning("Gemini quota used up for today; remaining PDFs wait for the next run")
                    stats["gemini_quota_exhausted"] = True
                    break
            gemini = usage()
            stats["gemini_requests"] = gemini["requests"]  # the free tier allows ~20 a day per model
            stats["gemini_models_skipped"] = gemini["models_skipped"]
        else:
            log.warning("GEMINI_API_KEY not set: skipping PDF extraction this run")
        stats["pdfs_ingested"] = ingested
        stats["pdfs_waiting"] = await pending_pdfs()
        stats["stopped_early"] = stopped

        now = datetime.now(UTC)
        await prune(now)
        async with SessionLocal() as session:
            jobs = await build_jobs_file(session, now=now)
            notices = await build_notices_file(session, now=now)
            stats["watchlist_missing"] = await watchlist_missing(session, jobs, now)
        stats["label_requests"] = await timeboxed(
            "labels",
            label_notices(notices["notices"], previous_labels(previous)),
            budget.left(3 * 60),
            stopped,
        )
        stats["stopped_early"] = stopped
        stats["errors"] = ERRORS
    finally:
        await fetcher.aclose()
        await engine.dispose()

    write_json(out / "jobs.json", jobs)
    write_json(out / "notices.json", notices)
    stats.update(
        finished_at=datetime.now(UTC).isoformat(),
        jobs=len(jobs["jobs"]),
        notices=len(notices["notices"]),
    )
    write_json(out / "status.json", stats)
    return stats


async def reuse_links(previous: Path | None) -> None:
    """Official links already found (in the last notices.json) are not looked up again:
    the quick run doesn't save its database, so it would open those pages every time."""
    if previous is None or not previous.exists():
        return
    try:
        known = {
            n["url"]: n["link"]
            for n in json.loads(previous.read_text(encoding="utf-8")).get("notices", [])
            if n.get("url") and n.get("link")
        }
    except (ValueError, KeyError, TypeError):
        return
    if not known:
        return
    async with SessionLocal() as session:
        items = await session.scalars(
            select(DiscoveredItem).where(
                DiscoveredItem.kind == ItemKind.ALERT,
                DiscoveredItem.apply_url.is_(None),
                DiscoveredItem.url.in_(list(known)),
            )
        )
        for item in items:
            item.apply_url = known[item.url][:2000]
        await session.commit()


async def run_notices(
    out: Path, previous: Path | None = None, budget_minutes: float = 10
) -> dict[str, object]:
    """The quick run (every 30 minutes): only the Admit Card / Answer Key / Result
    sections, then notices.json. No PDFs, no AI, jobs.json untouched."""
    settings = get_settings()
    started = datetime.now(UTC)
    budget = Budget(budget_minutes)
    stopped: list[str] = []
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        for ddl in ADDED_COLUMNS:
            await conn.execute(text(ddl))
    async with SessionLocal() as session:
        await ensure_seed_sources(session)
    fetcher = Fetcher(
        user_agent=settings.scraper_user_agent,
        timeout_s=settings.fetch_timeout_s,
        per_host_min_interval_s=settings.per_host_min_interval_s,
        respect_robots=settings.respect_robots_txt,
        extra_ca_bundle=settings.extra_ca_bundle,
        allow_legacy_tls_renegotiation=settings.tls_allow_legacy_renegotiation,
    )
    stats: dict[str, object] = {"schema": SCHEMA_VERSION, "started_at": started.isoformat()}
    try:
        stats["sources_crawled"] = await timeboxed(
            "crawl",
            run_due_crawls(
                SessionLocal, fetcher, settings, only=lambda url: section_milestone(url) is not None
            ),
            budget.left(3 * 60),
            stopped,
        )
        await reuse_links(previous)
        async with SessionLocal() as session:
            stats["notice_links"] = await timeboxed(
                "notice_links", resolve_notice_links(session, fetcher), budget.left(3 * 60), stopped
            )
        async with SessionLocal() as session:
            notices = await build_notices_file(session, now=datetime.now(UTC))
        stats["label_requests"] = await timeboxed(
            "labels",
            label_notices(notices["notices"], previous_labels(previous)),
            budget.left(3 * 60),
            stopped,
        )
        stats["stopped_early"] = stopped
        stats["errors"] = ERRORS
    finally:
        await fetcher.aclose()
        await engine.dispose()
    write_json(out / "notices.json", notices)
    stats.update(finished_at=datetime.now(UTC).isoformat(), notices=len(notices["notices"]))
    write_json(out / "status-notices.json", stats)
    return stats


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, required=True, help="folder for jobs.json / notices.json")
    parser.add_argument(
        "--ingest-rounds",
        type=int,
        default=200,
        help="most ingest rounds per run (INGEST_BATCH_SIZE PDFs each)",
    )
    parser.add_argument("--ingest-minutes", type=int, default=25, help="time budget for reading PDFs")
    parser.add_argument("--budget-minutes", type=float, default=36, help="whole run, publishing included")
    parser.add_argument(
        "--notices-only", action="store_true", help="quick run: admit card / answer key / result notices only"
    )
    parser.add_argument("--previous", type=Path, help="the last notices.json (its links are reused)")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    if args.notices_only:
        stats = asyncio.run(run_notices(args.out, args.previous))
    else:
        stats = asyncio.run(
            run(args.out, args.ingest_rounds, args.ingest_minutes, args.budget_minutes, args.previous)
        )
    log.info("Done: %s", stats)


if __name__ == "__main__":
    main()
