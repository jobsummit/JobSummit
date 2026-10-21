"""Crawl sources, detect changes, and record new links.

Pipeline for one source
-----------------------
1. ``collect_links``: fetch (httpx, Playwright fallback) and parse into ``Link``s.
2. ``fingerprint``: MD5 over the *normalised link set*, not raw HTML, so
   rotating ads, CSRF tokens and visitor counters don't look like changes.
3. If the hash changed, links never seen for this source become
   ``DiscoveredItem``s, classified by ``classify``:
     NOTIFICATION_PDF -> queued for Gemini (discovery_pipeline.ingest_pending_pdfs)
     DETAIL_PAGE      -> aggregator page to open later (discovery_pipeline.follow_detail_pages)
     ALERT            -> admit card / exam date / postponed / corrigendum
4. A job that is still open is always read, even on a source's first crawl.
   Only old alerts (admit cards, results from before tracking began) count
   as BASELINE. ``job_priority`` decides what Gemini reads first.
5. A job link whose "Last Date" (printed beside it on aggregator lists) has
   passed is SKIPPED: reading it would spend a Gemini request on a closed job.

Parsers were written against the live markup of each site in Oct 2026. They
fall back to the generic DOM parser when their selectors find nothing.
"""

from __future__ import annotations

import hashlib
import html
import json
import logging
import random
import re
import uuid
from collections.abc import Iterable
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, timedelta
from urllib.parse import parse_qs, urljoin, urlsplit, urlunsplit
from zoneinfo import ZoneInfo

from bs4 import BeautifulSoup, Tag
from dateutil import parser as dateparser
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings, get_settings
from app.domain.enums import ItemKind, ItemStatus, ParserKey
from app.models import DiscoveredItem, Source
from app.services.http_fetcher import Fetcher
from app.services.js_renderer import looks_js_rendered, render_page

log = logging.getLogger(__name__)

# =============================================================================
# Link model + keyword engine
# =============================================================================


@dataclass(frozen=True, slots=True)
class Link:
    url: str
    title: str
    context: str = ""  # surrounding row/list text; carries dates, "Last Date", labels
    published_at: datetime | None = None
    pdf_hint: bool = False  # parser knows it's a document even without ".pdf"
    detail_page: bool = False  # aggregator page that must be opened to find the PDF


# Flag -> phrases, matched as whole words/phrases (so "extension of" can't match
# "Extension Officer"). Inflections are listed explicitly instead of using stems.
ALERT_KEYWORDS: dict[str, tuple[str, ...]] = {
    "admit_card": ("admit card", "admit cards", "e-admit card", "call letter", "call letters", "hall ticket"),
    "exam_date": (
        "exam date",
        "exam dates",
        "exam schedule",
        "examination schedule",
        "exam city",
        "date of exam",
        "date of examination",
    ),
    "postponed": (
        "postpone",
        "postponed",
        "postponement",
        "rescheduled",
        "re-scheduled",
        "deferred",
        "cancelled",
        "cancellation",
    ),
    "corrigendum": ("corrigendum", "addendum", "erratum"),
    "date_extended": (
        "date extended",
        "extension of last date",
        "last date extended",
        "extended till",
        "extended upto",
        "extended up to",
    ),
}
RECRUITMENT_HINTS = (
    "recruitment",
    "notification",
    "advertisement",
    "advt",
    "vacanc",
    "online form",
    "apply online",
    "engagement",
    "employment notice",
    "detailed notice",
    "rozgar",
)
NOISE_HINTS = (
    "tentative vacanc",
    "result",
    "answer key",
    "marks",
    "cut off",
    "cutoff",
    "cut-off",
    "merit list",
    "response sheet",
    "syllabus",
    "debarred",
    "score card",
    "scorecard",
    "tender",
    "rti",
    "annual report",
)


_ALERT_PATTERNS = {
    flag: re.compile(r"\b(?:" + "|".join(re.escape(p) for p in phrases) + r")\b", re.IGNORECASE)
    for flag, phrases in ALERT_KEYWORDS.items()
}


def flag_keywords(text: str) -> list[str]:
    return [flag for flag, pattern in _ALERT_PATTERNS.items() if pattern.search(text)]


def _looks_like_pdf_url(url: str) -> bool:
    path = urlsplit(url).path.lower()
    return path.endswith(".pdf") or "/pdf/" in path


def classify(link: Link) -> tuple[ItemKind, list[str]]:
    text = f"{link.title} {link.context}".lower()
    flags = flag_keywords(text)
    if flags:
        return ItemKind.ALERT, flags
    recruitment = any(h in text for h in RECRUITMENT_HINTS)
    noise = any(h in text for h in NOISE_HINTS)
    if link.detail_page:
        return (ItemKind.DETAIL_PAGE if recruitment and not noise else ItemKind.OTHER), flags
    if (link.pdf_hint or _looks_like_pdf_url(link.url)) and recruitment and not noise:
        return ItemKind.NOTIFICATION_PDF, flags
    return ItemKind.OTHER, flags


# Aggregator sections that are notices by definition: a post listed under "Admit
# Card" is an admit-card notice even when its title is just "SSC CGL 2026 Tier-1".
_SECTION_MARKERS = (
    ("admit-card", "admit_card"),
    ("admitcard", "admit_card"),
    ("answer-key", "answer_key"),
    ("answerkey", "answer_key"),
    ("result", "result"),
)
SECTION_FLAG = "section:"


def section_milestone(source_url: str) -> str | None:
    """'admit_card' / 'answer_key' / 'result' for a source that is such a section: a
    section page (/admit-card/) or an API seed marked with section=admit-card."""
    parts = urlsplit(source_url)
    marked = parse_qs(parts.query).get("section", [""])[0].lower()
    for marker, milestone in _SECTION_MARKERS:
        if marked and marked.startswith(marker):
            return milestone
    for segment in (s for s in parts.path.lower().split("/") if s):
        for marker, milestone in _SECTION_MARKERS:
            if segment == marker or segment.startswith(marker):
                return milestone
    return None


# On a notice's page, the row whose label names the action ("Download Admit Card |
# Click Here") holds the official link.
_ACTION_LABELS = {
    "admit_card": re.compile(r"admit card|hall ticket|call letter|city (?:intimation|slip)|exam city", re.I),
    "answer_key": re.compile(r"answer key|response sheet|objection", re.I),
    "result": re.compile(r"result|merit list|score ?card|cut ?off|marks", re.I),
}


def find_notice_link(html: bytes | str, base_url: str, milestone: str) -> str | None:
    """The official link for the notice's action (the admit card download, the answer
    key, the result) from the page's link table, or None."""
    label_re = _ACTION_LABELS.get(milestone)
    if label_re is None:
        return None
    soup = _soup(html)
    for tr in soup.find_all("tr"):
        if tr.find("tr") is not None or len(tr.find_all(["td", "th"], recursive=False)) > 3:
            continue  # layout tables wrap the whole page; we want the short link rows
        label = clean_text(tr.get_text(" ", strip=True), 200)
        if len(label) > 120 or not label_re.search(label):
            continue
        for a in tr.find_all("a", href=True):
            url = canonical_url(urljoin(base_url, str(a["href"])))
            parts = urlsplit(url)
            if parts.scheme not in ("http", "https") or is_social_link(url):
                continue
            if _is_sarkari_result(parts.netloc) and "/wp-content/uploads/" not in parts.path:
                continue  # back into the aggregator itself
            return url
    return None


# =============================================================================
# Normalisation + fingerprint
# =============================================================================

_WS = re.compile(r"\s+")
_TRACKING_PARAMS = re.compile(r"^(utm_|fbclid|gclid|ref$|amp$)")


def clean_text(text: str, limit: int = 500) -> str:
    return _WS.sub(" ", text).strip()[:limit]


def canonical_url(url: str) -> str:
    """Drop fragments and tracking params so the same link isn't 'new' twice."""
    parts = urlsplit(url.strip())
    query = "&".join(
        kv for kv in parts.query.split("&") if kv and not _TRACKING_PARAMS.match(kv.split("=", 1)[0])
    )
    return urlunsplit((parts.scheme.lower(), parts.netloc.lower(), parts.path or "/", query, ""))


def fingerprint(links: Iterable[Link]) -> str:
    lines = sorted({f"{lk.url}|{lk.title.lower()}" for lk in links})
    return hashlib.md5("\n".join(lines).encode("utf-8"), usedforsecurity=False).hexdigest()


# =============================================================================
# Parsers
# =============================================================================

_SKIP_HREF = ("#", "mailto:", "tel:", "javascript:", "whatsapp:")
_CHROME_TAGS = ("nav", "header", "footer")


def _soup(html: bytes | str) -> BeautifulSoup:
    return BeautifulSoup(html, "lxml")


def _context_for(a: Tag) -> str:
    container = a.find_parent(["tr", "li"]) or a.parent
    return clean_text(container.get_text(" ", strip=True)) if container else ""


def _anchor_links(scope: Tag | BeautifulSoup, base_url: str, *, skip_chrome: bool = True) -> list[Link]:
    seen: dict[str, Link] = {}
    for a in scope.find_all("a", href=True):
        href = str(a["href"]).strip()
        if not href or href.lower().startswith(_SKIP_HREF):
            continue
        if skip_chrome and a.find_parent(_CHROME_TAGS) is not None:
            continue
        url = canonical_url(urljoin(base_url, href))
        if not url.startswith(("http://", "https://")):
            continue
        title = clean_text(a.get_text(" ", strip=True), 300) or clean_text(str(a.get("title", "")), 300)
        context = _context_for(a)
        if not title:
            title = context[:300]
        prev = seen.get(url)
        if prev is None or len(title) > len(prev.title):
            seen[url] = Link(url=url, title=title, context=context)
    return list(seen.values())


def parse_generic(html: bytes | str, base_url: str) -> list[Link]:
    """Any career page: every content link with its row/list context.
    Table rows are covered because the row text becomes the link context."""
    return _anchor_links(_soup(html), base_url)


# sarkariresult.com, and the unofficial copy sarkariresult.com.cm, which uses the same
# detail-page tables and is reachable from GitHub's US runners (the original returns 403).
SARKARI_RESULT_DOMAINS = ("sarkariresult.com", "sarkariresult.com.cm")


def _is_sarkari_result(netloc: str) -> bool:
    return netloc.endswith(SARKARI_RESULT_DOMAINS)


def parse_sarkari_result_list(html: bytes | str, base_url: str) -> list[Link]:
    soup = _soup(html)
    links: list[Link] = []
    for li in soup.select("ul.wp-block-list li, ul.sarkari-quick-list li, ul.latest-posts-last-date li"):
        a = li.find("a", href=True)
        if a is None:
            continue
        url = canonical_url(urljoin(base_url, str(a["href"])))
        if _is_sarkari_result(urlsplit(url).netloc):
            text = clean_text(li.get_text(" ", strip=True), 300)
            links.append(Link(url=url, title=text, context=text, detail_page=True))
    return links or parse_generic(html, base_url)


def parse_sarkari_result_detail(html: bytes | str, base_url: str) -> list[Link]:
    """Detail pages have a 'Useful Important Links' table: 'Download Notification | Click Here'.
    The PDF is often hosted under /wp-content/uploads/ with no .pdf extension."""
    soup = _soup(html)
    page_title = clean_text(soup.title.get_text() if soup.title else "", 200)
    out: list[Link] = []
    for tr in soup.find_all("tr"):
        if tr.find("tr") is not None or len(tr.find_all(["td", "th"], recursive=False)) > 3:
            continue  # layout tables wrap the whole page; we want the 2-cell link rows
        label = clean_text(tr.get_text(" ", strip=True), 200)
        if "notification" not in label.lower() or len(label) > 120:
            continue
        for a in tr.find_all("a", href=True):
            url = canonical_url(urljoin(base_url, str(a["href"])))
            parts = urlsplit(url)
            own_site = _is_sarkari_result(parts.netloc)
            if own_site and "/wp-content/uploads/" not in parts.path and not _looks_like_pdf_url(url):
                continue  # links back into SarkariResult itself (home, categories)
            if is_social_link(url):
                continue  # "Join our WhatsApp channel for notifications"
            out.append(Link(url=url, title=page_title or label, context=label, pdf_hint=True))
    return out


def parse_free_job_alert_list(html: bytes | str, base_url: str) -> list[Link]:
    """Rows: Post Date | Board | Post Name | Qualification | Advt No | Last Date | Get Details."""
    soup = _soup(html)
    links: list[Link] = []
    for tr in soup.select("table.lattbl tr"):
        cells = [clean_text(td.get_text(" ", strip=True), 120) for td in tr.find_all("td")]
        a = tr.find("a", href=True)
        if len(cells) < 6 or a is None:
            continue
        posted, board, post, _qual, advt, last_date = cells[:6]
        title = f"{board} – {post} Recruitment" + (f" (Advt {advt})" if advt.strip("– ") else "")
        if _parse_ddmmyyyy(last_date):
            title += f" – Last Date: {last_date}"  # kept with the item: closed jobs are skipped later
        published = _parse_ddmmyyyy(posted)
        links.append(
            Link(
                url=canonical_url(urljoin(base_url, str(a["href"]))),
                title=clean_text(title, 300),
                context=f"Last date {last_date}",
                published_at=published,
                detail_page=True,
            )
        )
    return links or parse_generic(html, base_url)


def parse_free_job_alert_detail(html: bytes | str, base_url: str) -> list[Link]:
    """'Download Official Notification' links straight to the board's own PDF. Some
    pages say "Official Notification PDF: Click here": the label is next to the link."""
    soup = _soup(html)
    page_title = clean_text(soup.title.get_text() if soup.title else "", 200)
    out: list[Link] = []
    seen: set[str] = set()
    for a in soup.find_all("a", href=True):
        text = clean_text(a.get_text(" ", strip=True), 120).lower()
        row = a.find_parent(["li", "p", "tr"])
        if row is not None and len(row.find_all("a", href=True)) == 1:
            label = clean_text(row.get_text(" ", strip=True), 160).lower()
            if len(label) <= 120:
                text = label
        url = canonical_url(urljoin(base_url, str(a["href"])))
        if (
            "notification" in text
            and "apply" not in text
            and url not in seen
            and not urlsplit(url).netloc.endswith("freejobalert.com")
            and not is_social_link(url)
        ):
            seen.add(url)
            out.append(Link(url=url, title=page_title or text, context=text, pdf_hint=True))
    return out


_SOCIAL_HOSTS = (
    "whatsapp.com",
    "t.me",
    "telegram.me",
    "telegram.org",
    "youtube.com",
    "youtu.be",
    "facebook.com",
    "instagram.com",
    "twitter.com",
    "x.com",
    "play.google.com",
    "apps.apple.com",
)


def is_social_link(url: str) -> bool:
    host = (urlsplit(url).hostname or "").lower()
    return any(host == h or host.endswith("." + h) for h in _SOCIAL_HOSTS)


# What Gemini reads first. Big national recruitments that many applicants want
# outrank one-post walk-ins; the phone ranks for the individual user afterwards.
_PRIORITY_WORDS: tuple[tuple[re.Pattern[str], int], ...] = tuple(
    (re.compile(p, re.IGNORECASE), w)
    for p, w in (
        (r"\b(?:rrb|ntpc|rrc|railway|alp|group d)\b", 6),
        (r"\b(?:ssc|cgl|chsl|mts|gd constable|stenographer|selection post)\b", 6),
        (r"\b(?:ibps|sbi|rbi|nabard|sidbi|exim|lic|niacl|gic|sebi|ippb|crp|common recruitment process)\b", 6),
        (r"\b(?:upsc|cds|nda|capf|ese|cms)\b", 5),
        (r"\bbank\b", 3),
        (
            r"\b(?:ongc|bhel|bel|gail|iocl|ioc|hpcl|bpcl|sail|hal|nhpc|powergrid|coal india|nlc|npcil|"
            r"drdo|isro|barc|aai|bsnl|nmdc|rites|ircon|mazagon|cochin shipyard|psu)\b",
            5,
        ),
        (
            r"\b(?:po|probationary|officer|clerk|assistant|junior engineer|je|engineer|executive|"
            r"management trainee|graduate trainee|inspector|accountant|auditor)\b",
            3,
        ),
        (r"\b(?:jrf|junior research fellow|net|gate)\b", 2),
        (r"\b(?:psc|sssc|subordinate services|dsssb|police|constable|army|navy|air force|coast guard)\b", 2),
        (
            r"\b(?:walk[- ]?in|guest faculty|part[- ]time|consultant|retired|honorary|para legal|"
            r"peon|chowkidar|sweeper|safai|gardener|cook|driver|attendant|anganwadi|home guard)\b",
            -4,
        ),
        (
            r"\b(?:project (?:assistant|associate|staff|technical)|field (?:worker|investigator)|"
            r"senior resident|post[- ]doctoral|faculty)\b",
            -2,
        ),
    )
)
_POST_COUNT = re.compile(r"([\d,]{2,7})\s*posts?\b", re.IGNORECASE)


# The big recurring recruitments nobody should miss: they jump the queue, and each
# run reports any that the sources mention but the app doesn't show yet.
WATCHLIST: dict[str, re.Pattern[str]] = {
    name: re.compile(pattern, re.IGNORECASE)
    for name, pattern in {
        "RRB NTPC": r"\brrb\b.*\bntpc\b|\bntpc\b.*\b(?:graduate|10\+2|ug|cen)\b|non[- ]technical popular",
        "RRB Group D": r"\brrb\b.*\bgroup[- ]d\b|\brrb\b.*\blevel[- ]1\b",
        "RRB ALP": r"\brrb\b.*\b(?:alp|assistant loco pilot)\b",
        "RRB JE": r"\brrb\b.*\b(?:je|junior engineer)\b",
        "SSC CGL": r"\bssc\b.*\b(?:cgl|combined graduate level)\b",
        "SSC CHSL": r"\bssc\b.*\b(?:chsl|combined higher secondary)\b",
        "SSC MTS": r"\bssc\b.*\b(?:mts|multi[- ]tasking)\b",
        "SSC GD": r"\bssc\b.*\bgd\b",
        "SSC CPO": r"\bssc\b.*\bcpo\b",
        "SSC JE": r"\bssc\b.*\b(?:je|junior engineer)\b",
        "SSC Stenographer": r"\bssc\b.*\bstenographer\b",
        "IBPS PO": r"\bibps\b.*\b(?:po|probationary officer)|crp[-\s]*po",
        "IBPS Clerk": r"\bibps\b.*\b(?:clerk|csa)\b|crp[-\s]*(?:clerk|csa)",
        "IBPS RRB": r"\bibps\b.*\brrb\b|crp[-\s]*rrb",
        "IBPS SO": r"\bibps\b.*\bso\b|crp[-\s]*spl|specialist officers?.*\bibps\b",
        "SBI PO": r"\bsbi\b.*\b(?:po|probationary officer)\b",
        "SBI Clerk": r"\bsbi\b.*\b(?:clerk|junior associate)\b",
        "RBI": r"\brbi\b.*\b(?:grade b|assistant|officer)\b",
        "NABARD": r"\bnabard\b",
        "LIC AAO/ADO": r"\blic\b.*\b(?:aao|ado|assistant)\b",
        "UPSC CSE": r"\bupsc\b.*\b(?:civil services|cse|ias)\b",
        "UPSC CDS/NDA": r"\bupsc\b.*\b(?:cds|nda)\b",
        "UPSC CAPF": r"\bupsc\b.*\bcapf\b",
    }.items()
}


def watchlist_name(title: str) -> str | None:
    return next((name for name, pattern in WATCHLIST.items() if pattern.search(title)), None)


def job_priority(title: str) -> int:
    """Higher = read sooner. Keyword weights plus a bonus for many vacancies; the
    watchlist's big recruitments always come first."""
    score = sum(w for pattern, w in _PRIORITY_WORDS if pattern.search(title))
    if watchlist_name(title):
        score += 20
    if m := _POST_COUNT.search(title):
        posts = int(m[1].replace(",", "") or 0)
        score += 3 if posts >= 1000 else 2 if posts >= 100 else 1 if posts >= 20 else 0
    return score


_APPLY_LABEL = re.compile(r"\bapply\s+online\b|\bonline\s+(?:application|apply)\b", re.IGNORECASE)
_REGISTER_LABEL = re.compile(r"\bregistration\b|\bregister\b", re.IGNORECASE)
_AGGREGATOR_DOMAINS = (*SARKARI_RESULT_DOMAINS, "freejobalert.com")

# Job and news sites write about every exam (same list as the app's links.dart).
JOB_SITE_DOMAINS = (
    *_AGGREGATOR_DOMAINS,
    "sarkariresult.app",
    "sarkariexam.com",
    "sarkarinaukri.com",
    "sarkarinaukriblog.com",
    "sarkariprep.in",
    "rojgarresult.com",
    "recruitmentresult.com",
    "freshersnow.com",
    "jagranjosh.com",
    "testbook.com",
    "adda247.com",
    "bankersadda.com",
    "sscadda.com",
    "careerpower.in",
    "oliveboard.in",
    "ixambee.com",
    "prepp.in",
    "indgovtjobs.in",
    "employmentnews.gov.in",
    "naukri.com",
    "shiksha.com",
    "careers360.com",
    "collegedunia.com",
    "timesofindia.indiatimes.com",
    "indianexpress.com",
    "hindustantimes.com",
    "ndtv.com",
    "news18.com",
    "jagran.com",
)


def is_job_site(url: str | None) -> bool:
    """A job site's page, not the exam board's own."""
    host = (urlsplit((url or "").strip()).hostname or "").lower()
    return bool(host) and any(host == d or host.endswith(f".{d}") for d in JOB_SITE_DOMAINS)


def find_apply_link(html: bytes | str, base_url: str) -> str | None:
    """The official application page a job site links to: SarkariResult's "Apply Online
    Link | Click Here" row, FreeJobAlert's "Apply Online: Click here", or the
    "Registration" link of an "Apply Online | Registration | Login" row. None until the
    link is live ("Link Activate Soon"). Kept as written: some portals route by #fragment."""
    registration: str | None = None
    for a in _soup(html).find_all("a", href=True):
        url = urljoin(base_url, str(a["href"]).strip())
        parts = urlsplit(url)
        if (
            parts.scheme not in ("http", "https")
            or (parts.hostname or "").endswith(_AGGREGATOR_DOMAINS)
            or _looks_like_pdf_url(url)
        ):
            continue
        # A one-link row is labelled by the row ("Apply Online Link | Click Here");
        # in a row of several links ("Registration | Login") each speaks for itself.
        row = a.find_parent(["tr", "li", "p"])
        row_text = clean_text(row.get_text(" ", strip=True), 200) if row is not None else ""
        single = row is not None and len(row.find_all("a", href=True)) == 1
        label = row_text if single else clean_text(a.get_text(" ", strip=True), 200)
        if len(label) > 120:
            continue  # a paragraph or a list of other jobs, not a link row
        if _APPLY_LABEL.search(label):
            return url[:2000]
        # A bare "Register now" is often an ad (mock tests): only inside an apply row.
        if registration is None and _REGISTER_LABEL.search(label) and _APPLY_LABEL.search(row_text):
            registration = url[:2000]
    return registration


SSC_API_BASE = "https://ssc.gov.in/api/attachment/"


def parse_ssc_api(body: bytes | str, base_url: str) -> list[Link]:  # noqa: ARG001
    """ssc.gov.in is a React SPA; its notice board is served by a public JSON API."""
    data = json.loads(body)
    out: list[Link] = []
    for rec in data.get("data") or []:
        headline = clean_text(str(rec.get("headline") or ""), 300)
        published = _parse_iso(rec.get("createdAt"))
        for att in rec.get("attachments") or []:
            path = str(att.get("path") or "").replace("\\", "/").lstrip("/")
            if not path:
                continue
            out.append(
                Link(
                    url=SSC_API_BASE + path,
                    title=headline,
                    context=headline,
                    published_at=published,
                    pdf_hint=att.get("type") == "application/pdf",
                )
            )
    return out


# What a post title announces, latest stage first ("Admit Card ... Result Out" is a result).
_NOTICE_KINDS = (
    ("result", re.compile(r"\bresult|merit list|score ?card|cut ?off", re.I)),
    ("answer_key", re.compile(r"answer key|response sheet", re.I)),
    (
        "admit_card",
        re.compile(r"admit card|hall ticket|call letter|exam city|city (?:slip|intimation)", re.I),
    ),
    ("exam_date", re.compile(r"exam date|exam schedule|time ?table", re.I)),
)

_STAGE_TOKEN = re.compile(
    r"\b(tier|phase|paper|cbt|stage)[\s-]*(i{1,3}v?|iv|v|\d)\b|\b(prelims?|preliminary|pre|mains|interview|final)\b",
    re.I,
)


def notice_key(title: str, section: str | None) -> str:
    """What a notice on a reused page is about: 'admit_card-tier-i', 'result-final'.
    The site keeps one page per exam (/ssc-cgl-2026/) and updates it from admit card to
    answer key to result, so the page address alone can't tell the notices apart."""
    kind = next((k for k, rx in _NOTICE_KINDS if rx.search(title)), None) or section or "notice"
    stage = _STAGE_TOKEN.search(title)
    if stage is None:
        return kind
    token = (stage.group(1) and f"{stage.group(1)}-{stage.group(2)}") or stage.group(3)
    return f"{kind}-{token.lower()}"


def parse_wordpress_posts(body: bytes | str, base_url: str) -> list[Link]:
    """A WordPress category through its public REST API (/wp-json/wp/v2/posts): stable
    JSON instead of theme markup. Each post becomes one notice per stage it announces."""
    section = section_milestone(base_url)
    out: list[Link] = []
    for post in json.loads(body) or []:
        link = str(post.get("link") or "")
        title = clean_text(html.unescape(str((post.get("title") or {}).get("rendered") or "")), 300)
        if not link.startswith("http") or not title:
            continue
        sep = "&" if "?" in link else "?"
        out.append(
            Link(
                url=f"{canonical_url(link)}{sep}notice={notice_key(title, section)}",
                title=title,
                context=title,
                published_at=_parse_iso(post.get("modified") or post.get("date")),
                detail_page=True,
            )
        )
    return out


def _parse_ddmmyyyy(text: str) -> datetime | None:
    m = re.search(r"(\d{1,2})[/-](\d{1,2})[/-](\d{4})", text)
    if not m:
        return None
    try:
        return datetime(int(m[3]), int(m[2]), int(m[1]), tzinfo=UTC)
    except ValueError:
        return None


def _parse_iso(value: object) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


# "Last Date: 25 November 2026" (SarkariResult), "Last date 25/11/2026" (FreeJobAlert),
# "Last Date Extended till 30-11-2026".
_LAST_DATE = re.compile(
    r"\blast\s+date\b\D{0,40}?"
    r"(\d{1,2}[./-]\d{1,2}[./-]\d{4}|\d{1,2}(?:st|nd|rd|th)?\s+[a-z]{3,9}\.?,?\s+\d{4})",
    re.IGNORECASE,
)


def closing_date(text: str) -> date | None:
    """The 'Last Date' an aggregator prints beside a job link, if any."""
    m = _LAST_DATE.search(text)
    if m is None:
        return None
    try:
        d = dateparser.parse(m[1], dayfirst=True).date()
    except (ValueError, OverflowError):
        return None
    return d if 2000 <= d.year <= 2100 else None


def closed_note(text: str, today: date) -> str | None:
    """Why a job link is skipped unread: its 'Last Date' is before ``today``."""
    closes = closing_date(text)
    if closes is None or closes >= today:
        return None
    return f"Closed on {closes:%d %b %Y} before it was read"


def local_today(settings: Settings, now: datetime | None = None) -> date:
    return (now or datetime.now(UTC)).astimezone(ZoneInfo(settings.timezone)).date()


LIST_PARSERS = {
    ParserKey.GENERIC: parse_generic,
    ParserKey.SARKARI_RESULT: parse_sarkari_result_list,
    ParserKey.FREE_JOB_ALERT: parse_free_job_alert_list,
    ParserKey.SSC_API: parse_ssc_api,
    ParserKey.WORDPRESS_POSTS: parse_wordpress_posts,
}
DETAIL_PARSERS = {
    ParserKey.SARKARI_RESULT: parse_sarkari_result_detail,
    ParserKey.FREE_JOB_ALERT: parse_free_job_alert_detail,
}


# =============================================================================
# Crawler
# =============================================================================


@dataclass
class CrawlOutcome:
    source_id: str
    changed: bool = False
    new_items: int = 0
    queued: int = 0
    alerts: int = 0
    error: str | None = None
    flags: list[str] = field(default_factory=list)


def next_check_time(now: datetime, settings: Settings, *, failures: int = 0) -> datetime:
    base = timedelta(hours=settings.crawl_interval_hours)
    if failures:
        base = min(base * (2 ** min(failures, 4)), timedelta(hours=24))
    jitter = timedelta(minutes=random.uniform(-settings.crawl_jitter_minutes, settings.crawl_jitter_minutes))
    return now + max(base + jitter, timedelta(minutes=30))


class SourceCrawler:
    def __init__(self, fetcher: Fetcher, settings: Settings | None = None) -> None:
        self.fetcher = fetcher
        self.settings = settings or get_settings()

    async def collect_links(self, source: Source) -> list[Link]:
        if source.parser is ParserKey.TELEGRAM:
            from app.services.telegram_service import collect_channel_links

            links, cursor = await collect_channel_links(
                self.fetcher, source.url, source.cursor, self.settings
            )
            if cursor:
                source.cursor = cursor
            return links

        parse = LIST_PARSERS.get(source.parser, parse_generic)
        res = await self.fetcher.get(source.url, max_bytes=self.settings.max_page_bytes)
        links = parse(res.body, res.url)
        if (
            self.settings.playwright_enabled
            and source.parser is ParserKey.GENERIC
            and (source.render_js or looks_js_rendered(res.text, len(links)))
        ):
            html = await render_page(source.url, user_agent=self.fetcher.user_agent)
            links = parse_generic(html, source.url)
        return links

    async def crawl(
        self, session: AsyncSession, source: Source, *, now: datetime | None = None
    ) -> CrawlOutcome:
        now = now or datetime.now(UTC)
        outcome = CrawlOutcome(source_id=str(source.id))
        source.last_checked_at = now
        try:
            links = await self.collect_links(source)
        except Exception as exc:  # noqa: BLE001 - one broken source must not stop the tick
            source.consecutive_failures += 1
            source.last_error = str(exc)[:1000]
            source.next_check_at = next_check_time(now, self.settings, failures=source.consecutive_failures)
            await session.commit()
            outcome.error = source.last_error
            log.warning("Crawl failed for %s: %s", source.name, exc)
            return outcome

        source.consecutive_failures = 0
        source.last_error = None
        source.next_check_at = next_check_time(now, self.settings)

        digest = fingerprint(links)
        first_crawl = source.content_hash is None
        if digest == source.content_hash:
            await session.commit()
            return outcome

        outcome.changed = True
        source.content_hash = digest
        source.last_changed_at = now
        rows = await self._new_item_rows(
            session, source, links, first_crawl=first_crawl, today=local_today(self.settings, now)
        )
        if rows:
            await session.execute(
                pg_insert(DiscoveredItem)
                .values(rows)
                .on_conflict_do_nothing(index_elements=["source_id", "url"])
            )
        await session.commit()

        outcome.new_items = len(rows)
        outcome.queued = sum(1 for r in rows if r["status"] == ItemStatus.PENDING)
        outcome.alerts = sum(
            1 for r in rows if r["kind"] == ItemKind.ALERT and r["status"] != ItemStatus.BASELINE
        )
        outcome.flags = sorted({f for r in rows if r["status"] != ItemStatus.BASELINE for f in r["keywords"]})
        log.info(
            "Crawled %s: %d new (%d queued, %d alerts)%s",
            source.name,
            outcome.new_items,
            outcome.queued,
            outcome.alerts,
            " [baseline]" if first_crawl else "",
        )
        return outcome

    async def _new_item_rows(
        self, session: AsyncSession, source: Source, links: list[Link], *, first_crawl: bool, today: date
    ) -> list[dict[str, object]]:
        if not links:
            return []
        known = set(
            await session.scalars(
                select(DiscoveredItem.url).where(
                    DiscoveredItem.source_id == source.id,
                    DiscoveredItem.url.in_([lk.url for lk in links]),
                )
            )
        )
        rows: list[dict[str, object]] = []
        for link in links:  # page order: newest first on every source we parse
            if link.url in known:
                continue
            known.add(link.url)
            kind, flags = classify(link)
            # A post listed in an Admit Card / Answer Key / Result section is that notice,
            # whatever its title says (not a job page to mine for a notification).
            section = section_milestone(source.url)
            if section and link.detail_page:
                kind, flags = ItemKind.ALERT, [*flags, f"{SECTION_FLAG}{section}"]
            actionable = kind in (ItemKind.NOTIFICATION_PDF, ItemKind.DETAIL_PAGE)
            closed = closed_note(f"{link.title} {link.context}", today) if actionable else None
            if kind is ItemKind.OTHER:
                status = ItemStatus.SKIPPED
            elif closed:
                status = ItemStatus.SKIPPED
            elif actionable:
                status = ItemStatus.PENDING  # still open (or no date known): always read it
            elif first_crawl:
                status = ItemStatus.BASELINE  # an old admit card / result notice
            else:
                status = ItemStatus.DONE  # an alert: recorded, published in notices.json
            rows.append(
                {
                    "id": uuid.uuid4(),
                    "attempts": 0,
                    "source_id": source.id,
                    "url": link.url[:2000],
                    "title": (link.title or link.url)[:500],
                    "kind": kind,
                    "status": status,
                    "keywords": flags,
                    "published_at": link.published_at,
                    "error": closed,
                }
            )
        return rows
