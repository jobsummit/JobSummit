"""The job-picks model: what the app learns from everyone who chose to share,
published as ``picks.json`` for the phones to rank with.

Two parts:

* A small LLM (Ministral 8B by default) gives every open job a career track
  (clerical, officer, engineering, teaching...). Each job is labelled once; the
  labels are kept in picks.json and reused.
* From the shared choices (Supabase, ``picks_training()`` / ``picks_jobs()``),
  for each group of people with the same degree, the same qualification level,
  and everyone, a weight per job feature: the log-odds of applying versus
  turning it down, shrunk towards 0 when few people are behind it. The phone
  adds these to its own learned likes, with less weight, so your own choices
  still lead.

Groups of fewer than 5 people never leave the database. Without the Supabase
secret, the tracks are still labelled and the weights stay as they were.

    python -m app.services.picks --jobs ../publish/jobs.json --previous old.json --out ../publish/picks.json
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import math
import sys
import time
from collections import defaultdict
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import httpx

from app.core.config import get_settings
from app.services import mistral_reader
from app.services import practice_bank as bank

log = logging.getLogger(__name__)

TRACKS = [
    "clerical", "officer", "engineering", "technical", "teaching", "police_defence", "medical",
    "banking_finance", "research", "legal", "skilled_trade", "other",
]  # fmt: skip
BATCH = 40
MAX_REQUESTS = 10
BUDGET_S = 4 * 60
SHRINK = 10  # people needed for a weight to count half
KEEP_TRACKS = 5000

LABEL = (
    "You sort Indian government job notifications into career tracks. For each job give exactly one "
    "track from: " + ", ".join(TRACKS) + ". clerical = clerks, assistants, data entry, MTS; officer = "
    "administrative and executive officers, PO, inspectors; engineering = JE/AE and engineer posts; "
    "technical = technicians, ITI trades, lab and IT staff; police_defence = constables, soldiers, SI, "
    "agniveer; banking_finance = bank and insurance jobs, accountants. "
    'Reply with one JSON object: {"tracks": [{"i": <number>, "track": <track>}]}'
)


def _models() -> bank._Models:
    names = [m.strip() for m in get_settings().picks_models.split(",") if m.strip()]
    return bank._Models(names)


def open_jobs(jobs_file: dict[str, Any], now: datetime) -> list[dict[str, Any]]:
    out = []
    for j in jobs_file.get("jobs", []):
        deadline = j.get("application_deadline")
        try:
            if deadline and datetime.fromisoformat(deadline) < now:
                continue
        except ValueError:
            pass
        out.append(j)
    return out


def _describe(job: dict[str, Any]) -> str:
    posts = ", ".join(p.get("post_name", "") for p in job.get("posts", [])[:6])
    return f"{job.get('exam_name', '')} | {job.get('organization', '')} | posts: {posts}"[:300]


async def label_tracks(
    http: httpx.AsyncClient, jobs: list[dict[str, Any]], known: dict[str, str], deadline: float
) -> dict[str, str]:
    """Tracks for [jobs] not in [known] (asked in batches, within the budget)."""
    todo = [j for j in jobs if j.get("id") and j["id"] not in known]
    if not todo or not mistral_reader.configured():
        return {}
    models = _models()
    found: dict[str, str] = {}
    for n, start in enumerate(range(0, len(todo), BATCH)):
        if n >= MAX_REQUESTS or time.monotonic() > deadline:
            break
        batch = todo[start : start + BATCH]
        listed = "\n".join(f"{i}. {_describe(j)}" for i, j in enumerate(batch))
        try:
            model, answer = await bank._chat(http, models, LABEL, listed, temperature=0)
        except (httpx.HTTPError, ValueError, KeyError, IndexError, TypeError) as exc:
            log.warning("Track labels failed (%s); next run", exc)
            break
        if model is None:
            break
        rows = answer.get("tracks") if isinstance(answer, dict) else answer
        for row in rows if isinstance(rows, list) else []:
            i = row.get("i") if isinstance(row, dict) else None
            track = row.get("track") if isinstance(row, dict) else None
            if isinstance(i, int) and 0 <= i < len(batch) and track in TRACKS:
                found[batch[i]["id"]] = track
    return found


def weight(applied: int, rejected: int, people: int) -> float:
    """Log-odds of applying, shrunk towards 0 when few people are behind it."""
    return math.log((applied + 1) / (rejected + 1)) * people / (people + SHRINK)


def cohort_weights(
    feature_rows: list[dict[str, Any]], job_rows: list[dict[str, Any]], tracks: dict[str, str]
) -> dict[str, dict[str, float]]:
    """{cohort: {feature: weight}} from the database's summaries. Tracks come
    from the job rows (which jobs a degree's people applied to)."""
    out: dict[str, dict[str, float]] = defaultdict(dict)
    for r in feature_rows:
        w = weight(int(r["applied"]), int(r["rejected"]), int(r["people"]))
        if abs(w) >= 0.05:
            out[r["cohort"]][r["feature"]] = round(w, 3)
    per_track: dict[tuple[str, str], list[int]] = defaultdict(lambda: [0, 0, 0])
    for r in job_rows:
        track = tracks.get(r["job_id"])
        if track:
            t = per_track[(r["cohort"], f"track:{track}")]
            t[0] += int(r["applied"])
            t[1] += int(r["rejected"])
            t[2] += 5  # each job row stands for at least 5 people
    for (cohort, feature), (a, rj, people) in per_track.items():
        w = weight(a, rj, people)
        if abs(w) >= 0.05:
            out[cohort][feature] = round(w, 3)
    return dict(out)


async def _rpc(http: httpx.AsyncClient, name: str) -> list[dict[str, Any]]:
    s = get_settings()
    key = s.supabase_secret_key.get_secret_value()
    response = await http.post(
        f"{s.supabase_url.rstrip('/')}/rest/v1/rpc/{name}",
        headers={"apikey": key, "Content-Type": "application/json"},
        json={},
        timeout=60,
    )
    response.raise_for_status()
    rows = response.json()
    return rows if isinstance(rows, list) else []


def _configured() -> bool:
    s = get_settings()
    key = s.supabase_secret_key.get_secret_value().strip()
    return bool(s.supabase_url.strip()) and bool(key) and key.lower() not in {"unset", "none"}


async def build(
    jobs_file: dict[str, Any], previous: dict[str, Any], *, client: httpx.AsyncClient | None = None
) -> dict[str, Any]:
    """The new picks.json."""
    now = datetime.now(UTC)
    deadline = time.monotonic() + BUDGET_S
    jobs = open_jobs(jobs_file, now)
    live = {j["id"] for j in jobs if j.get("id")}
    tracks = {k: v for k, v in (previous.get("tracks") or {}).items() if v in TRACKS}
    weights = previous.get("cohorts") or {}
    trained_at = previous.get("trained_at")
    own = client is None
    http = client or httpx.AsyncClient(timeout=get_settings().mistral_timeout_s)
    try:
        tracks.update(await label_tracks(http, jobs, tracks, deadline))
        if _configured():
            try:
                await _rpc(http, "prune_old")  # 12 months unseen: deleted
                weights = cohort_weights(
                    await _rpc(http, "picks_training"), await _rpc(http, "picks_jobs"), tracks
                )
                trained_at = now.isoformat(timespec="seconds")
            except (httpx.HTTPError, ValueError, KeyError, TypeError) as exc:
                log.warning("Couldn't read the shared choices (%s); weights kept", exc)
    finally:
        if own:
            await http.aclose()
    # Open jobs' tracks first, then the newest of the rest (decisions refer to older jobs too).
    kept = {k: v for k, v in tracks.items() if k in live}
    for k, v in reversed(list(tracks.items())):
        if len(kept) >= KEEP_TRACKS:
            break
        kept.setdefault(k, v)
    return {
        "generated_at": now.isoformat(timespec="seconds"),
        "trained_at": trained_at,
        "cohorts": weights,
        "tracks": kept,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m app.services.picks")
    parser.add_argument("--jobs", required=True, type=Path)
    parser.add_argument("--previous", type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    jobs_file = json.loads(args.jobs.read_text(encoding="utf-8"))
    previous = bank.load_raw(args.previous) if args.previous else {}
    picks = asyncio.run(build(jobs_file, previous))
    args.out.write_text(json.dumps(picks, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(
        json.dumps(
            {"tracks": len(picks["tracks"]), "cohorts": len(picks["cohorts"]), "trained": picks["trained_at"]}
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
