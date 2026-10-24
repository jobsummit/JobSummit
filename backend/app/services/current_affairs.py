"""Current affairs for the practice tests, from the government's own press releases
(Press Information Bureau). Each run reads the newest English releases from PIB's
feed, and Mistral writes questions from each release's text alone; a second model
answers them from the same text, and only the questions both agree on are kept.
So every answer is in a release the app links to, not in a model's memory.

``practice/current.json`` holds the last ``WEEKS`` weeks; each question carries its
week (that week's Monday) and its release link. Releases already read are listed
so they are not read again.
"""

from __future__ import annotations

import html
import logging
import re
import time
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Any

import httpx

from app.services import practice_bank as bank

log = logging.getLogger(__name__)

FEED = "https://www.pib.gov.in/RssMain.aspx?ModId=6&Lang=1&Regid=3&reg=3"
PAGE = "https://www.pib.gov.in/PressReleaseIframePage.aspx?PRID={}&reg=3&lang=1"
SOURCE = "https://pib.gov.in/PressReleasePage.aspx?PRID={}"  # the page people open
HEADERS = {"User-Agent": "Mozilla/5.0 (JobSummit practice questions)"}

PER_RUN = 10  # releases read per run
BATCH = 5  # releases per request
TEXT_CHARS = 3000
WEEKS = 8
PER_WEEK = 150
KEEP_READ = 3000

TOPICS = [
    "Schemes & policies", "Economy & finance", "Defence & security", "Science & technology",
    "Awards & appointments", "Sports", "Environment", "International relations", "States & places",
    "Health & education", "Infrastructure & transport",
]  # fmt: skip

WRITE = (
    "You write current-affairs multiple-choice questions for Indian government exams (SSC, banks, "
    "railways, state PSCs) from official press releases. Use ONLY facts stated in the release text you "
    "are given: names of schemes, missions, places, people appointed or awarded, numbers, firsts, dates. "
    "Write 0 to 2 questions per release; write none for greetings, condolences, visit announcements, "
    "routine meetings or releases with no exam-worthy fact. Each question has exactly four options and "
    "one correct answer, says enough to stand alone (name the scheme or event, never 'this release'), "
    "and is under 250 characters. Topic: one of " + ", ".join(TOPICS) + ". "
    'Reply with one JSON object: {"questions": [{"r": <release number>, "topic": <topic>, '
    '"q": <question>, "options": [<4 strings>], "answer": <0-3>, "explanation": <one sentence>}]}'
)

CHECK = (
    "You check current-affairs questions against the press releases they were written from. For each "
    "question, using ONLY its release's text, give the index (0-3) of the correct option; give null when "
    "the text does not settle it, or more than one option could be right. "
    'Reply with one JSON object: {"answers": [{"i": <number>, "answer": <0-3 or null>}]} '
    "with one entry for every question."
)

_ITEM = re.compile(r"<item>\s*<title>(.*?)</title>\s*<link>(.*?)</link>", re.S)
_PRID = re.compile(r"PRID=(\d+)")
_POSTED = re.compile(r"Posted On:\s*(\d{1,2}) ([A-Za-z]{3}) (\d{4})")
_MONTHS = {
    m: i
    for i, m in enumerate(
        ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"], 1
    )
}


def feed_items(xml: str) -> list[tuple[str, str]]:
    """(release id, title), newest first, from PIB's RSS feed."""
    out = []
    for title, link in _ITEM.findall(xml):
        m = _PRID.search(link)
        if m:
            out.append((m.group(1), html.unescape(title).strip()))
    return out


def release_text(page: str) -> tuple[date | None, str]:
    """The release's date and its text (from "Posted On" on, tags removed)."""
    page = re.sub(r"<script.*?</script>|<style.*?</style>", " ", page, flags=re.S | re.I)
    text = html.unescape(re.sub(r"<[^>]+>", " ", page))
    text = re.sub(r"\s+", " ", text)
    m = _POSTED.search(text)
    if not m:
        return None, ""
    month = _MONTHS.get(m.group(2).upper())
    day = date(int(m.group(3)), month, int(m.group(1))) if month else None
    body = text[m.end() :]
    body = re.sub(r"^\s*\d{1,2}:\d{2}\s*[AP]M\s*by PIB \w+", "", body).strip()
    return day, body[:TEXT_CHARS]


def week_of(d: date) -> str:
    return (d - timedelta(days=d.weekday())).isoformat()


def _valid(raw: Any, release: dict[str, Any]) -> dict[str, Any] | None:
    q = bank._valid(raw, "english", "x")  # "english": the changing-facts filter is not for news
    if q is None:
        return None
    topic = raw.get("topic")
    q["t"] = topic if topic in TOPICS else "Current affairs"
    q["w"] = week_of(release["date"])
    q["src"] = SOURCE.format(release["id"])
    return q


async def _get(http: httpx.AsyncClient, url: str) -> str:
    response = await http.get(url, headers=HEADERS, follow_redirects=True, timeout=30)
    response.raise_for_status()
    return response.text


async def grow_current(
    http: httpx.AsyncClient, models: bank._Models, path: Path, deadline: float, *, today: date | None = None
) -> int:
    """Adds this run's questions to [path]; returns how many."""
    today = today or datetime.now(UTC).date()
    data = bank.load_raw(path)
    questions = [q for q in data.get("questions", []) if isinstance(q, dict)]
    read: list[str] = [r for r in data.get("read", []) if isinstance(r, str)]
    oldest = week_of(today - timedelta(weeks=WEEKS - 1))
    questions = [q for q in questions if q.get("w", "") >= oldest]

    try:
        items = feed_items(await _get(http, FEED))
    except httpx.HTTPError as exc:
        log.warning("PIB feed unreachable (%s)", exc)
        return 0
    todo = [(i, t) for i, t in items if i not in read][:PER_RUN]
    releases = []
    for rid, title in todo:
        if time.monotonic() > deadline:
            break
        try:
            day, text = release_text(await _get(http, PAGE.format(rid)))
        except httpx.HTTPError as exc:
            log.warning("PIB release %s unreachable (%s)", rid, exc)
            continue
        read.append(rid)
        if day and len(text) > 300 and day >= today - timedelta(weeks=WEEKS):
            releases.append({"id": rid, "title": title, "date": day, "text": text})

    known = {bank._squash(q["q"]) for q in questions}
    per_week: dict[str, int] = {}
    for q in questions:
        per_week[q["w"]] = per_week.get(q["w"], 0) + 1
    added: list[dict[str, Any]] = []
    for start in range(0, len(releases), BATCH):
        if time.monotonic() > deadline:
            break
        batch = releases[start : start + BATCH]
        listed = "\n\n".join(f"Release {i}: {r['title']}\n{r['text']}" for i, r in enumerate(batch))
        writer, answer = await bank._chat(http, models, WRITE, listed, temperature=0.3)
        if writer is None:
            break
        written: list[tuple[dict[str, Any], int]] = []
        raw = answer.get("questions") if isinstance(answer, dict) else answer
        for item in raw if isinstance(raw, list) else []:
            r = item.get("r") if isinstance(item, dict) else None
            if not isinstance(r, int) or not 0 <= r < len(batch):
                continue
            q = _valid(item, batch[r])
            if q and bank._squash(q["q"]) not in known and per_week.get(q["w"], 0) < PER_WEEK:
                known.add(bank._squash(q["q"]))
                written.append((q, r))
        if not written:
            continue
        checks = "\n\n".join(
            f"{i}. (Release {r}) {q['q']}\n   " + "  ".join(f"({j}) {o}" for j, o in enumerate(q["o"]))
            for i, (q, r) in enumerate(written)
        )
        checker, answer = await bank._chat(
            http, models, CHECK, f"{listed}\n\nQuestions:\n{checks}", other_than=writer
        )
        if checker is None:
            break
        agreed = bank.agreed_indexes(answer, [q for q, _ in written])
        for i, (q, _) in enumerate(written):
            if i in agreed:
                added.append(q)
                per_week[q["w"]] = per_week.get(q["w"], 0) + 1
        log.info(
            "current: %d written, %d agreed (%s, checked by %s)", len(written), len(agreed), writer, checker
        )

    if added or todo:
        bank.save(path, "current", questions + added, extra={"read": read[-KEEP_READ:]})
    return len(added)
