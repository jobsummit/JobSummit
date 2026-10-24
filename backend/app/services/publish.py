"""Static data files for the serverless app (GitHub Actions -> `data` branch).

    jobs.json     open notifications with everything the phone needs to run the
                  eligibility engine itself (degrees, tiers, ages, seats, experience)
    notices.json  recent admit-card / exam-date / answer-key / result notices, which
                  the phone's exam watcher matches against the exams you track

Qualification rules are published *merged*: what the extractor stated plus what
the degree lines imply (``infer_requirement``), so the phone needs no text parsing
except the "Others" keyword search.
"""

from __future__ import annotations

import re
from datetime import UTC, date, datetime, timedelta
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.domain.enums import ExamMilestone, ItemKind, ItemStatus
from app.domain.qualifications import QualificationLevel
from app.models import DiscoveredItem, JobPost, PostDetail
from app.services.exam_watcher import classify_milestone
from app.services.lifecycle import timeline_out
from app.services.scraper_service import SECTION_FLAG, is_job_site
from app.services.streams import infer_requirement

SCHEMA_VERSION = 1
# Recently closed jobs stay a little while, so a phone that was offline over the
# deadline still shows "closed" rather than the job silently vanishing.
JOBS_GRACE = timedelta(days=2)
NOTICES_WINDOW = timedelta(days=21)


def _iso(value: date | datetime | None) -> str | None:
    return value.isoformat() if value is not None else None


def merged_requirement(post: PostDetail) -> dict[str, Any]:
    """Explicit fields + what the degree lines imply, in the phone's terms."""
    req = infer_requirement(list(post.eligible_streams or ()))
    any_grad = bool(post.is_open_to_any_graduate) or req.open_to_any_graduate
    any_pg = bool(post.is_open_to_any_post_graduate) or req.open_to_any_post_graduate
    levels = [lv for lv in (post.min_qualification_level, req.min_level) if lv is not None]
    levels += [QualificationLevel.UG] if any_grad else []
    levels += [QualificationLevel.PG] if any_pg else []
    need = min(levels, key=lambda lv: lv.rank) if levels else None
    return {
        "allowed_degrees": list(dict.fromkeys([*(post.allowed_degrees or ()), *req.allowed_degrees])),
        "min_qualification_level": need.value if need else None,
        "is_open_to_any_graduate": any_grad,
        "is_open_to_any_post_graduate": any_pg,
    }


def post_json(post: PostDetail) -> dict[str, Any]:
    vac = post.vacancy
    return {
        "id": str(post.id),
        "post_code": post.post_code,
        "post_name": post.post_name,
        "min_age": post.min_age,
        "base_max_age": post.base_max_age,
        "age_as_on": _iso(post.age_as_on),
        "eligible_streams": list(post.eligible_streams or ()),
        "qualification_text": post.qualification_text,
        "raw_eligibility_text": post.raw_eligibility_text,
        **merged_requirement(post),
        "min_experience_years": float(post.min_experience_years or 0),
        "pay_scale": post.pay_scale,
        "monthly_pay_min": post.monthly_pay_min,
        "age_relaxation_overrides": dict(post.age_relaxation_overrides or {}),
        "vacancy": None
        if vac is None
        else {"ur": vac.ur, "sc": vac.sc, "st": vac.st, "obc": vac.obc, "ews": vac.ews, "total": vac.total},
    }


# First match wins: a railway PSU is "railway", a bank's research post is "bank".
_CATEGORIES: tuple[tuple[str, re.Pattern[str]], ...] = tuple(
    (name, re.compile(pattern, re.IGNORECASE))
    for name, pattern in (
        ("railway", r"\b(?:rrb|rrc|railway|ntpc graduate|ntpc ug|metro rail|ircon|rites|konkan)\b"),
        (
            "bank",
            r"\b(?:bank|banking|crp|ibps|sbi|rbi|nabard|sidbi|exim|lic|insurance|niacl|gic|sebi|"
            r"ippb)\b",
        ),
        ("ssc", r"\b(?:ssc|staff selection commission)\b"),
        ("upsc", r"\b(?:upsc|union public service commission)\b"),
        (
            "research",
            r"\b(?:jrf|srf|research (?:fellow|associate|assistant)|project (?:associate|assistant|scientist|"
            r"staff|technical)|post[- ]?doctoral|fellow)\b",
        ),
        (
            "defence",
            r"\b(?:army|navy|air force|coast guard|bsf|crpf|cisf|itbp|ssb|assam rifles|police|"
            r"constable|agniveer|defence|ordnance)\b",
        ),
        (
            "psu",
            r"\b(?:limited|ltd|corporation|ongc|bhel|bel|gail|iocl|hpcl|bpcl|sail|hal|nhpc|ntpc|powergrid|"
            r"coal india|nlc|npcil|drdo|isro|barc|aai|bsnl|nmdc|psu)\b",
        ),
        ("teaching", r"\b(?:teacher|tgt|pgt|prt|lecturer|professor|faculty|school|kvs|nvs|education)\b"),
        (
            "medical",
            r"\b(?:aiims|nurs\w*|medical|doctors?|hospital|health|pharmac\w*|paramedical|resident)\b",
        ),
        ("court", r"\b(?:court|judicial|judge|legal)\b"),
        (
            "state",
            r"\b(?:psc|sssc|subordinate|dsssb|osssc|hssc|bpsc|uppsc|mpesb|rsmssb|jssc|wbpsc|tnpsc|kpsc|"
            r"appsc|tspsc|opsc|gpsc|mpsc|state|district|zila|municipal|nagar)\b",
        ),
    )
)


def job_category(organization: str, exam_name: str) -> str:
    """A coarse group the app filters and ranks by (keywords, so older jobs get one too)."""
    text = f"{organization} {exam_name}"
    return next((name for name, pattern in _CATEGORIES if pattern.search(text)), "other")


def job_json(job: JobPost) -> dict[str, Any]:
    return {
        "id": str(job.id),
        "organization": job.organization,
        "exam_name": job.exam_name,
        "advertisement_no": job.advertisement_no,
        # The board's site. A job site's address is what the AI copies when it read the
        # job site's page (the official PDF unreachable): the app would watch the wrong page.
        "portal_url": None if is_job_site(job.portal_url) else job.portal_url,
        "apply_url": job.apply_url,  # the registration page itself, when a job site links it
        "category": job_category(job.organization, job.exam_name),
        "employment_type": job.employment_type,
        "fees": job.fees or {},
        "fee_refund": job.fee_refund,
        "application_start": _iso(job.application_start),
        "application_deadline": _iso(job.application_deadline),
        "exam_date": _iso(job.exam_date),
        "needs_review": job.needs_review,
        "timeline": timeline_out(job).model_dump(mode="json"),
        "posts": [post_json(p) for p in job.posts],
    }


async def build_jobs_file(session: AsyncSession, *, now: datetime | None = None) -> dict[str, Any]:
    now = now or datetime.now(UTC)
    jobs = await session.scalars(
        select(JobPost)
        .where(JobPost.application_deadline >= now - JOBS_GRACE)
        .order_by(JobPost.application_deadline.asc(), JobPost.id)
        .options(
            selectinload(JobPost.posts).selectinload(PostDetail.vacancy),
            selectinload(JobPost.timeline),
        )
    )
    return {"schema": SCHEMA_VERSION, "generated_at": now.isoformat(), "jobs": without_twins(list(jobs))}


# --- The same notice found twice -------------------------------------------------------
# Two sources can lead to one notice by different files (the official PDF, a job
# site's page read when the PDF was out of reach), so it is read twice. Mirrored in
# the app (feed_builder.dart withoutDuplicates).

_ADVERT_FILLER = re.compile(
    r"\b(?:advt|advertisement|notification|notice|no|number|ref|reference|dated|dt)\b\.?", re.IGNORECASE
)
_ORG_FILLER = {"of", "the", "and", "for", "office", "department", "govt", "government"}
_IST = timedelta(hours=5, minutes=30)


def advert_key(advert: str | None) -> str | None:
    """ "CEN No. 06/2026" and "CEN 6/2026" -> "cen-6-2026"; None when too short to tell."""
    if not advert:
        return None
    parts = re.findall(r"[a-z]+|\d+", _ADVERT_FILLER.sub(" ", advert.lower()))
    parts = [(p.lstrip("0") or "0") if p.isdigit() else p for p in parts]
    key = "-".join(parts)
    return key if len(key.replace("-", "")) >= 3 else None


def _org_words(org: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", org.lower())


def _initials(words: list[str]) -> set[str]:
    every = "".join(w[0] for w in words)
    plain = "".join(w[0] for w in words if w not in _ORG_FILLER)
    return {a for a in (every, plain) if len(a) > 1}


def same_board(a: str, b: str) -> bool:
    """One board, named two ways: "Railway Recruitment Boards" and "Railway
    Recruitment Board (RRB)". One name's words (bar an acronym of the other) must all
    be in the other's, so two districts' collectors stay apart."""
    words_a, words_b = _org_words(a), _org_words(b)

    def significant(words: list[str], other: list[str]) -> set[str]:
        acronyms = _initials(other)
        return {
            w[:-1] if len(w) > 3 and w.endswith("s") else w
            for w in words
            if len(w) > 1 and w not in _ORG_FILLER and w not in acronyms
        }

    sa, sb = significant(words_a, words_b), significant(words_b, words_a)
    if not words_a or not words_b:
        return False
    return sa <= sb or sb <= sa


def _post_names(job: JobPost) -> set[str]:
    return {" ".join(re.findall(r"[a-z0-9]+", (p.post_name or "").lower())) for p in job.posts}


def _same_posts(a: JobPost, b: JobPost) -> bool:
    pa, pb = _post_names(a), _post_names(b)
    if not pa or not pb:
        return True
    return len(pa & pb) * 2 >= min(len(pa), len(pb))


def _twin_key(job: JobPost) -> str | None:
    adv = advert_key(job.advertisement_no)
    if adv is None or job.application_deadline is None:
        return None
    return f"{adv}|{(job.application_deadline.astimezone(UTC) + _IST).date()}"


def _rank(job: JobPost) -> tuple[bool, bool, int, bool]:
    """The copy to keep: read from the notification itself, with the board's site,
    the most posts, an application link."""
    return (
        (job.source_pdf_path or "").endswith(".pdf"),
        bool(job.portal_url) and not is_job_site(job.portal_url),
        len(job.posts),
        bool(job.apply_url),
    )


def without_twins(jobs: list[JobPost]) -> list[dict[str, Any]]:
    """jobs.json rows with each notice once: one advert number, one closing day in
    India, one board, overlapping posts. The copy kept gets what only the other knew
    and lists its id in ``same_as`` (the app hides both once you apply to either)."""
    groups: list[list[JobPost]] = []
    for job in jobs:
        key = _twin_key(job)
        group = next(
            (
                g
                for g in groups
                if key is not None
                and _twin_key(g[0]) == key
                and same_board(g[0].organization, job.organization)
                and _same_posts(g[0], job)
            ),
            None,
        )
        if group is None:
            groups.append([job])
        else:
            group.append(job)
    rows = []
    for group in groups:
        group.sort(key=_rank, reverse=True)
        row = job_json(group[0])
        for twin in group[1:]:
            other = job_json(twin)
            for field in ("portal_url", "apply_url", "application_start", "exam_date"):
                if row[field] is None:
                    row[field] = other[field]
            if row["timeline"] is not None and other["timeline"] is not None:
                for field, value in other["timeline"].items():
                    if row["timeline"].get(field) in (None, {}, []):
                        row["timeline"][field] = value
                row["timeline"]["job_post_id"] = row["id"]
            row.setdefault("same_as", []).append(other["id"])
        rows.append(row)
    return rows


def _section_milestone(item: DiscoveredItem) -> ExamMilestone | None:
    for flag in item.keywords or []:
        if flag.startswith(SECTION_FLAG):
            try:
                return ExamMilestone(flag[len(SECTION_FLAG) :])
            except ValueError:
                return None
    return None


async def build_notices_file(session: AsyncSession, *, now: datetime | None = None) -> dict[str, Any]:
    now = now or datetime.now(UTC)
    items = await session.scalars(
        select(DiscoveredItem)
        .where(
            DiscoveredItem.kind.in_([ItemKind.ALERT, ItemKind.OTHER]),
            # First-crawl ("baseline") notices count too: an admit card already out
            # when a source is added is exactly what a tracked exam needs.
            DiscoveredItem.status != ItemStatus.SKIPPED,
            DiscoveredItem.created_at >= now - NOTICES_WINDOW,
        )
        .order_by(DiscoveredItem.created_at.desc())
    )
    notices = []
    seen: set[str] = set()  # a post listed in two sections is one notice
    for item in items:
        if item.url in seen:
            continue
        milestone = classify_milestone(item.title) or _section_milestone(item)
        if milestone is None:
            continue  # navigation links, tenders, syllabi...
        seen.add(item.url)
        notices.append(
            {
                "title": item.title,
                "url": item.url,  # the notice's identity (never changes)
                # The official link from the notice's page (admit card download,
                # answer key, result), when found: what the app's button opens.
                "link": item.apply_url if item.kind == ItemKind.ALERT and item.apply_url else None,
                "milestone": milestone.value,
                "published_at": _iso(item.published_at),
                "seen_at": _iso(item.created_at),
            }
        )
    return {"schema": SCHEMA_VERSION, "generated_at": now.isoformat(), "notices": notices}
