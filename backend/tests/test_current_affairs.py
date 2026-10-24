import asyncio
import json
import time
from datetime import date

import httpx
from pydantic import SecretStr

from app.core.config import get_settings
from app.services import current_affairs as ca
from app.services import practice_bank

FEED = """<?xml version="1.0" encoding="utf-8"?><rss version="2.0"><channel><title>Press Information Bureau</title>
<item><title>PM launches PM-SETU scheme for ITIs</title><link>https://pib.gov.in/PressReleaseIframePage.aspx?PRID=101</link></item>
<item><title>Prime Minister extends greetings on Raising Day</title><link>https://pib.gov.in/PressReleaseIframePage.aspx?PRID=102</link></item>
<item><title>Old news</title><link>https://pib.gov.in/PressReleaseIframePage.aspx?PRID=100</link></item>
</channel></rss>"""  # fmt: skip


def _page(day: str, body: str) -> str:
    return (
        "<html><head><script>var x = 1;</script></head><body><div class='ReleaseDateSubHeaddateTime'>"
        f"Posted On: {day} 10:47AM by PIB Delhi</div><p>{body}</p></body></html>"
    )


SCHEME = (
    "The Prime Minister launched PM-SETU, a scheme to upgrade 1,000 government ITIs with an outlay of "
    "Rs 60,000 crore, in Varanasi on 23 October 2026. " * 3
)


def _reply(obj):
    return httpx.Response(200, json={"choices": [{"message": {"content": json.dumps(obj)}}]})


def test_feed_and_release_text():
    assert ca.feed_items(FEED)[:2] == [
        ("101", "PM launches PM-SETU scheme for ITIs"),
        ("102", "Prime Minister extends greetings on Raising Day"),
    ]
    day, text = ca.release_text(_page("24 OCT 2026", SCHEME))
    assert day == date(2026, 10, 24)
    assert text.startswith("The Prime Minister launched PM-SETU") and "var x" not in text
    assert ca.week_of(date(2026, 10, 24)) == "2026-10-19"
    assert ca.release_text("<p>no date here</p>") == (None, "")


def test_questions_come_from_the_release_and_both_models_agree(tmp_path, monkeypatch):
    monkeypatch.setattr(get_settings(), "mistral_api_key", SecretStr("test-key"))
    path = tmp_path / "current.json"
    # Release 100 was read last run; a question from 9 weeks ago falls out.
    practice_bank.save(path, "current", [
        {"id": "old", "t": "Sports", "q": "An old question about sport?", "o": ["a", "b", "c", "d"], "a": 0,
         "w": "2026-08-17"},
    ], extra={"read": ["100"]})  # fmt: skip
    fetched = []

    def answer(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        if "RssMain" in url:
            return httpx.Response(200, text=FEED)
        if "PressReleaseIframePage" in url:
            fetched.append(url)
            return httpx.Response(
                200, text=_page("24 OCT 2026", SCHEME if "PRID=101" in url else "Greetings. " * 50)
            )
        body = json.loads(request.content)
        if body["messages"][0]["content"] == ca.WRITE:
            assert "PM-SETU" in body["messages"][1]["content"]
            q = {"r": 0, "topic": "Schemes & policies", "q": "How many ITIs will the PM-SETU scheme upgrade?",
                 "options": ["500", "1,000", "1,500", "2,000"], "answer": 1, "explanation": "1,000 ITIs."}  # fmt: skip
            wrong = {**q, "q": "Where was PM-SETU launched?", "options": ["Delhi", "Varanasi", "Patna", "Pune"],
                     "answer": 0}  # fmt: skip
            return _reply({"questions": [q, wrong, {**q, "r": 7}]})
        assert body["model"] == "checker-model"
        return _reply({"answers": [{"i": 0, "answer": 1}, {"i": 1, "answer": 1}]})

    monkeypatch.setattr(get_settings(), "practice_models", "writer-model,checker-model")
    models = practice_bank._Models(["writer-model", "checker-model"])
    client = httpx.AsyncClient(transport=httpx.MockTransport(answer))
    added = asyncio.run(
        ca.grow_current(client, models, path, time.monotonic() + 60, today=date(2026, 10, 24))
    )

    saved = practice_bank.load_raw(path)
    assert added == 1
    assert len(fetched) == 2  # 100 was read before
    assert [q["q"] for q in saved["questions"]] == ["How many ITIs will the PM-SETU scheme upgrade?"]
    q = saved["questions"][0]
    assert (q["t"], q["w"], q["src"], q["a"]) == (
        "Schemes & policies", "2026-10-19", "https://pib.gov.in/PressReleasePage.aspx?PRID=101", 1,
    )  # fmt: skip
    assert set(saved["read"]) == {"100", "101", "102"}


def test_pib_unreachable_changes_nothing(tmp_path):
    def answer(request):
        return httpx.Response(503)

    models = practice_bank._Models(["w", "c"])
    client = httpx.AsyncClient(transport=httpx.MockTransport(answer))
    assert asyncio.run(ca.grow_current(client, models, tmp_path / "current.json", time.monotonic() + 60)) == 0
    assert not (tmp_path / "current.json").exists()
