"""Mistral labels each notice once: which exam it is about (an id from the app's own
exam list), which round (advert number, year, IBPS numeral) and which stage.

The phone's exam watcher matches these labels to the exams you track instead of
guessing from the title's words ("NTPC Graduate CBTST" is not NTPC Undergraduate's
CBT-1). Only public notice titles are sent; nothing about anyone's exams.

Labels travel in notices.json (``about``), and each run takes the ones the last
file already had, so a notice is sent to Mistral once.
"""

from __future__ import annotations

import json
import logging
import re
from pathlib import Path
from typing import Any

import httpx
from tenacity import AsyncRetrying, retry_if_exception, stop_after_attempt, wait_exponential_jitter

from app.core.config import get_settings
from app.services import mistral_reader

log = logging.getLogger(__name__)

# The app's exam list (mobile/lib/domain/exam_catalog.dart), next to this code in
# the repository.
CATALOG = Path(__file__).resolve().parents[3] / "mobile" / "lib" / "domain" / "exam_catalog.dart"
BATCH = 25

# Same keys as the app's stageKey() (exam_watcher.dart).
STAGES = (
    "tier-1", "tier-2", "tier-3", "paper-1", "paper-2", "phase-1", "phase-2", "phase-3",
    "cbt-1", "cbt-2", "stage-1", "stage-2", "prelims", "mains", "interview", "skill", "dv",
    "medical", "physical",
)  # fmt: skip

_EXAM = re.compile(
    r"CatalogExam\(\s*'([^']+)',\s*'([^']+)',\s*([^,]+),(.*?)\)\s*,\s*(?=CatalogExam\(|//|\])", re.S
)
_ALIASES = re.compile(r"aliases:\s*\[(.*?)\]", re.S)
_BOARDS = re.compile(r"^const (_\w+) = '([^']+)';", re.M)
_ROMAN = re.compile(r"^(?=[IVXL]{1,6}$)L?X{0,3}(IX|IV|V?I{0,3})$")
_YEAR = re.compile(r"^(?:19|20)\d\d$")


def load_catalog(path: Path = CATALOG) -> list[dict[str, Any]]:
    """[{id, name, board, aliases}] from the Dart source."""
    source = path.read_text(encoding="utf-8")
    boards = dict(_BOARDS.findall(source))
    exams = []
    for m in _EXAM.finditer(source):
        board = m.group(3).strip()
        board = boards.get(board, board.strip("'"))
        aliases = _ALIASES.search(m.group(4))
        exams.append(
            {
                "id": m.group(1),
                "name": m.group(2),
                "board": board,
                "aliases": re.findall(r"'([^']+)'", aliases.group(1)) if aliases else [],
            }
        )
    return exams


def previous_labels(path: Path | None) -> dict[str, dict[str, Any]]:
    """url -> label, from the last notices.json."""
    if path is None or not path.exists():
        return {}
    try:
        notices = json.loads(path.read_text(encoding="utf-8")).get("notices", [])
    except (ValueError, AttributeError):
        return {}
    return {n["url"]: n["about"] for n in notices if isinstance(n, dict) and n.get("url") and n.get("about")}


SYSTEM = (
    "You label Indian government recruitment notices (admit cards, answer keys, results, exam dates). "
    "For each notice title decide which exam it is about, using ONLY an id from the exam list, or null "
    "when it is none of them or you are not sure. Be strict: Graduate and Undergraduate (10+2, UG) are "
    "different exams; IBPS Clerk (CSA) and IBPS RRB Office Assistant are different; a board's other "
    "recruitments (Junior Translator, Ministerial, Section Controller...) are none of them unless listed. "
    'Also give, when the title prints them: the advertisement number ("CEN 06/2025", '
    '"CRPD/CR/2026-27/17"), the year of the recruitment round, the IBPS-style round numeral ("XV"), '
    "and the stage the notice is about, one of: " + ", ".join(STAGES) + ". CBTST, CBAT and typing tests "
    'are "skill"; DV is "dv". Use null for anything not printed. Reply with one JSON object: '
    '{"labels": [{"i": <number>, "exam": <id or null>, "advert": <string or null>, '
    '"year": <string or null>, "numeral": <string or null>, "stage": <string or null>}]} '
    "with one entry for every notice."
)


def _exam_list(catalog: list[dict[str, Any]]) -> str:
    lines = []
    for e in catalog:
        also = f"; also {', '.join(e['aliases'])}" if e["aliases"] else ""
        lines.append(f"{e['id']}: {e['name']} ({e['board']}{also})")
    return "\n".join(lines)


def _squash(s: str) -> str:
    return re.sub(r"[^a-z0-9]", "", s.lower())


def _clean(raw: Any, ids: set[str], title: str = "") -> dict[str, Any] | None:
    if not isinstance(raw, dict):
        return None

    def text(key: str) -> str | None:
        v = raw.get(key)
        return v.strip()[:80] if isinstance(v, str) and v.strip() and v.strip().lower() != "null" else None

    exam, stage, year, numeral, advert = (
        text("exam"),
        text("stage"),
        text("year"),
        text("numeral"),
        text("advert"),
    )
    # An advert number the title doesn't print is a guess ("CRP SPL-XVI"), and a wrong
    # one would hide the notice from the exam it is about.
    if advert and _squash(advert) not in _squash(title):
        advert = None
    return {
        "exam": exam if exam in ids else None,
        "advert": advert,
        "year": year if year and _YEAR.match(year) else None,
        "numeral": numeral.upper() if numeral and _ROMAN.match(numeral.upper()) else None,
        "stage": stage.lower() if stage and stage.lower() in STAGES else None,
    }


def _retryable(exc: BaseException) -> bool:
    return isinstance(exc, httpx.HTTPStatusError) and exc.response.status_code in {429, 500, 502, 503, 504}


async def _ask(http: httpx.AsyncClient, titles: list[str], exam_list: str) -> list[Any]:
    settings = get_settings()
    headers = {"Authorization": f"Bearer {settings.mistral_api_key.get_secret_value()}"}
    numbered = "\n".join(f"{i}. {t}" for i, t in enumerate(titles))
    for model in mistral_reader.models():
        body = {
            "model": model,
            "temperature": 0,
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": SYSTEM},
                {"role": "user", "content": f"Exam list:\n{exam_list}\n\nNotices:\n{numbered}"},
            ],
        }
        try:
            response = None
            async for attempt in AsyncRetrying(
                retry=retry_if_exception(_retryable),
                wait=wait_exponential_jitter(initial=3, max=30),
                stop=stop_after_attempt(3),
                reraise=True,
            ):
                with attempt:
                    response = await http.post(mistral_reader.API_URL, headers=headers, json=body)
                    response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            if exc.response.status_code in {400, 403, 404, 429}:
                log.warning("Mistral model %s refused labels (%s)", model, exc.response.status_code)
                mistral_reader._refused.add(model)
                continue
            raise
        content = response.json()["choices"][0]["message"]["content"]
        if isinstance(content, list):  # some models answer in chunks
            content = "".join(c.get("text", "") for c in content if isinstance(c, dict))
        answer = json.loads(content)
        labels = answer.get("labels") if isinstance(answer, dict) else answer
        return labels if isinstance(labels, list) else []
    return []


async def label_notices(
    notices: list[dict[str, Any]],
    known: dict[str, dict[str, Any]],
    *,
    catalog: list[dict[str, Any]] | None = None,
    client: httpx.AsyncClient | None = None,
) -> int:
    """Puts ``about`` on each notice: the label the last file had, else Mistral's.
    Returns how many requests were sent. Without a Mistral key, or when Mistral
    fails, notices go without (the app then falls back to its word rules)."""
    for n in notices:
        if n["url"] in known:
            about = dict(known[n["url"]])
            if about.get("advert") and _squash(about["advert"]) not in _squash(n["title"]):
                about["advert"] = None  # labelled before guesses were dropped
            n["about"] = about
    todo = [n for n in notices if "about" not in n]
    if not todo or not mistral_reader.configured():
        return 0
    catalog = catalog if catalog is not None else load_catalog()
    ids = {e["id"] for e in catalog}
    exam_list = _exam_list(catalog)
    own = client is None
    http = client or httpx.AsyncClient(timeout=get_settings().mistral_timeout_s)
    requests = 0
    try:
        for start in range(0, len(todo), BATCH):
            batch = todo[start : start + BATCH]
            try:
                answers = await _ask(http, [n["title"] for n in batch], exam_list)
            except (httpx.HTTPError, ValueError, KeyError, IndexError, TypeError, AttributeError) as exc:
                log.warning("Mistral labels failed (%s); the rest wait for the next run", exc)
                break
            requests += 1
            for raw in answers:
                i = raw.get("i") if isinstance(raw, dict) else None
                if isinstance(i, int) and 0 <= i < len(batch):
                    label = _clean(raw, ids, batch[i]["title"])
                    if label is not None:
                        batch[i]["about"] = label
    finally:
        if own:
            await http.aclose()
    return requests
