import asyncio
import json

import httpx
from pydantic import SecretStr

from app.core.config import get_settings
from app.services import notice_labels


def test_the_apps_exam_list_is_read_from_its_code():
    catalog = notice_labels.load_catalog()
    ids = {e["id"] for e in catalog}
    assert len(catalog) > 60
    assert {"rrb-ntpc-graduate", "rrb-ntpc-ug", "ibps-rrb-clerk", "ibps-po", "sbi-clerk"} <= ids
    ug = next(e for e in catalog if e["id"] == "rrb-ntpc-ug")
    assert ug["board"] == "Railway Recruitment Boards" and "ntpc 10+2" in ug["aliases"]


def _notices(*titles):
    return [{"title": t, "url": f"https://agg.example/{i}"} for i, t in enumerate(titles)]


def test_labels_known_from_the_last_file_are_not_asked_again(monkeypatch):
    monkeypatch.setattr(get_settings(), "mistral_api_key", SecretStr("test-key"))
    asked: list[list[str]] = []

    def answer(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        titles = body["messages"][1]["content"].split("Notices:\n", 1)[1].splitlines()
        asked.append(titles)
        labels = [
            {"i": 0, "exam": "rrb-ntpc-graduate", "advert": "CEN 06/2025", "year": "2026", "stage": "skill"},
            {"i": 1, "exam": "made-up-exam", "advert": "CEN 05/2024", "stage": "the third one", "numeral": "xv",
             "year": "soon"},
        ]  # fmt: skip
        content = json.dumps({"labels": labels})
        return httpx.Response(200, json={"choices": [{"message": {"content": content}}]})

    notices = _notices(
        "RRB NTPC Graduate Level (CEN 06/2025) CBTST Admit Card 2026",
        "RRB Ministerial & Isolated Category Junior Translator (Hindi) Result",
        "IBPS SO XVI Mains Admit Card 2026",
    )
    known = {"https://agg.example/2": {"exam": "ibps-so", "advert": "CRP SPL-XVI", "stage": "mains"}}
    client = httpx.AsyncClient(transport=httpx.MockTransport(answer))
    requests = asyncio.run(notice_labels.label_notices(notices, known, client=client))

    assert requests == 1
    assert len(asked[0]) == 2  # the IBPS one came from the last file
    assert notices[0]["about"] == {
        "exam": "rrb-ntpc-graduate",
        "advert": "CEN 06/2025",
        "year": "2026",
        "numeral": None,
        "stage": "skill",
    }
    # Not an exam of the list, not a stage, not a year, an advert the title doesn't
    # print: dropped, not guessed.
    assert notices[1]["about"] == {"exam": None, "advert": None, "year": None, "numeral": "XV", "stage": None}
    assert notices[2]["about"] == {"exam": "ibps-so", "advert": None, "stage": "mains"}


def test_a_bare_list_or_chunked_answer_still_counts(monkeypatch):
    monkeypatch.setattr(get_settings(), "mistral_api_key", SecretStr("test-key"))
    label = [{"i": 0, "exam": "ssc-cgl", "stage": "tier-1"}]
    for content in (json.dumps(label), [{"type": "text", "text": json.dumps({"labels": label})}]):
        reply = {"choices": [{"message": {"content": content}}]}
        client = httpx.AsyncClient(
            transport=httpx.MockTransport(lambda r, reply=reply: httpx.Response(200, json=reply))
        )
        notices = _notices("SSC CGL Tier 1 Admit Card 2026")
        assert asyncio.run(notice_labels.label_notices(notices, {}, client=client)) == 1
        assert notices[0]["about"]["exam"] == "ssc-cgl"


def test_without_a_key_notices_go_unlabelled(monkeypatch):
    monkeypatch.setattr(get_settings(), "mistral_api_key", SecretStr(""))
    notices = _notices("SSC CGL Tier 1 Admit Card 2026")
    assert asyncio.run(notice_labels.label_notices(notices, {})) == 0
    assert "about" not in notices[0]


def test_mistral_failing_leaves_them_for_the_next_run(monkeypatch):
    monkeypatch.setattr(get_settings(), "mistral_api_key", SecretStr("test-key"))
    client = httpx.AsyncClient(transport=httpx.MockTransport(lambda r: httpx.Response(500)))
    notices = _notices("SSC CGL Tier 1 Admit Card 2026")
    monkeypatch.setattr(notice_labels, "_retryable", lambda exc: False)
    assert asyncio.run(notice_labels.label_notices(notices, {}, client=client)) == 0
    assert "about" not in notices[0]
