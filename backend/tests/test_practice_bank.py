import asyncio
import json

import httpx
from pydantic import SecretStr

from app.core.config import get_settings
from app.services import practice_bank


def _q(text, answer=1, options=None, why="Because."):
    return {"q": text, "options": options or [f"{text} a", f"{text} b", f"{text} c", f"{text} d"],
            "answer": answer, "explanation": why}  # fmt: skip


def _reply(obj):
    return httpx.Response(200, json={"choices": [{"message": {"content": json.dumps(obj)}}]})


def _run(folder, handler, monkeypatch, models="writer-model,checker-model"):
    monkeypatch.setattr(get_settings(), "mistral_api_key", SecretStr("test-key"))
    monkeypatch.setattr(get_settings(), "practice_models", models)
    monkeypatch.setattr(practice_bank, "SECTIONS", {"gs": practice_bank.SECTIONS["gs"]})
    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return asyncio.run(practice_bank.grow(folder, client=client, seed=1, current=False))


def test_only_questions_both_models_agree_on_are_kept(tmp_path, monkeypatch):
    seen = []

    def answer(request):
        body = json.loads(request.content)
        seen.append(body["model"])
        if body["messages"][0]["content"] == practice_bank.WRITE:
            return _reply({"questions": [
                _q("Which river is called the Ganga of the South?", 2),
                _q("Who wrote the book Discovery of India?", 0),
                _q("Who is the current Chief Justice of India?", 1),  # changes: dropped
                _q("Which article of the Constitution abolishes untouchability?", 3,
                   options=["Article 14", "Article 17", "Article 17 ", "Article 21"]),  # same option twice
                _q("The Battle of Plassey was fought in?", 5),  # no such option
                _q("Which river is called the Ganga of the South?", 2),  # a repeat
            ]})  # fmt: skip
        # The checker: agrees with the first, says the second has no right option.
        listed = body["messages"][1]["content"]
        assert "current Chief Justice" not in listed
        return _reply({"answers": [{"i": 0, "answer": "2"}, {"i": 1, "answer": None}]})

    added = _run(tmp_path, answer, monkeypatch)
    saved = json.loads((tmp_path / "gs.json").read_text(encoding="utf-8"))

    assert added == {"gs": 1}
    assert [q["q"] for q in saved["questions"]] == ["Which river is called the Ganga of the South?"]
    q = saved["questions"][0]
    assert (
        q["a"] == 2
        and len(q["o"]) == 4
        and q["x"] == "Because."
        and q["id"] == practice_bank.question_id(q["q"])
    )
    assert q["t"] in practice_bank.SECTIONS["gs"][1]
    # Two topics written by the first model, checked by the other.
    assert seen == ["writer-model", "writer-model", "checker-model"]


def test_questions_already_in_the_bank_are_not_added_again(tmp_path, monkeypatch):
    first = {"id": "x", "t": "Indian geography", "q": "Which river is called the Ganga of the South?",
             "o": ["a", "b", "c", "d"], "a": 2, "x": ""}  # fmt: skip
    practice_bank.save(tmp_path / "gs.json", "gs", [first])

    def answer(request):
        body = json.loads(request.content)
        if body["messages"][0]["content"] == practice_bank.WRITE:
            return _reply({"questions": [_q("Which river is called the Ganga of the South?", 2)]})
        raise AssertionError("nothing new to check")

    assert _run(tmp_path, answer, monkeypatch) == {"gs": 0}
    assert len(practice_bank.load(tmp_path / "gs.json")) == 1


def test_no_second_model_means_nothing_is_kept(tmp_path, monkeypatch):
    def answer(request):
        body = json.loads(request.content)
        if body["model"] == "checker-model":
            return httpx.Response(403, json={"message": "no access"})
        return _reply({"questions": [_q("Which planet is known as the Red Planet?", 1)]})

    assert _run(tmp_path, answer, monkeypatch) == {"gs": 0}
    assert not (tmp_path / "gs.json").exists()


def test_a_full_section_and_no_key_ask_nothing(tmp_path, monkeypatch):
    full = [{"id": str(i), "t": "Indian geography", "q": f"Q{i}", "o": ["a", "b", "c", "d"], "a": 0}
            for i in range(practice_bank.CAP)]  # fmt: skip
    practice_bank.save(tmp_path / "gs.json", "gs", full)

    def answer(request):
        raise AssertionError("not asked")

    assert _run(tmp_path, answer, monkeypatch) == {}
    monkeypatch.setattr(get_settings(), "mistral_api_key", SecretStr(""))
    assert asyncio.run(practice_bank.grow(tmp_path)) == {}


def test_topics_with_the_fewest_questions_go_first():
    import random

    bank = [{"t": "Indian geography"}] * 5 + [{"t": "Modern Indian history"}] * 2
    picked = practice_bank._topics("gs", bank, random.Random(0))
    assert len(picked) == practice_bank.TOPICS_PER_RUN
    assert "Indian geography" not in picked and "Modern Indian history" not in picked


def test_changing_facts_are_dropped_outside_english():
    ok = practice_bank._valid(
        _q("Which gas is present in the largest amount in air?", 0), "science", "Chemistry"
    )
    assert ok is not None  # "present" is fine in science
    assert (
        practice_bank._valid(_q("Who is the present Governor of RBI?", 0), "banking", "Banking terms") is None
    )
    assert (
        practice_bank._valid(_q("Which scheme was launched in 2024 for farmers?", 0), "gs", "Indian economy")
        is None
    )
    assert (
        practice_bank._valid(_q("Choose the word closest to 'current'.", 0), "english", "Synonyms")
        is not None
    )
