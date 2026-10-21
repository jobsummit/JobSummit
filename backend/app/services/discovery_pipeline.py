"""Orchestration used by the scheduler: crawl due sources, open aggregator
detail pages, and push discovered PDFs through the Phase 1 Gemini ingester.

Gemini's free tier allows about 20 requests a day per model, so links whose
"Last Date" has passed are never read, and new PDFs are read several per request."""

from __future__ import annotations

import asyncio
import logging
import uuid
from collections import defaultdict
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from urllib.parse import parse_qs, urlsplit

from bs4 import BeautifulSoup
from sqlalchemy import func, or_, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings, get_settings
from app.domain.enums import ItemKind, ItemStatus
from app.models import DiscoveredItem, Source
from app.services.http_fetcher import Fetcher, FetchError, RetryableFetchError
from app.services.ingestion import find_by_pdf, pdf_sha256, remember_apply_url, save_notification
from app.services.pdf_parser import (
    ExtractionError,
    GeminiQuotaExhausted,
    GeminiUnavailable,
    extract_notifications,
)
from app.services.scraper_service import (
    DETAIL_PARSERS,
    SECTION_FLAG,
    SourceCrawler,
    classify,
    clean_text,
    closed_note,
    find_apply_link,
    find_notice_link,
    job_priority,
    local_today,
)

log = logging.getLogger(__name__)

SessionFactory = Callable[[], AsyncSession]
MAX_ATTEMPTS = 3


# -----------------------------------------------------------------------------
# 1. Crawl due sources (different hosts in parallel, same host sequential)
# -----------------------------------------------------------------------------


async def run_due_crawls(
    session_factory: SessionFactory,
    fetcher: Fetcher,
    settings: Settings | None = None,
    *,
    only: Callable[[str], bool] | None = None,
) -> int:
    """Crawls the sources that are due. With ``only`` (a test on the source's URL),
    just those sources, due or not: the quick notices run reads the admit card /
    answer key / result sections every time."""
    settings = settings or get_settings()
    now = datetime.now(UTC)
    async with session_factory() as session:
        query = select(Source.id, Source.url).where(Source.enabled)
        if only is None:
            query = query.where(or_(Source.next_check_at.is_(None), Source.next_check_at <= now))
        due = (
            await session.execute(query.order_by(Source.next_check_at.asc().nulls_first()).limit(100))
        ).all()
    if only is not None:
        due = [row for row in due if only(row.url)]
    if not due:
        return 0

    by_host: defaultdict[str, list[uuid.UUID]] = defaultdict(list)
    for source_id, url in due:
        by_host[urlsplit(url).hostname or ""].append(source_id)

    crawler = SourceCrawler(fetcher, settings)
    sem = asyncio.Semaphore(settings.crawl_concurrency)

    async def crawl_host(ids: list[uuid.UUID]) -> None:
        async with sem:
            for source_id in ids:
                async with session_factory() as session:
                    source = await session.get(Source, source_id)
                    if source is not None and source.enabled:
                        await crawler.crawl(session, source)

    await asyncio.gather(*(crawl_host(ids) for ids in by_host.values()))
    return len(due)


# -----------------------------------------------------------------------------
# 2. Aggregator detail pages -> official notification PDF links
# -----------------------------------------------------------------------------


NOTICE_LINKS_PER_RUN = 80
NOTICE_LINK_WINDOW_DAYS = 21


def notice_kind(item: DiscoveredItem) -> str | None:
    """What the post itself announces (from its ?notice= key), else its section: a
    post filed under Results that is really an answer key wants the answer-key link."""
    key = parse_qs(urlsplit(item.url).query).get("notice", [""])[0]
    kind = next((k for k in ("admit_card", "answer_key", "result", "exam_date") if key.startswith(k)), None)
    if kind == "exam_date":
        return "admit_card"  # an exam date's useful link is the admit card / login
    return kind or notice_section(item)


def notice_section(item: DiscoveredItem) -> str | None:
    """'admit_card' / 'answer_key' / 'result' for a notice found in such a section."""
    for flag in item.keywords or []:
        if flag.startswith(SECTION_FLAG):
            return flag[len(SECTION_FLAG) :]
    return None


async def resolve_notice_links(
    session: AsyncSession, fetcher: Fetcher, *, limit: int = NOTICE_LINKS_PER_RUN
) -> int:
    """For notices from Admit Card / Answer Key / Result sections, opens the post once
    (twice at most) and keeps the official link from its link table in apply_url: the
    app's button then goes to the admit card itself, not to the aggregator's page."""
    since = datetime.now(UTC) - timedelta(days=NOTICE_LINK_WINDOW_DAYS)
    candidates = await session.scalars(
        select(DiscoveredItem)
        .where(
            DiscoveredItem.kind == ItemKind.ALERT,
            DiscoveredItem.apply_url.is_(None),
            DiscoveredItem.attempts < 2,
            DiscoveredItem.created_at >= since,
        )
        .order_by(DiscoveredItem.created_at.desc())
        .limit(limit * 3)
    )
    resolved = 0
    for item in [i for i in candidates if notice_section(i)][:limit]:
        item.attempts += 1
        try:
            res = await fetcher.get(item.url, max_bytes=get_settings().max_page_bytes)
        except FetchError:
            await session.commit()
            continue
        link = find_notice_link(res.body, res.url, notice_kind(item) or "")
        if link:
            item.apply_url = link[:2000]
            resolved += 1
        await session.commit()
    return resolved


async def follow_detail_pages(
    session: AsyncSession, fetcher: Fetcher, settings: Settings | None = None
) -> int:
    settings = settings or get_settings()
    items = list(
        await session.scalars(
            select(DiscoveredItem)
            .join(Source)
            .where(DiscoveredItem.kind == ItemKind.DETAIL_PAGE, DiscoveredItem.status == ItemStatus.PENDING)
            .limit(QUEUE_SCAN)
        )
    )
    items = by_priority(items)[: settings.aggregator_detail_pages_per_run]
    processed = 0
    today = local_today(settings)
    for item in items:
        if note := closed_note(item.title, today):
            item.status, item.error = ItemStatus.SKIPPED, note  # no point reading its PDF
            continue
        source = await session.get(Source, item.source_id)
        parse = DETAIL_PARSERS.get(source.parser) if source else None
        if parse is None:
            item.status = ItemStatus.SKIPPED
            continue
        item.attempts += 1
        try:
            res = await fetcher.get(item.url, max_bytes=settings.max_page_bytes)
        except FetchError as exc:
            _record_failure(item, exc, retryable=isinstance(exc, RetryableFetchError))
            await session.commit()
            continue

        apply_url = find_apply_link(res.body, res.url)  # travels with the PDF to its job
        rows = []
        for link in parse(res.body, res.url):
            kind, flags = classify(link)
            if kind is ItemKind.OTHER:
                kind = ItemKind.NOTIFICATION_PDF  # the detail parser already picked the notification row
            rows.append(
                {
                    "id": uuid.uuid4(),
                    "attempts": 0,
                    "source_id": item.source_id,
                    "url": link.url[:2000],
                    "title": (link.title or item.title)[:500],
                    "kind": kind,
                    "status": ItemStatus.PENDING if kind is ItemKind.NOTIFICATION_PDF else ItemStatus.DONE,
                    "keywords": flags,
                    "published_at": item.published_at,
                    "apply_url": apply_url,
                    "page_url": item.url[:2000],
                }
            )
        if rows:
            await session.execute(
                pg_insert(DiscoveredItem)
                .values(rows)
                .on_conflict_do_nothing(index_elements=["source_id", "url"])
            )
            # PDFs queued before pages were remembered: link them up now.
            await session.execute(
                update(DiscoveredItem)
                .where(
                    DiscoveredItem.source_id == item.source_id,
                    DiscoveredItem.url.in_([r["url"] for r in rows]),
                    DiscoveredItem.page_url.is_(None),
                )
                .values(
                    page_url=item.url[:2000], apply_url=func.coalesce(DiscoveredItem.apply_url, apply_url)
                )
            )
        item.status = ItemStatus.DONE
        item.error = None if rows else "No notification link found on page"
        await session.commit()
        processed += 1
    await session.commit()
    return processed


# -----------------------------------------------------------------------------
# 3. Notification PDFs -> Gemini -> job_posts (Phase 1 ingester)
# -----------------------------------------------------------------------------


async def ingest_pending_pdfs(
    session: AsyncSession,
    fetcher: Fetcher,
    settings: Settings | None = None,
    *,
    attempted: set[uuid.UUID] | None = None,
) -> int:
    """Downloads one round of queued PDFs, then reads the new ones with as few Gemini
    requests as possible. PDFs left unread because every model is out of quota go
    back in the queue untouched (``pdf_parser.quota_left()`` then says so)."""
    settings = settings or get_settings()
    items = list(
        await session.scalars(
            select(DiscoveredItem)
            .where(
                DiscoveredItem.kind == ItemKind.NOTIFICATION_PDF,
                DiscoveredItem.status == ItemStatus.PENDING,
                DiscoveredItem.attempts < MAX_ATTEMPTS,
            )
            .limit(QUEUE_SCAN)
        )
    )
    today = local_today(settings)
    for item in items:
        if note := closed_note(item.title, today):
            item.status, item.error = ItemStatus.SKIPPED, note
    await session.commit()
    tried = attempted if attempted is not None else set()
    items = by_priority([i for i in items if i.status == ItemStatus.PENDING and i.id not in tried])
    items = items[: settings.ingest_batch_size]
    tried.update(i.id for i in items)  # one try per run: what goes back in the queue waits for the next
    done = 0
    to_read: list[tuple[uuid.UUID, str, str | None, str, bytes]] = []  # id, url, apply url, sha256, doc
    for item in items:
        item_id, url, apply_url, page_url = item.id, item.url, item.apply_url, item.page_url
        item.attempts += 1
        await session.commit()
        problem: Exception | None = None
        body: bytes | None = None
        try:
            res = await fetcher.get(url, max_bytes=settings.max_upload_bytes)
            if res.is_pdf:
                body = res.body
            else:
                problem = FetchError("Link is not a PDF")
        except FetchError as exc:
            problem = exc
        if body is None and page_url:
            # The official site is unreachable from here, or the link is a web page:
            # the job site's own page lists the dates, posts, fees and eligibility.
            text = await page_text(fetcher, page_url, settings)
            if text is not None:
                body = text.encode("utf-8")
                log.info("Reading %s from its job page %s (%s)", url, page_url, problem)
        if body is None:
            item = await session.get(DiscoveredItem, item_id)
            if item is not None:
                if isinstance(problem, FetchError) and str(problem) == "Link is not a PDF":
                    item.status, item.error = ItemStatus.SKIPPED, str(problem)
                else:
                    _record_failure(
                        item, problem or FetchError("?"), retryable=isinstance(problem, RetryableFetchError)
                    )
                await session.commit()
            continue
        res_body = body
        sha256 = pdf_sha256(res_body)
        if known := await find_by_pdf(session, sha256):  # read before, e.g. via another source
            await remember_apply_url(session, known, apply_url)
            await _finish(session, item_id, ItemStatus.DONE, job_post_id=known.id)
            done += 1
            log.info("Ingested %s -> %s (duplicate)", url, known.exam_name)
            continue
        to_read.append((item_id, url, apply_url, sha256, res_body))
    if not to_read:
        return done

    docs = {sha256: data for *_, sha256, data in to_read}  # the same PDF twice is read once
    readable = [d if d.startswith(b"%PDF-") else d.decode("utf-8") for d in docs.values()]
    outcomes = dict(zip(docs, await extract_notifications(readable), strict=True))
    for item_id, url, apply_url, sha256, data in to_read:
        outcome = outcomes[sha256]
        if isinstance(outcome, GeminiQuotaExhausted | GeminiUnavailable):
            item = await session.get(DiscoveredItem, item_id)
            if item is not None:
                if isinstance(outcome, GeminiQuotaExhausted):
                    return_to_queue(item)  # not even tried: the attempt doesn't count
                else:
                    _record_failure(item, outcome, retryable=True)  # again next run, up to MAX_ATTEMPTS
                await session.commit()
            continue
        if isinstance(outcome, ExtractionError):
            await _finish(session, item_id, ItemStatus.FAILED, error=f"Extraction: {outcome}")
            continue
        job, created = await save_notification(session, data, outcome, apply_url=apply_url)
        await _finish(session, item_id, ItemStatus.DONE, job_post_id=job.id)
        done += 1
        log.info("Ingested %s -> %s (%s)", url, job.exam_name, "new" if created else "duplicate")
    return done


# Queues are small (hundreds); sorting in Python keeps the priority rules in one place.
QUEUE_SCAN = 3000


def by_priority(items: list[DiscoveredItem]) -> list[DiscoveredItem]:
    """Big recruitments (railways, banks, SSC, PSUs...) first, then the newest."""
    return sorted(
        items,
        key=lambda i: (-job_priority(i.title or ""), -(i.published_at.timestamp() if i.published_at else 0)),
    )


async def page_text(fetcher: Fetcher, url: str, settings: Settings) -> str | None:
    """The readable text of a job page, without menus, ads and scripts."""
    try:
        res = await fetcher.get(url, max_bytes=settings.max_page_bytes)
    except FetchError:
        return None
    soup = BeautifulSoup(res.body, "lxml")
    for tag in soup(["script", "style", "noscript", "nav", "header", "footer", "aside", "form", "iframe"]):
        tag.decompose()
    main = soup.find("article") or soup.find("main") or soup.body or soup
    lines = [clean_text(line, 400) for line in main.get_text("\n").splitlines()]
    text = "\n".join(line for line in lines if line)
    if len(text) < 500:
        return None  # nothing useful (an error page, a login wall)
    title = clean_text(soup.title.get_text() if soup.title else "", 200)
    return f"Job page: {url}\nTitle: {title}\n\n{text[:40000]}"


def return_to_queue(item: DiscoveredItem) -> None:
    """Undo an attempt that failed for reasons outside the item (e.g. Gemini quota)."""
    item.status = ItemStatus.PENDING
    item.attempts = max(0, item.attempts - 1)
    item.error = None


def _record_failure(item: DiscoveredItem, exc: Exception, *, retryable: bool) -> None:
    item.error = str(exc)[:1000]
    if not retryable or item.attempts >= MAX_ATTEMPTS:
        item.status = ItemStatus.FAILED


async def _finish(
    session: AsyncSession,
    item_id: uuid.UUID,
    status: ItemStatus,
    *,
    error: str | None = None,
    job_post_id: uuid.UUID | None = None,
) -> None:
    # Re-load: save_notification may have rolled the session back.
    item = await session.get(DiscoveredItem, item_id)
    if item is None:
        return
    item.status = status
    item.error = error
    if job_post_id is not None:
        item.job_post_id = job_post_id
    await session.commit()
