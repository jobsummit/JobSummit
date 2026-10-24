import asyncio
import json
import math

import httpx
from pydantic import SecretStr

from app.core.config import get_settings
from app.services import picks

JOBS = {
    "jobs": [
        {"id": "j1", "exam_name": "SSC CGL 2026", "organization": "SSC", "application_deadline": "2099-01-01T00:00:00+00:00",
         "posts": [{"post_name": "Assistant Section Officer"}]},
        {"id": "j2", "exam_name": "RRB JE 2026", "organization": "RRB", "application_deadline": "2099-01-01T00:00:00+00:00",
         "posts": [{"post_name": "Junior Engineer"}]},
        {"id": "old", "exam_name": "Closed", "organization": "X", "application_deadline": "2001-01-01T00:00:00+00:00",
         "posts": []},
    ]
}  # fmt: skip


def _reply(obj):
    return httpx.Response(200, json={"choices": [{"message": {"content": json.dumps(obj)}}]})


def test_weights_are_log_odds_shrunk_by_how_many_people():
    assert picks.weight(9, 0, 10) == math.log(10) * 0.5
    assert picks.weight(0, 0, 100) == 0
    assert picks.weight(0, 9, 1000) < -2


def test_cohort_weights_with_tracks():
    features = [
        {"cohort": "deg:B_TECH", "feature": "cat:railway", "applied": 30, "rejected": 2, "people": 20},
        {
            "cohort": "deg:B_TECH",
            "feature": "cat:bank",
            "applied": 3,
            "rejected": 3,
            "people": 6,
        },  # even: dropped
        {"cohort": "all", "feature": "cat:ssc", "applied": 2, "rejected": 20, "people": 40},
    ]
    jobs = [{"cohort": "deg:B_TECH", "job_id": "j2", "applied": 8, "rejected": 0}]
    w = picks.cohort_weights(features, jobs, {"j2": "engineering"})
    assert w["deg:B_TECH"]["cat:railway"] > 1.5
    assert "cat:bank" not in w["deg:B_TECH"]
    assert w["all"]["cat:ssc"] < -1
    assert w["deg:B_TECH"]["track:engineering"] > 0


def test_build_labels_new_jobs_and_learns_from_the_shared_choices(monkeypatch):
    monkeypatch.setattr(get_settings(), "mistral_api_key", SecretStr("test-key"))
    monkeypatch.setattr(get_settings(), "supabase_secret_key", SecretStr("sb_secret_test"))
    asked = []

    def answer(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        if "/rpc/picks_training" in url:
            assert request.headers["apikey"] == "sb_secret_test"
            return httpx.Response(200, json=[
                {"cohort": "lvl:UG", "feature": "cat:ssc", "applied": 40, "rejected": 1, "people": 30}])  # fmt: skip
        if "/rpc/picks_jobs" in url:
            return httpx.Response(
                200, json=[{"cohort": "deg:BSC", "job_id": "j1", "applied": 6, "rejected": 0}]
            )
        body = json.loads(request.content)
        listed = body["messages"][1]["content"]
        asked.append(listed)
        assert (
            "Closed" not in listed and "SSC CGL" not in listed
        )  # j1 was labelled before; closed jobs aren't
        return _reply({"tracks": [{"i": 0, "track": "engineering"}]})

    previous = {"tracks": {"j1": "officer", "gone": "teaching"}, "cohorts": {}}
    client = httpx.AsyncClient(transport=httpx.MockTransport(answer))
    out = asyncio.run(picks.build(JOBS, previous, client=client))

    assert len(asked) == 1
    assert out["tracks"] == {"j1": "officer", "j2": "engineering", "gone": "teaching"}
    assert out["cohorts"]["lvl:UG"]["cat:ssc"] > 2
    assert out["cohorts"]["deg:BSC"]["track:officer"] > 0
    assert out["trained_at"]


def test_without_the_secret_weights_stay(monkeypatch):
    monkeypatch.setattr(get_settings(), "mistral_api_key", SecretStr(""))
    monkeypatch.setattr(get_settings(), "supabase_secret_key", SecretStr(""))

    def answer(request):
        raise AssertionError("nothing asked")

    previous = {"tracks": {}, "cohorts": {"all": {"cat:ssc": 0.4}}, "trained_at": "2026-10-20T00:00:00+00:00"}
    out = asyncio.run(
        picks.build(JOBS, previous, client=httpx.AsyncClient(transport=httpx.MockTransport(answer)))
    )
    assert out["cohorts"] == {"all": {"cat:ssc": 0.4}}
    assert out["trained_at"] == "2026-10-20T00:00:00+00:00"
