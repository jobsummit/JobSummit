"""Gemini quota handling: the free tier counts requests (about 20 a day per model),
so several PDFs share a request, a daily quota isn't retried, the next model is
tried, and a PDF that couldn't be read for quota reasons goes back in the queue."""

import json
from types import SimpleNamespace

import httpx
import pymupdf
import pytest
from google.genai import errors as genai_errors
from google.genai import types
from tenacity import AsyncRetrying, RetryCallState

from app.core.config import get_settings
from app.domain.enums import ItemKind, ItemStatus
from app.models import DiscoveredItem
from app.services import pdf_parser
from app.services.discovery_pipeline import return_to_queue
from app.services.pdf_parser import (
    GeminiQuotaExhausted,
    GeminiUnavailable,
    extract_notification,
    extract_notifications,
)

PDF = b"%PDF-1.4 fake notification"

EXTRACTION = {
    "organization": "Bharat Electronics Limited",
    "exam_name": "Probationary Engineer 2026",
    "advertisement_no": None,
    "official_portal_url": None,
    "application_start_date": "2026-10-01",
    "application_end_date": "2026-11-15",
    "application_end_time": None,
    "exam_date": None,
    "age_as_on_date": "2026-10-01",
    "fee_payment_last_date": None,
    "correction_window_start_date": None,
    "correction_window_end_date": None,
    "admit_card_release_date": None,
    "exam_end_date": None,
    "answer_key_date": None,
    "result_date": None,
    "employment_type": None,
    "application_fees": [],
    "fee_refund": None,
    "general_age_relaxations": [],
    "posts": [
        {
            "post_code": None,
            "post_name": "Probationary Engineer",
            "min_age": None,
            "max_age_ur": 25,
            "age_as_on_date": None,
            "eligible_degrees": ["B.E./B.Tech"],
            "qualification_summary": None,
            "eligibility_text": None,
            "min_qualification_level": None,
            "open_to_any_graduate": None,
            "open_to_any_post_graduate": None,
            "min_experience_years": None,
            "pay_scale": None,
            "monthly_pay_min": None,
            "vacancies": {
                "ur": 10,
                "sc": 3,
                "st": 1,
                "obc": 5,
                "ews": 2,
                "total": 21,
                "pwbd": None,
                "ex_serviceman": None,
            },  # fmt: skip
            "age_relaxations": [],
        }
    ],
}

# What the API actually says once the day's free requests are used up (Oct 2026):
# no "PerDay" in the message, but an hours-long retry delay.
LIVE_DAILY_MESSAGE = (
    "You exceeded your current quota, please check your plan and billing details. For more "
    "information on this error, head to: https://ai.google.dev/gemini-api/docs/rate-limits.\n"
    "* Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, "
    "limit: 20, model: gemini-3.8-flash\nPlease retry in 22h28m9.716s."
)


def _api_error(code: int, message: str, *details: dict) -> genai_errors.APIError:
    return genai_errors.APIError(
        code,
        {
            "error": {
                "code": code,
                "message": message,
                "status": "RESOURCE_EXHAUSTED",
                "details": list(details),
            }
        },
    )


def _quota_error(quota_id: str) -> genai_errors.APIError:
    return _api_error(
        429,
        "You exceeded your current quota, please check your plan and billing details.",
        {"@type": "type.googleapis.com/google.rpc.QuotaFailure", "violations": [{"quotaId": quota_id}]},
    )


def _pdf(name: str, pages: int = 1) -> bytes:
    """A real PDF that prints its name on every page."""
    doc = pymupdf.open()
    for _ in range(pages):
        doc.new_page().insert_text((72, 72), name)
    data = doc.tobytes()
    doc.close()
    return data


def _names(contents: list) -> list[str]:
    """Which test PDFs a request carried, in order."""
    names = []
    for part in contents:
        blob = getattr(getattr(part, "inline_data", None), "data", None)
        if blob is None:
            continue
        try:
            with pymupdf.open(stream=blob, filetype="pdf") as doc:
                names.append(doc[0].get_text().strip())
        except Exception:  # noqa: BLE001 - the fake PDF bytes above aren't a real PDF
            names.append("?")
    return names


def _extraction(name: str) -> dict:
    return {**EXTRACTION, "exam_name": name}


def _answer(names: list[str], skip: tuple[str, ...] = ()) -> dict:
    """A correct answer for the PDFs in a request: one notification, or numbered documents."""
    if len(names) == 1:
        return _extraction(names[0])
    documents = [
        {"document_number": n, "notification": _extraction(name)}
        for n, name in enumerate(names, start=1)
        if name not in skip
    ]
    return {"documents": documents[::-1]}  # order doesn't matter, the numbers do


class FakeClient:
    """Stands in for genai.Client: per-model behaviour (an answer, an error, or a
    function of the PDF names in the request); records every request."""

    def __init__(self, behaviour: dict[str, object]):
        self.behaviour = behaviour
        self.calls: list[str] = []
        self.batches: list[list[str]] = []
        self.aio = SimpleNamespace(models=SimpleNamespace(generate_content=self._generate))

    async def _generate(self, *, model, contents, config):
        self.calls.append(model)
        names = _names(contents)
        self.batches.append(names)
        outcome = self.behaviour[model]
        if callable(outcome):
            outcome = outcome(names)
        if isinstance(outcome, Exception):
            raise outcome
        if isinstance(outcome, SimpleNamespace):
            return outcome
        return SimpleNamespace(text=json.dumps(outcome), candidates=[])


@pytest.fixture(autouse=True)
def _fresh_model_state(monkeypatch):
    pdf_parser._unusable_models.clear()
    pdf_parser.request_counts.clear()
    settings = get_settings()
    monkeypatch.setattr(settings, "gemini_model", "main-model")
    monkeypatch.setattr(settings, "gemini_fallback_models", "lite-model")
    monkeypatch.setattr(settings, "gemini_max_attempts", 3)
    monkeypatch.setattr(settings, "gemini_batch_docs", 3)
    monkeypatch.setattr(settings, "gemini_batch_pages", 48)
    monkeypatch.setattr(pdf_parser, "_mistral_out", False)
    yield
    pdf_parser._unusable_models.clear()
    pdf_parser.request_counts.clear()


async def test_daily_quota_is_not_retried_and_the_fallback_model_reads_the_pdf():
    client = FakeClient(
        {
            "main-model": _quota_error("GenerateRequestsPerDayPerProjectPerModel-FreeTier"),
            "lite-model": EXTRACTION,
        }
    )
    parsed = await extract_notification(PDF, client=client)
    assert client.calls == ["main-model", "lite-model"]  # no retries of the daily-quota error
    assert parsed.extraction_model == "lite-model"
    assert parsed.posts[0].allowed_degrees == ["B_TECH"]

    # The exhausted model is skipped for the rest of the run.
    await extract_notification(PDF, client=client)
    assert client.calls == ["main-model", "lite-model", "lite-model"]


async def test_all_models_out_of_quota_raises_quota_exhausted():
    day = _quota_error("GenerateRequestsPerDayPerProjectPerModel-FreeTier")
    client = FakeClient({"main-model": day, "lite-model": day})
    with pytest.raises(GeminiQuotaExhausted):
        await extract_notification(PDF, client=client)
    with pytest.raises(GeminiQuotaExhausted):  # nothing left to try: no more calls
        await extract_notification(PDF, client=client)
    assert client.calls == ["main-model", "lite-model"]
    assert not pdf_parser.quota_left()


async def test_unknown_fallback_model_is_skipped():
    missing = genai_errors.APIError(404, {"error": {"code": 404, "message": "models/x is not found"}})
    client = FakeClient({"main-model": EXTRACTION, "lite-model": missing})
    parsed = await extract_notification(PDF, client=client)
    assert parsed.extraction_model == "main-model"


def test_the_live_daily_quota_message_is_recognised():
    daily = _api_error(429, LIVE_DAILY_MESSAGE)
    assert pdf_parser._retry_delay_s(daily) == pytest.approx(22 * 3600 + 28 * 60 + 9.716)
    assert pdf_parser._is_daily_quota(daily)
    assert not pdf_parser._is_retryable(daily)

    retry_info = _api_error(
        429,
        "Resource exhausted.",
        {"@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "80889s"},
    )
    assert pdf_parser._is_daily_quota(retry_info)

    no_free_quota = _api_error(
        429, LIVE_DAILY_MESSAGE.replace("limit: 20", "limit: 0").replace("22h28m9.716s", "9s")
    )
    assert pdf_parser._is_daily_quota(no_free_quota)


def test_a_per_minute_limit_is_retried_after_the_wait_the_api_asks_for():
    minute = _api_error(
        429, LIVE_DAILY_MESSAGE.replace("limit: 20", "limit: 10").replace("22h28m9.716s", "39.4s")
    )
    assert not pdf_parser._is_daily_quota(minute)
    assert pdf_parser._is_retryable(minute)

    state = RetryCallState(AsyncRetrying(), None, (), {})
    state.set_exception((genai_errors.APIError, minute, None))
    assert pdf_parser._wait(state) == pytest.approx(39.4)


async def test_several_pdfs_share_one_request():
    client = FakeClient({"main-model": _answer})
    out = await extract_notifications([_pdf("Alpha"), _pdf("Bravo"), _pdf("Charlie")], client=client)
    assert [o.exam_name for o in out] == ["Alpha", "Bravo", "Charlie"]
    assert {o.extraction_model for o in out} == {"main-model"}
    assert client.batches == [["Alpha", "Bravo", "Charlie"]]
    assert pdf_parser.usage() == {"requests": {"main-model": 1}, "models_skipped": []}


async def test_a_pdf_missing_from_the_shared_answer_is_read_alone():
    client = FakeClient({"main-model": lambda names: _answer(names, skip=("Bravo",))})
    out = await extract_notifications([_pdf("Alpha"), _pdf("Bravo"), _pdf("Charlie")], client=client)
    assert [o.exam_name for o in out] == ["Alpha", "Bravo", "Charlie"]
    assert client.batches == [["Alpha", "Bravo", "Charlie"], ["Bravo"]]


async def test_a_cut_off_shared_answer_is_asked_again_in_halves():
    cut_off = SimpleNamespace(
        text='{"documents": [{"document_number": 1, "notifi',
        candidates=[SimpleNamespace(finish_reason=types.FinishReason.MAX_TOKENS)],
    )
    client = FakeClient({"main-model": lambda names: cut_off if len(names) == 3 else _answer(names)})
    out = await extract_notifications([_pdf("Alpha"), _pdf("Bravo"), _pdf("Charlie")], client=client)
    assert [o.exam_name for o in out] == ["Alpha", "Bravo", "Charlie"]
    assert client.batches == [["Alpha", "Bravo", "Charlie"], ["Alpha"], ["Bravo", "Charlie"]]


async def test_page_budget_decides_how_many_pdfs_share_a_request(monkeypatch):
    monkeypatch.setattr(get_settings(), "gemini_batch_pages", 25)
    client = FakeClient({"main-model": _answer})
    pdfs = [_pdf("Alpha", pages=10), _pdf("Bravo", pages=10), _pdf("Charlie", pages=10), b"not a pdf"]
    out = await extract_notifications(pdfs, client=client)
    assert [o.exam_name for o in out[:3]] == ["Alpha", "Bravo", "Charlie"]
    assert isinstance(out[3], pdf_parser.ExtractionError)
    assert client.batches == [["Alpha", "Bravo"], ["Charlie"]]


async def test_pdfs_left_unread_when_every_model_runs_out_are_marked_as_such(monkeypatch):
    monkeypatch.setattr(get_settings(), "gemini_batch_docs", 2)
    day = _api_error(429, LIVE_DAILY_MESSAGE)
    client = FakeClient(
        {
            "main-model": lambda names: _answer(names) if names == ["Alpha", "Bravo"] else day,
            "lite-model": day,
        }
    )
    out = await extract_notifications(
        [_pdf(n) for n in ("Alpha", "Bravo", "Charlie", "Delta")], client=client
    )
    assert [o.exam_name for o in out[:2]] == ["Alpha", "Bravo"]
    assert all(isinstance(o, GeminiQuotaExhausted) for o in out[2:])
    assert client.calls == ["main-model", "main-model", "lite-model"]  # daily quota: no retries
    assert not pdf_parser.quota_left()
    assert pdf_parser.usage()["models_skipped"] == ["lite-model", "main-model"]


async def test_no_answer_is_worth_another_try_later():
    client = FakeClient({"main-model": httpx.ReadTimeout("timed out")})
    out = await extract_notifications([_pdf("Alpha"), _pdf("Bravo")], client=client)
    assert all(isinstance(o, GeminiUnavailable) for o in out)
    assert client.batches == [["Alpha", "Bravo"], ["Alpha"], ["Bravo"]]  # smaller requests first
    assert pdf_parser.quota_left()  # a timeout says nothing about the quota


def test_quota_failure_puts_the_pdf_back_in_the_queue():
    item = DiscoveredItem(
        kind=ItemKind.NOTIFICATION_PDF, status=ItemStatus.FAILED, attempts=1, error="Gemini API error 429"
    )
    return_to_queue(item)
    assert (item.status, item.attempts, item.error) == (ItemStatus.PENDING, 0, None)


async def test_a_job_page_text_is_read_when_the_pdf_was_out_of_reach():
    seen: list[list] = []

    def answer(names):
        return _answer(names) if names else _extraction("RRB NTPC")

    client = FakeClient({"main-model": answer})
    original = client._generate

    async def spy(*, model, contents, config):
        seen.append(contents)
        return await original(model=model, contents=contents, config=config)

    client.aio.models.generate_content = spy
    page = "Job page: https://sarkariresult.com.cm/rrb-ntpc/\nTitle: RRB NTPC\n\n" + "Important dates " * 50
    out = await extract_notifications([page], client=client)
    assert out[0].exam_name == "RRB NTPC"
    assert page in seen[0]  # sent as text, not as a PDF part


# -----------------------------------------------------------------------------
# Mistral: the backup once every Gemini model is out of quota
# -----------------------------------------------------------------------------


def _text_pdf(name: str) -> bytes:
    """A PDF with a real text layer (enough for Mistral to read)."""
    doc = pymupdf.open()
    page = doc.new_page()
    page.insert_textbox(page.rect + (40, 40, -40, -40), f"{name}\n" + "Recruitment notification. " * 60)
    data = doc.tobytes()
    doc.close()
    return data


def _mistral(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


def _mistral_answer(body: dict) -> httpx.Response:
    return httpx.Response(200, json={"choices": [{"message": {"content": json.dumps(body)}}]})


@pytest.fixture
def mistral_on(monkeypatch):
    from pydantic import SecretStr

    monkeypatch.setattr(get_settings(), "mistral_api_key", SecretStr("test-mistral"))
    monkeypatch.setattr(get_settings(), "mistral_models", "ministral-14b-latest,mistral-small-latest")
    monkeypatch.setattr("app.services.mistral_reader.wait_exponential_jitter", lambda **_: lambda _state: 0)
    from app.services import mistral_reader

    mistral_reader._refused.clear()
    yield
    mistral_reader._refused.clear()


async def test_mistral_reads_what_gemini_had_no_quota_left_for(mistral_on):
    day = _api_error(429, LIVE_DAILY_MESSAGE)
    gemini = FakeClient({"main-model": day, "lite-model": day})
    sent: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        sent.append(body)
        assert request.headers["Authorization"] == "Bearer test-mistral"
        if body["model"] == "ministral-14b-latest":  # not in this account's free plan
            return httpx.Response(429, json={"message": "Rate limit exceeded", "code": "1300"})
        answer = {
            k: v for k, v in _extraction("Read by Mistral").items() if k != "exam_date"
        }  # a key left out
        return _mistral_answer(answer)

    out = await extract_notifications([_text_pdf("Alpha")], client=gemini, mistral_client=_mistral(handler))
    assert out[0].exam_name == "Read by Mistral"
    assert out[0].extraction_model == "mistral-small-latest"  # after the first model refused
    assert sent[-1]["response_format"] == {"type": "json_object"}
    assert "Alpha" in sent[-1]["messages"][1]["content"]  # the PDF's text, not the PDF
    assert pdf_parser.quota_left()  # Mistral can still read more this run
    assert pdf_parser.usage()["requests"]["mistral-small-latest"] == 1

    # The refusing model isn't asked again in this run.
    sent.clear()
    await extract_notifications([_text_pdf("Bravo")], client=gemini, mistral_client=_mistral(handler))
    assert [b["model"] for b in sent] == ["mistral-small-latest"]


async def test_when_mistral_is_rate_limited_too_the_pdf_waits_for_the_next_run(mistral_on, monkeypatch):
    monkeypatch.setattr("app.services.mistral_reader.wait_exponential_jitter", lambda **_: lambda _state: 0)
    day = _api_error(429, LIVE_DAILY_MESSAGE)
    gemini = FakeClient({"main-model": day, "lite-model": day})
    client = _mistral(lambda _request: httpx.Response(429, json={"message": "Requests rate limit exceeded"}))
    out = await extract_notifications(
        [_text_pdf("Alpha"), _text_pdf("Bravo")], client=gemini, mistral_client=client
    )
    assert all(isinstance(o, GeminiQuotaExhausted) for o in out)
    assert not pdf_parser.quota_left()


async def test_a_scanned_pdf_waits_for_gemini_instead_of_going_to_mistral(mistral_on):
    day = _api_error(429, LIVE_DAILY_MESSAGE)
    gemini = FakeClient({"main-model": day, "lite-model": day})

    def handler(_request):  # never called: there is no text to send
        raise AssertionError("Mistral was asked to read an empty page")

    out = await extract_notifications([_pdf("x")], client=gemini, mistral_client=_mistral(handler))
    assert isinstance(out[0], GeminiQuotaExhausted)
