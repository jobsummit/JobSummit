"""Gemini Flash PDF extractor.

Two stages:
  1. ``_call_gemini``         PDF(s) -> JSON in the LLM schema (``NotificationExtraction``, loosely typed)
  2. ``normalize_extraction`` -> ``ParsedNotification`` (strict types, sanity checks)

The free tier allows about 20 requests a day per model, so ``extract_notifications``
reads several PDFs in one request, and every call moves on to the next model in
``GEMINI_FALLBACK_MODELS`` once one is out of quota.

Stage 2 is pure and unit-testable. Anything suspicious is recorded in
``review_notes`` instead of failing the whole upload, so a half-good PDF is
still ingested and flagged ``needs_review`` for a human glance.
"""

from __future__ import annotations

import asyncio
import io
import json
import logging
import re
from collections import Counter
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import date, datetime, time
from functools import lru_cache
from pathlib import Path
from zoneinfo import ZoneInfo

import httpx
from dateutil import parser as dateparser
from google import genai
from google.genai import errors as genai_errors
from google.genai import types
from pydantic import ValidationError
from tenacity import (
    AsyncRetrying,
    RetryCallState,
    retry_if_exception,
    stop_after_attempt,
    wait_exponential_jitter,
)

from app.core.config import get_settings
from app.domain.enums import RELAXATION_KEY_EXSM, RELAXATION_KEY_PWBD, Category
from app.domain.qualifications import QualificationLevel
from app.schemas.extraction import (
    BatchExtraction,
    ExtractedRelaxation,
    ExtractedVacancy,
    NotificationExtraction,
    NumberedExtraction,
)
from app.schemas.notification import ParsedNotification, ParsedPost, ParsedTimeline, ParsedVacancy
from app.services import mistral_reader
from app.services.pdf_slicer import PageSelection, select_relevant_pages
from app.services.streams import infer_requirement

log = logging.getLogger(__name__)

INLINE_PDF_LIMIT = 18 * 1024 * 1024  # inline request cap is ~20 MB; larger goes via Files API
_RETRYABLE_HTTP = {429, 500, 502, 503, 504}
_MAX_OUTPUT_TOKENS = 32768
_BATCH_MAX_OUTPUT_TOKENS = 65536  # the Flash / Flash-Lite ceiling: room for several notifications


class ExtractionError(RuntimeError):
    """The PDF could not be turned into a usable notification."""


class GeminiQuotaExhausted(ExtractionError):
    """Every configured model is out of quota for today. Not the PDF's fault:
    the caller should put it back in the queue and stop for this run."""


class GeminiUnavailable(ExtractionError):
    """No answer: a timeout, a network error, or a server error that outlasted the
    retries. Worth trying the PDF again on a later run."""


# Models that ran out of daily quota (or don't exist for this key) during this
# process: skipped until the next run. Quotas are per model, so a fallback helps.
_unusable_models: set[str] = set()
# Requests sent per model during this process: the free tier counts requests, not PDFs.
request_counts: Counter[str] = Counter()


def usage() -> dict[str, object]:
    """What this run used of today's quota (for the pipeline's status.json)."""
    return {"requests": dict(request_counts), "models_skipped": sorted(_unusable_models)}


def quota_left() -> bool:
    return bool(_models_to_try(None)) or (mistral_reader.configured() and not _mistral_out)


# Mistral said "too many requests" this run: leave the rest for the next run.
_mistral_out = False


def _error_blob(exc: genai_errors.APIError) -> str:
    try:
        return f"{exc.message} {json.dumps(exc.details)}"
    except (TypeError, ValueError):
        return str(exc)


# "Please retry in 22h28m9.7s." in the message, or RetryInfo {"retryDelay": "80889s"} in the details.
_RETRY_DELAY = re.compile(r'"retryDelay":\s*"(\d+(?:\.\d+)?)s"')
_RETRY_IN = re.compile(r"retry in\s+((?:\d+(?:\.\d+)?(?:h|ms|m|s))+)", re.IGNORECASE)
_UNIT_SECONDS = {"h": 3600.0, "m": 60.0, "s": 1.0, "ms": 0.001}


def _retry_delay_s(exc: BaseException | None) -> float | None:
    """The wait the API asked for, in seconds, when it says."""
    if not isinstance(exc, genai_errors.APIError):
        return None
    blob = _error_blob(exc)
    if m := _RETRY_DELAY.search(blob):
        return float(m[1])
    if m := _RETRY_IN.search(blob):
        return sum(float(n) * _UNIT_SECONDS[u] for n, u in re.findall(r"(\d+(?:\.\d+)?)(ms|h|m|s)", m[1]))
    return None


def _is_daily_quota(exc: BaseException) -> bool:
    """A 429 that retrying today can't fix: a per-day quota (the message doesn't always
    say "PerDay", but the hours-long retry delay gives it away), or no free quota at all."""
    if not (isinstance(exc, genai_errors.APIError) and exc.code == 429):
        return False
    blob = _error_blob(exc)
    if "PerDay" in blob or re.search(r"\blimit: 0\b", blob):
        return True
    delay = _retry_delay_s(exc)
    return delay is not None and delay > 600


SYSTEM_INSTRUCTION = """\
You are a meticulous data-entry clerk for Indian Government / PSU recruitment notifications.
Extract facts ONLY from the attached PDF (or, when the PDF couldn't be fetched, the text of a
job website's page about the recruitment). Never guess or use outside knowledge.
When several documents are attached, each is a separate notification: read each one on its
own and never carry a fact from one document into another.

Rules:
- If a value is not printed, return null (or an empty list). Do not infer.
- Copy numbers exactly as printed. Vacancy tables: map GEN/General/UR/Unreserved -> ur,
  OBC/OBC-NCL -> obc, PwBD/PH/PWD/Divyang -> pwbd, ESM/Ex-Servicemen -> ex_serviceman.
- If a post's vacancies are split across locations/units, sum them per category.
- Create one entry in `posts` per distinct post code / discipline.
- Dates must be YYYY-MM-DD (convert DD.MM.YYYY / DD-MM-YYYY). Times are 24h HH:MM.
- `age_as_on_date` is the date on which age is reckoned ("age as on ...").
- Age relaxation: list each category separately in years (SC, ST, OBC, EWS, PWBD, EXSM).
  For PwBD, give the relaxation for the UR PwBD candidate (usually 10).
- `eligible_degrees`: one short entry per degree+branch, e.g.
  "B.E./B.Tech Electronics & Communication", "B.E./B.Tech Electrical", "Any Graduate".
- `min_qualification_level`: the LOWEST level that qualifies (10th-pass posts are MATRIC,
  "12th pass" INTERMEDIATE, "Diploma or B.E." DIPLOMA, "Any Graduate" UG, "Any PG" PG).
- `open_to_any_graduate` / `open_to_any_post_graduate`: true only when the notification
  accepts a degree in ANY discipline ("Graduation from a recognised university").
- `min_experience_years`: post-qualification experience only; ignore "desirable" experience.
- `eligibility_text`: the essential-qualification paragraph exactly as printed (English).
- Schedule dates (fee, correction window, admit card, exam end, answer key, result):
  only from an explicit schedule/important-dates table; "tentative" dates are fine.
- `pay_scale`: copy the pay level / scale / fixed pay as printed. `monthly_pay_min`: the entry
  basic pay in rupees per month (7th CPC Level 1 = 18000, L2 = 19900, L3 = 21700, L4 = 25500,
  L5 = 29200, L6 = 35400, L7 = 44900, L8 = 47600, L9 = 53100, L10 = 56100), or the fixed monthly
  pay / stipend; null when nothing is printed.
- `employment_type`: permanent (regular posts), contract (fixed-term / consolidated pay),
  apprenticeship, fellowship (JRF/SRF), or internship.
- `application_fees`: the fee table, one entry per category in rupees (UR for General; 0 for
  "exempted"/"nil"); one ALL entry when everyone pays the same. `fee_refund`: only if printed.
- Bilingual (Hindi/English) PDFs: use the English text.
"""

USER_PROMPT = "Extract the recruitment notification in this PDF into the required JSON schema."
BATCH_PROMPT = (
    "The {count} PDFs above are separate recruitment notifications, each right after its "
    "'Document N:' label. Extract every one of them into `documents`: exactly one entry per "
    "document, with its `document_number`."
)


@lru_cache
def _default_client() -> genai.Client:
    s = get_settings()
    return genai.Client(
        api_key=s.gemini_api_key.get_secret_value(),
        http_options=types.HttpOptions(timeout=s.gemini_timeout_s * 1000),  # milliseconds
    )


def _is_retryable(exc: BaseException) -> bool:
    return isinstance(exc, genai_errors.APIError) and exc.code in _RETRYABLE_HTTP and not _is_daily_quota(exc)


_backoff = wait_exponential_jitter(initial=2, max=60)


def _wait(retry_state: RetryCallState) -> float:
    """Exponential backoff, but never shorter than the wait the API asked for
    (a per-minute limit says "retry in 39s"), and at most 90 s."""
    outcome = retry_state.outcome
    hinted = _retry_delay_s(outcome.exception()) if outcome is not None and outcome.failed else None
    return min(max(hinted or 0.0, _backoff(retry_state)), 90.0)


def _models_to_try(explicit: str | None) -> list[str]:
    if explicit:
        return [explicit]
    s = get_settings()
    names = [s.gemini_model, *(m.strip() for m in s.gemini_fallback_models.split(","))]
    return [m for m in dict.fromkeys(names) if m and m not in _unusable_models]


# =============================================================================
# Public API
# =============================================================================


@dataclass(frozen=True, slots=True)
class _Doc:
    data: bytes | str  # the relevant pages of a long PDF, or a job page's text
    pages: int | None  # None when the PDF can't be opened here (Gemini may still manage)
    selection: PageSelection | None


async def extract_notification(
    pdf: bytes | str | Path,
    *,
    client: genai.Client | None = None,
    model: str | None = None,
) -> ParsedNotification:
    data = pdf if isinstance(pdf, bytes) else await asyncio.to_thread(Path(pdf).read_bytes)
    doc = await _prepare(data)
    text, used_model = await _call_with_fallback(client or _default_client(), [doc.data], model)
    return _to_notification(_single(text), doc, used_model)


async def extract_notifications(
    pdfs: Sequence[bytes | str],
    *,
    client: genai.Client | None = None,
    model: str | None = None,
    mistral_client: httpx.AsyncClient | None = None,
) -> list[ParsedNotification | ExtractionError]:
    """Reads several PDFs (``str``: a job page's text) with as few Gemini requests as possible: up to
    ``gemini_batch_docs`` PDFs (``gemini_batch_pages`` pages) share one request.

    One outcome per PDF, in order: the notification, or that PDF's error. Once every
    Gemini model is out of quota, Mistral (if configured) reads what's left;
    ``GeminiQuotaExhausted`` marks the PDFs nobody could read this run."""
    settings = get_settings()
    client = client or _default_client()
    outcomes: dict[int, ParsedNotification | ExtractionError] = {}
    ready: list[tuple[int, _Doc]] = []
    for i, data in enumerate(pdfs):
        try:
            ready.append((i, await _prepare(data)))
        except ExtractionError as exc:
            outcomes[i] = exc
    for group in _group(ready, max_docs=settings.gemini_batch_docs, max_pages=settings.gemini_batch_pages):
        results = await _read_group(client, [doc for _, doc in group], model)
        outcomes.update((i, result) for (i, _), result in zip(group, results, strict=True))
    if mistral_reader.configured():
        for i, doc in ready:
            if isinstance(outcomes[i], GeminiQuotaExhausted):
                outcomes[i] = await _read_with_mistral(doc, mistral_client)
    return [outcomes[i] for i in range(len(pdfs))]


async def _read_with_mistral(
    doc: _Doc, client: httpx.AsyncClient | None
) -> ParsedNotification | ExtractionError:
    """Anything Mistral can't do goes back in the queue for Gemini tomorrow."""
    global _mistral_out
    if _mistral_out:
        return GeminiQuotaExhausted("Gemini and Mistral are both out of quota for this run.")
    text = (
        doc.data if isinstance(doc.data, str) else await asyncio.to_thread(mistral_reader.pdf_text, doc.data)
    )
    if not text:
        return GeminiQuotaExhausted("A scanned PDF (no text layer): waits for Gemini.")
    try:
        raw, model = await mistral_reader.extract(text, system=SYSTEM_INSTRUCTION, client=client)
        request_counts[model] += 1
        return _to_notification(raw, doc, model)
    except mistral_reader.MistralOutOfQuota as exc:
        log.warning("Mistral out for this run: %s", exc)
        _mistral_out = True
        return GeminiQuotaExhausted(str(exc))
    except (mistral_reader.MistralError, ExtractionError) as exc:
        log.warning("Mistral couldn't read a PDF (%s); it waits for Gemini", exc)
        return GeminiQuotaExhausted(f"Mistral: {exc}")


async def _prepare(data: bytes | str) -> _Doc:
    if isinstance(data, str):
        return _Doc(data, max(1, len(data) // 3000), None)  # ~a page per 3000 characters
    if not data.startswith(b"%PDF-"):
        raise ExtractionError("Input is not a PDF file.")
    settings = get_settings()
    try:
        selection = await asyncio.to_thread(
            select_relevant_pages,
            data,
            min_pages_to_slice=settings.pdf_slice_min_pages,
            max_pages=settings.pdf_slice_max_pages,
        )
    except Exception as exc:  # noqa: BLE001 - malformed PDFs: let Gemini try the original
        log.warning("Page slicing failed, sending the whole PDF: %s", exc)
        return _Doc(data, None, None)
    return _Doc(selection.data, len(selection.kept), selection)


def _group(docs: list[tuple[int, _Doc]], *, max_docs: int, max_pages: int) -> list[list[tuple[int, _Doc]]]:
    """Consecutive PDFs share a request while they fit. One whose page count is
    unknown, or that is too big to send inline, gets a request of its own."""
    groups: list[list[tuple[int, _Doc]]] = []
    shared: list[tuple[int, _Doc]] = []
    for entry in docs:
        doc = entry[1]
        if doc.pages is None or len(doc.data) > INLINE_PDF_LIMIT:
            groups.append([entry])
            continue
        if shared and not _fits(shared, doc, max_docs=max_docs, max_pages=max_pages):
            groups.append(shared)
            shared = []
        shared.append(entry)
    if shared:
        groups.append(shared)
    return groups


def _fits(group: list[tuple[int, _Doc]], doc: _Doc, *, max_docs: int, max_pages: int) -> bool:
    return (
        len(group) < max_docs
        and sum(d.pages or 0 for _, d in group) + (doc.pages or 0) <= max_pages
        and sum(len(d.data) for _, d in group) + len(doc.data) <= INLINE_PDF_LIMIT
    )


async def _read_group(
    client: genai.Client, docs: list[_Doc], explicit: str | None
) -> list[ParsedNotification | ExtractionError]:
    if len(docs) == 1:
        return [await _read_one(client, docs[0], explicit)]
    try:
        text, used_model = await _call_with_fallback(client, [d.data for d in docs], explicit)
        raws = _numbered(text, len(docs))
    except GeminiQuotaExhausted as exc:
        return [exc] * len(docs)
    except ExtractionError as exc:
        # Usually an answer cut off at the output limit (many posts): ask in halves.
        log.warning("Reading %d PDFs in one request failed (%s); splitting it", len(docs), exc)
        mid = len(docs) // 2
        return [
            *await _read_group(client, docs[:mid], explicit),
            *await _read_group(client, docs[mid:], explicit),
        ]
    out: list[ParsedNotification | ExtractionError] = []
    for doc, raw in zip(docs, raws, strict=True):
        if raw is not None:
            try:
                out.append(_to_notification(raw, doc, used_model))
                continue
            except ExtractionError as exc:  # e.g. "no posts": the shared answer may be at fault
                log.warning("Unusable answer for one PDF of a shared request (%s); reading it alone", exc)
        out.append(await _read_one(client, doc, explicit))
    return out


async def _read_one(
    client: genai.Client, doc: _Doc, explicit: str | None
) -> ParsedNotification | ExtractionError:
    try:
        text, used_model = await _call_with_fallback(client, [doc.data], explicit)
        return _to_notification(_single(text), doc, used_model)
    except ExtractionError as exc:
        return exc


def _single(text: str) -> NotificationExtraction:
    try:
        return NotificationExtraction.model_validate_json(text)
    except ValidationError as exc:
        raise ExtractionError(f"Gemini output failed schema validation: {exc}") from exc


def _numbered(text: str, count: int) -> list[NotificationExtraction | None]:
    """A shared answer split per document; one the answer skipped or garbled is None."""
    try:
        entries = json.loads(text)["documents"]
    except (ValueError, KeyError, TypeError) as exc:
        raise ExtractionError(f"Gemini's shared answer is not the expected JSON: {exc}") from exc
    if not isinstance(entries, list):
        raise ExtractionError("Gemini's shared answer has no document list.")
    out: list[NotificationExtraction | None] = [None] * count
    for entry in entries:
        try:
            item = NumberedExtraction.model_validate(entry)
        except ValidationError:
            continue
        n = item.document_number
        if 1 <= n <= count and out[n - 1] is None:
            out[n - 1] = item.notification
    return out


def _to_notification(raw: NotificationExtraction, doc: _Doc, model: str) -> ParsedNotification:
    parsed = normalize_extraction(raw, tz=ZoneInfo(get_settings().timezone))
    parsed.extraction_model = model
    # Only worth a reviewer's attention when something else already looks off.
    if doc.selection is not None and doc.selection.sliced and parsed.review_notes:
        parsed.review_notes.append(doc.selection.describe())
    return parsed


async def _call_with_fallback(
    client: genai.Client, pdfs: list[bytes | str], explicit: str | None
) -> tuple[str, str]:
    """First model with quota left wins. A model that is out of daily quota, or
    unknown to this API key (404), is skipped for the rest of the run."""
    last_error: ExtractionError | None = None
    quota_hit = False
    for name in _models_to_try(explicit):
        try:
            return await _call_gemini(client, pdfs, name), name
        except GeminiQuotaExhausted as exc:
            quota_hit, last_error = True, exc
        except ExtractionError as exc:
            if not str(exc).startswith("Gemini API error 404"):
                raise  # a problem with this PDF, not with the model
            last_error = exc
        log.warning("Gemini model %s unusable for this run: %s", name, last_error)
        _unusable_models.add(name)
    if quota_hit or last_error is None:
        raise GeminiQuotaExhausted("All Gemini models are out of quota for today.")
    raise last_error


# =============================================================================
# Stage 1: Gemini
# =============================================================================


async def _call_gemini(client: genai.Client, pdfs: list[bytes | str], model: str) -> str:
    """The model's JSON answer: one ``NotificationExtraction``, or a ``BatchExtraction``
    when several PDFs share the request."""
    shared = len(pdfs) > 1
    settings = get_settings()
    config = types.GenerateContentConfig(
        system_instruction=SYSTEM_INSTRUCTION,
        response_mime_type="application/json",
        response_schema=BatchExtraction if shared else NotificationExtraction,
        temperature=0.0,
        max_output_tokens=_BATCH_MAX_OUTPUT_TOKENS if shared else _MAX_OUTPUT_TOKENS,
        # A shared answer is several notifications long: give it time to finish.
        http_options=types.HttpOptions(timeout=settings.gemini_timeout_s * 2000) if shared else None,
    )
    retrying = AsyncRetrying(
        retry=retry_if_exception(_is_retryable),
        wait=_wait,
        stop=stop_after_attempt(settings.gemini_max_attempts),
        reraise=True,
    )
    try:
        async for attempt in retrying:
            with attempt:
                response = await _generate(client, pdfs, model, config)
    except genai_errors.APIError as exc:
        if exc.code == 429:
            # Daily quota, or a per-minute limit that outlasted every retry.
            raise GeminiQuotaExhausted(f"Gemini API error 429 ({model}): {exc.message}") from exc
        if exc.code in _RETRYABLE_HTTP:
            raise GeminiUnavailable(f"Gemini API error {exc.code}: {exc.message}") from exc
        raise ExtractionError(f"Gemini API error {exc.code}: {exc.message}") from exc
    except (httpx.TransportError, TimeoutError, ConnectionError) as exc:
        raise GeminiUnavailable(f"Gemini did not answer ({type(exc).__name__}): {exc}") from exc

    candidate = response.candidates[0] if response.candidates else None
    if candidate is not None and candidate.finish_reason == types.FinishReason.MAX_TOKENS:
        raise ExtractionError("Gemini's answer was cut off at the output limit.")
    text = response.text
    if not text:
        reason = candidate.finish_reason if candidate is not None else "no candidates"
        raise ExtractionError(f"Gemini returned an empty response ({reason}).")
    return text


async def _generate(
    client: genai.Client, pdfs: list[bytes | str], model: str, config: types.GenerateContentConfig
) -> types.GenerateContentResponse:
    uploaded: list[types.File] = []
    try:
        contents: list[types.Part | types.File | str] = []
        for n, data in enumerate(pdfs, start=1):
            if len(pdfs) > 1:
                contents.append(f"Document {n}:")
            if isinstance(data, str):
                contents.append(data)  # a job page's text
            elif len(data) <= INLINE_PDF_LIMIT:
                contents.append(types.Part.from_bytes(data=data, mime_type="application/pdf"))
            else:
                file = await client.aio.files.upload(
                    file=io.BytesIO(data), config=types.UploadFileConfig(mime_type="application/pdf")
                )
                uploaded.append(file)
                contents.append(file)
        contents.append(BATCH_PROMPT.format(count=len(pdfs)) if len(pdfs) > 1 else USER_PROMPT)
        request_counts[model] += 1
        return await client.aio.models.generate_content(model=model, contents=contents, config=config)
    finally:
        for file in uploaded:
            if not file.name:
                continue
            try:
                await client.aio.files.delete(name=file.name)
            except Exception:  # noqa: BLE001 - cleanup is best-effort (files auto-expire in 48h)
                log.warning("Failed to delete uploaded Gemini file %s", file.name)


# =============================================================================
# Stage 2: normalisation (pure)
# =============================================================================

_RELAX_ALIASES = {
    "SC": Category.SC.value,
    "ST": Category.ST.value,
    "SCST": None,  # ambiguous combined row; handled below
    "OBC": Category.OBC.value,
    "OBCNCL": Category.OBC.value,
    "EWS": Category.EWS.value,
    "PWBD": RELAXATION_KEY_PWBD,
    "PWD": RELAXATION_KEY_PWBD,
    "PH": RELAXATION_KEY_PWBD,
    "DIVYANG": RELAXATION_KEY_PWBD,
    "EXSM": RELAXATION_KEY_EXSM,
    "ESM": RELAXATION_KEY_EXSM,
    "EXSERVICEMEN": RELAXATION_KEY_EXSM,
    "EXSERVICEMAN": RELAXATION_KEY_EXSM,
}


def _parse_date(raw: str | None, label: str, notes: list[str]) -> date | None:
    if not raw:
        return None
    try:
        d = date.fromisoformat(raw.strip())
    except ValueError:
        try:
            d = dateparser.parse(raw, dayfirst=True).date()
        except (ValueError, OverflowError):
            notes.append(f"Unparseable {label}: {raw!r}")
            return None
    if not 2000 <= d.year <= 2100:
        notes.append(f"Implausible {label}: {d.isoformat()}")
        return None
    return d


def _parse_time(raw: str | None, notes: list[str]) -> time | None:
    if not raw:
        return None
    m = re.fullmatch(r"\s*(\d{1,2})[:.](\d{2})\s*", raw)
    if not m or int(m[1]) > 23 or int(m[2]) > 59:
        notes.append(f"Unparseable closing time {raw!r}; assumed 23:59.")
        return None
    return time(int(m[1]), int(m[2]))


def _relaxations(items: list[ExtractedRelaxation], notes: list[str]) -> dict[str, int]:
    out: dict[str, int] = {}
    for item in items:
        key = re.sub(r"[^A-Z]", "", item.category.upper())
        if not 0 <= item.years <= 20:
            notes.append(f"Ignored implausible relaxation {item.category}: {item.years} yrs")
            continue
        if key == "SCST":
            out.setdefault(Category.SC.value, item.years)
            out.setdefault(Category.ST.value, item.years)
            continue
        canon = _RELAX_ALIASES.get(key)
        if canon is None:
            notes.append(f"Unknown relaxation category {item.category!r} ignored")
            continue
        out[canon] = item.years
    return out


def _vacancy(v: ExtractedVacancy, label: str, notes: list[str]) -> ParsedVacancy:
    cats = {k: max(0, getattr(v, k) or 0) for k in ("ur", "sc", "st", "obc", "ews")}
    cat_sum = sum(cats.values())
    total = max(0, v.total) if v.total is not None else cat_sum
    if v.total is not None and cat_sum and cat_sum != v.total:
        notes.append(f"{label}: category seats sum to {cat_sum} but printed total is {v.total}")
    if cat_sum == 0 and total > 0:
        notes.append(f"{label}: category-wise vacancy break-up missing")
    return ParsedVacancy(
        **cats,
        total=total,
        pwbd=max(0, v.pwbd) if v.pwbd is not None else None,
        ex_serviceman=max(0, v.ex_serviceman) if v.ex_serviceman is not None else None,
    )


def _age(value: int | None, label: str, notes: list[str]) -> int | None:
    if value is None or 14 <= value <= 70:
        return value
    notes.append(f"Ignored implausible {label}: {value}")
    return None


def _clean_url(raw: str | None, notes: list[str]) -> str | None:
    if not raw:
        return None
    url = raw.strip()
    if url.lower().startswith("www."):
        url = "https://" + url
    if not re.match(r"^https?://[^\s/$.?#].[^\s]*$", url, re.IGNORECASE):
        notes.append(f"Ignored invalid portal URL {raw!r}")
        return None
    return url[:1000]


_LEVEL_ALIASES = {"10TH": "MATRIC", "12TH": "INTERMEDIATE", "GRADUATE": "UG", "POSTGRADUATE": "PG"}


def _level(raw: str | None, label: str, notes: list[str]) -> QualificationLevel | None:
    if not raw:
        return None
    key = re.sub(r"[^A-Z0-9]", "", raw.upper())
    try:
        return QualificationLevel(_LEVEL_ALIASES.get(key, key))
    except ValueError:
        notes.append(f"{label}: unknown qualification level {raw!r} ignored")
        return None


def _experience(value: float | None, label: str, notes: list[str]) -> float:
    if value is None or value <= 0:
        return 0.0
    if value > 40:
        notes.append(f"{label}: implausible experience {value} yrs ignored")
        return 0.0
    return round(float(value), 2)


def _monthly_pay(value: int | None, label: str, notes: list[str]) -> int | None:
    if value is None or value <= 0:
        return None
    if not 1000 <= value <= 1_000_000:
        notes.append(f"{label}: implausible monthly pay {value} ignored")
        return None
    return int(value)


_EMPLOYMENT_TYPES = {
    "permanent": "permanent",
    "regular": "permanent",
    "contract": "contract",
    "contractual": "contract",
    "temporary": "contract",
    "apprentice": "apprenticeship",
    "apprenticeship": "apprenticeship",
    "fellowship": "fellowship",
    "internship": "internship",
}


def _employment_type(raw: str | None) -> str | None:
    return _EMPLOYMENT_TYPES.get((raw or "").strip().lower())


def _dedupe(items: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for s in (x.strip() for x in items):
        if s and s.lower() not in seen:
            seen.add(s.lower())
            out.append(s[:200])
    return out


def normalize_extraction(raw: NotificationExtraction, *, tz: ZoneInfo) -> ParsedNotification:
    notes: list[str] = []

    start = _parse_date(raw.application_start_date, "application start date", notes)
    end = _parse_date(raw.application_end_date, "application end date", notes)
    close_at = _parse_time(raw.application_end_time, notes) or time(23, 59, 59)
    deadline = datetime.combine(end, close_at, tzinfo=tz) if end else None
    if deadline is None:
        notes.append("Application deadline not found — job will not appear in the feed.")
    if start and end and start > end:
        notes.append(f"Start date {start} is after end date {end}")

    global_as_on = _parse_date(raw.age_as_on_date, "age cut-off date", notes)
    general_relax = _relaxations(raw.general_age_relaxations, notes)

    posts: list[ParsedPost] = []
    for i, p in enumerate(raw.posts, start=1):
        label = f"Post {p.post_code or i} ({p.post_name[:40]})"
        as_on = _parse_date(p.age_as_on_date, f"{label} age cut-off", notes) or global_as_on
        if as_on is None and end is not None:
            as_on = end
            notes.append(f"{label}: age cut-off not printed; assumed closing date {end}")
        min_age = _age(p.min_age, f"{label} min age", notes)
        max_age = _age(p.max_age_ur, f"{label} max age", notes)
        if min_age is not None and max_age is not None and min_age > max_age:
            notes.append(f"{label}: min age {min_age} > max age {max_age}")

        streams = _dedupe(p.eligible_degrees)
        # The explicit fields win; the degree lines fill whatever the model left out.
        inferred = infer_requirement(streams)
        level = _level(p.min_qualification_level, label, notes) or inferred.min_level
        posts.append(
            ParsedPost(
                post_code=(p.post_code or "").strip()[:60] or None,
                post_name=p.post_name.strip()[:300] or f"Post {i}",
                min_age=min_age,
                base_max_age=max_age,
                age_as_on=as_on,
                eligible_streams=streams,
                qualification_text=p.qualification_summary,
                age_relaxation_overrides={**general_relax, **_relaxations(p.age_relaxations, notes)},
                allowed_degrees=list(inferred.allowed_degrees),
                raw_eligibility_text=(p.eligibility_text or "").strip()[:2000] or None,
                min_qualification_level=level,
                is_open_to_any_graduate=bool(p.open_to_any_graduate) or inferred.open_to_any_graduate,
                is_open_to_any_post_graduate=bool(p.open_to_any_post_graduate)
                or inferred.open_to_any_post_graduate,
                min_experience_years=_experience(p.min_experience_years, label, notes),
                pay_scale=(p.pay_scale or "").strip()[:300] or None,
                monthly_pay_min=_monthly_pay(p.monthly_pay_min, label, notes),
                vacancy=_vacancy(p.vacancies, label, notes),
            )
        )

    if not posts:
        raise ExtractionError("No posts found in the notification.")

    exam_date = _parse_date(raw.exam_date, "exam date", notes)
    timeline = ParsedTimeline(
        fee_deadline=_parse_date(raw.fee_payment_last_date, "fee payment date", notes),
        edit_window_start=_parse_date(raw.correction_window_start_date, "correction window start", notes),
        edit_window_end=_parse_date(raw.correction_window_end_date, "correction window end", notes),
        admit_card_release=_parse_date(raw.admit_card_release_date, "admit card date", notes),
        exam_start=exam_date,
        exam_end=_parse_date(raw.exam_end_date, "exam end date", notes),
        answer_key_release=_parse_date(raw.answer_key_date, "answer key date", notes),
        result_date=_parse_date(raw.result_date, "result date", notes),
    )

    return ParsedNotification(
        organization=raw.organization.strip()[:200] or "Unknown organisation",
        exam_name=raw.exam_name.strip()[:300] or "Untitled recruitment",
        advertisement_no=(raw.advertisement_no or "").strip()[:120] or None,
        portal_url=_clean_url(raw.official_portal_url, notes),
        application_start=datetime.combine(start, time(0, 0), tzinfo=tz) if start else None,
        application_deadline=deadline,
        exam_date=exam_date,
        posts=posts,
        timeline=timeline,
        employment_type=_employment_type(raw.employment_type),
        fees=_fees(raw.application_fees),
        fee_refund=(raw.fee_refund or "").strip()[:300] or None,
        review_notes=notes,
    )


_FEE_CATEGORIES = {
    "UR": "UR", "GEN": "UR", "GENERAL": "UR", "OBC": "OBC", "OBC-NCL": "OBC", "EWS": "EWS", "SC": "SC",
    "ST": "ST", "PWBD": "PWBD", "PWD": "PWBD", "PH": "PWBD", "WOMEN": "WOMEN", "FEMALE": "WOMEN",
    "EXSM": "EXSM", "ESM": "EXSM", "EX-SERVICEMEN": "EXSM", "ALL": "ALL",
}  # fmt: skip


def _fees(raw: list | None) -> dict[str, int]:
    """Known categories with a plausible amount (a fee above Rs 5,000 is a misread)."""
    out: dict[str, int] = {}
    for f in raw or []:
        key = _FEE_CATEGORIES.get((f.category or "").strip().upper().replace(" ", ""))
        if key and isinstance(f.amount, int) and 0 <= f.amount <= 5000 and key not in out:
            out[key] = f.amount
    return out
