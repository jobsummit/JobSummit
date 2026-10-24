"""The question bank for the app's practice tests: English, general awareness,
general science, computer awareness, and banking & finance, as Indian government
exams (SSC, IBPS, SBI, RRB, state PSCs) ask them. Maths and reasoning are made on
the phone itself (mobile/lib/domain/practice_maker.dart).

Each run adds a few questions per section until it holds ``CAP``: one Mistral
model writes them, a different one answers each blind, and only the questions
both agree on are kept. Questions on facts that change (office-holders, "latest",
rates, recent years) are dropped. One file per section, ``practice/<section>.json``;
the run starts from the last published files, so a failed run changes nothing.

    python -m app.services.practice_bank --dir ../publish/practice
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import logging
import random
import re
import sys
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import httpx
from tenacity import AsyncRetrying, retry_if_exception, stop_after_attempt, wait_exponential_jitter

from app.core.config import get_settings
from app.services import mistral_reader

log = logging.getLogger(__name__)

CAP = 1000  # questions per section
TOPICS_PER_RUN = 2  # per section: the topics with the fewest questions so far
PER_TOPIC = 8
BUDGET_S = 6 * 60  # no new request after this

SECTIONS: dict[str, tuple[str, list[str]]] = {
    "english": (
        "English language",
        [
            "Synonyms", "Antonyms", "One-word substitution", "Idioms & phrases", "Spot the error",
            "Fill in the blank", "Spelling", "Active & passive voice", "Direct & indirect speech",
            "Sentence improvement", "Prepositions", "Articles & tenses",
        ],
    ),
    "gs": (
        "General awareness (static GK)",
        [
            "Indian Constitution & polity", "Ancient & medieval India", "Modern Indian history",
            "Freedom struggle", "Indian geography", "World geography", "Indian economy basics",
            "Art & culture of India", "Sports (rules, terms, trophies)", "Books & authors (classics)",
            "Important days", "International organisations",
        ],
    ),
    "science": (
        "General science",
        [
            "Physics", "Chemistry", "Biology", "Human body", "Diseases & nutrition",
            "Everyday science", "Environment & ecology", "Inventions & discoveries",
        ],
    ),
    "computer": (
        "Computer awareness",
        [
            "Hardware & devices", "Software & operating systems", "MS Word", "MS Excel", "MS PowerPoint",
            "Internet & networking", "Computer security", "Memory & storage units", "Shortcuts & file types",
            "Number systems & abbreviations",
        ],
    ),
    "banking": (
        "Banking & financial awareness",
        [
            "Banking terms", "RBI & monetary policy tools", "Payment systems (NEFT, RTGS, IMPS, UPI)",
            "Types of accounts & loans", "Cheques & negotiable instruments", "Financial regulators",
            "Insurance basics", "Capital market basics", "Abbreviations in banking",
            "History of Indian banking",
        ],
    ),
}  # fmt: skip

WRITE = (
    "You write multiple-choice questions for Indian government recruitment exams (SSC, IBPS, SBI, RRB, "
    "state PSCs), at their real level: mostly moderate, some easy. Each question has exactly four options "
    "and exactly one correct answer; the other three must be clearly wrong to someone who knows. Only "
    "settled, timeless facts: nothing about current office-holders, 'latest' or recent anything, schemes "
    "or rates that change, records, or events after 2020. No question that needs a picture or a table. "
    "Questions under 300 characters, options short. Add a one-sentence explanation of the answer. "
    'Reply with one JSON object: {"questions": [{"q": <question>, "options": [<4 strings>], '
    '"answer": <0-3>, "explanation": <string>}]}'
)

CHECK = (
    "You check multiple-choice questions for Indian government exams. Answer each one yourself: the index "
    "(0-3) of the one correct option. Answer null when no option is correct, when more than one could be, "
    "when the question is unclear, or when it depends on recent or changing facts. "
    'Reply with one JSON object: {"answers": [{"i": <number>, "answer": <0-3 or null>}]} '
    "with one entry for every question."
)

# Facts that change, in sections where they would be wrong next year.
_CHANGES = re.compile(
    r"\b(current|currently|latest|recent|recently|newly|this year|as of|incumbent"
    r"|present(ly)? (chief|head|governor|president|prime|minister|chairman|ceo|captain|holder)"
    r"|20(2[1-9]|3\d))\b",
    re.I,
)
_CHANGES_ALSO = re.compile(r"\b(present|presently|now)\b", re.I)  # only for GK and banking


def _squash(s: str) -> str:
    return re.sub(r"[^a-z0-9]", "", s.lower())


def question_id(text: str) -> str:
    return hashlib.sha1(_squash(text).encode()).hexdigest()[:12]


def _valid(raw: Any, section: str, topic: str) -> dict[str, Any] | None:
    """A written question in the published form, or None when anything is off."""
    if not isinstance(raw, dict):
        return None
    q, options, answer, why = raw.get("q"), raw.get("options"), raw.get("answer"), raw.get("explanation")
    if not isinstance(q, str) or not 12 <= len(q.strip()) <= 400:
        return None
    if not isinstance(options, list) or len(options) != 4:
        return None
    opts = [o.strip() if isinstance(o, str) else "" for o in options]
    if any(not o or len(o) > 150 for o in opts) or len({_squash(o) for o in opts}) != 4:
        return None
    if isinstance(answer, bool) or not isinstance(answer, int) or not 0 <= answer <= 3:
        return None
    if section != "english":
        text = " ".join([q, *opts])
        if _CHANGES.search(text) or (section in {"gs", "banking"} and _CHANGES_ALSO.search(text)):
            return None
    return {
        "id": question_id(q),
        "t": topic,
        "q": q.strip(),
        "o": opts,
        "a": answer,
        "x": why.strip()[:400] if isinstance(why, str) else "",
    }


def load(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    try:
        questions = json.loads(path.read_text(encoding="utf-8")).get("questions", [])
    except (ValueError, AttributeError):
        return []
    return [q for q in questions if isinstance(q, dict) and q.get("id") and q.get("q")]


def save(path: Path, section: str, questions: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    body = {
        "section": section,
        "updated": datetime.now(UTC).isoformat(timespec="seconds"),
        "count": len(questions),
        "questions": questions,
    }
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(body, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    tmp.replace(path)


def _retryable(exc: BaseException) -> bool:
    return isinstance(exc, httpx.HTTPStatusError) and exc.response.status_code in {429, 500, 502, 503, 504}


class _Models:
    """The writer is the first model that answers; the checker the first other one."""

    def __init__(self, names: list[str]) -> None:
        self.names = names
        self.refused: set[str] = set()

    def pick(self, other_than: str | None = None) -> str | None:
        return next((m for m in self.names if m not in self.refused and m != other_than), None)


async def _chat(
    http: httpx.AsyncClient, models: _Models, system: str, user: str, *, other_than: str | None = None
):
    """(model, answer object), or (None, None) when no model will answer."""
    headers = {"Authorization": f"Bearer {get_settings().mistral_api_key.get_secret_value()}"}
    while (model := models.pick(other_than)) is not None:
        body = {
            "model": model,
            "temperature": 0.7 if system is WRITE else 0,
            "response_format": {"type": "json_object"},
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
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
            if exc.response.status_code in {400, 401, 403, 404, 429}:
                log.warning("Mistral model %s refused (%s)", model, exc.response.status_code)
                models.refused.add(model)
                continue
            raise
        content = response.json()["choices"][0]["message"]["content"]
        if isinstance(content, list):  # some models answer in chunks
            content = "".join(c.get("text", "") for c in content if isinstance(c, dict))
        return model, json.loads(content)
    return None, None


def _topics(section: str, bank: list[dict[str, Any]], rng: random.Random) -> list[str]:
    """The topics with the fewest questions so far (ties in random order)."""
    names = SECTIONS[section][1]
    count = {t: 0 for t in names}
    for q in bank:
        if q.get("t") in count:
            count[q["t"]] += 1
    order = sorted(names, key=lambda t: (count[t], rng.random()))
    return order[:TOPICS_PER_RUN]


def _numbered(questions: list[dict[str, Any]]) -> str:
    lines = []
    for i, q in enumerate(questions):
        opts = "  ".join(f"({j}) {o}" for j, o in enumerate(q["o"]))
        lines.append(f"{i}. {q['q']}\n   {opts}")
    return "\n".join(lines)


async def grow_section(
    http: httpx.AsyncClient, models: _Models, section: str, bank: list[dict[str, Any]], rng: random.Random,
    deadline: float,
) -> list[dict[str, Any]]:  # fmt: skip
    """New questions both models agree on (not yet in [bank])."""
    title, _ = SECTIONS[section]
    known = {_squash(q["q"]) for q in bank}
    written: list[dict[str, Any]] = []
    writer = None
    for topic in _topics(section, bank, rng):
        if time.monotonic() > deadline:
            break
        same = [q["q"] for q in bank if q.get("t") == topic]
        avoid = "\n".join(f"- {q}" for q in rng.sample(same, min(25, len(same))))
        user = f"Section: {title}. Topic: {topic}. Write {PER_TOPIC} different questions." + (
            f"\nAlready in the bank (write different ones):\n{avoid}" if avoid else ""
        )
        writer, answer = await _chat(http, models, WRITE, user)
        if writer is None:
            return []
        raw = answer.get("questions") if isinstance(answer, dict) else answer
        for item in raw if isinstance(raw, list) else []:
            q = _valid(item, section, topic)
            if q and _squash(q["q"]) not in known:
                known.add(_squash(q["q"]))
                written.append(q)
    if not written or time.monotonic() > deadline:
        return []
    checker, answer = await _chat(http, models, CHECK, _numbered(written), other_than=writer)
    if checker is None:
        log.warning("No second model to check %s questions; none kept", section)
        return []
    answers = answer.get("answers") if isinstance(answer, dict) else answer
    agreed: set[int] = set()
    for a in answers if isinstance(answers, list) else []:
        i = a.get("i") if isinstance(a, dict) else None
        said = a.get("answer") if isinstance(a, dict) else None
        if isinstance(said, str) and said.strip().isdigit():
            said = int(said)
        if (
            isinstance(i, int)
            and 0 <= i < len(written)
            and said == written[i]["a"]
            and not isinstance(said, bool)
        ):
            agreed.add(i)
    kept = [q for i, q in enumerate(written) if i in agreed]
    log.info(
        "%s: %d written, %d agreed (%s, checked by %s)", section, len(written), len(kept), writer, checker
    )
    return kept


async def grow(
    folder: Path, *, client: httpx.AsyncClient | None = None, seed: int | None = None
) -> dict[str, int]:
    """Adds to each section's file in [folder]; returns how many each got."""
    if not mistral_reader.configured():
        log.info("No Mistral key: the practice bank stays as it is")
        return {}
    rng = random.Random(seed)
    models = _Models([m.strip() for m in get_settings().practice_models.split(",") if m.strip()])
    deadline = time.monotonic() + BUDGET_S
    own = client is None
    http = client or httpx.AsyncClient(timeout=get_settings().mistral_timeout_s)
    added: dict[str, int] = {}
    try:
        for section in SECTIONS:
            path = folder / f"{section}.json"
            bank = load(path)
            if len(bank) >= CAP or time.monotonic() > deadline:
                continue
            try:
                new = await grow_section(http, models, section, bank, rng, deadline)
            except (httpx.HTTPError, ValueError, KeyError, IndexError, TypeError, AttributeError) as exc:
                log.warning("Practice %s failed (%s); next run", section, exc)
                continue
            added[section] = len(new)
            if new:
                save(path, section, (bank + new)[:CAP])
    finally:
        if own:
            await http.aclose()
    return added


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m app.services.practice_bank")
    parser.add_argument(
        "--dir", required=True, type=Path, help="the practice/ folder (last files already in it)"
    )
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    added = asyncio.run(grow(args.dir))
    counts = {s: len(load(args.dir / f"{s}.json")) for s in SECTIONS}
    print(json.dumps({"added": added, "total": counts}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
