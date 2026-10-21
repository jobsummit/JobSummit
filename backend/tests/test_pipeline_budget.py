import asyncio
import importlib.util
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "run_pipeline.py"


def _load():
    spec = importlib.util.spec_from_file_location("run_pipeline", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["run_pipeline"] = module
    spec.loader.exec_module(module)
    return module


rp = _load()


def test_slow_phase_is_cut_off_and_reported():
    async def hangs() -> int:
        await asyncio.sleep(60)
        return 5

    stopped: list[str] = []
    assert asyncio.run(rp.timeboxed("detail_pages", hangs(), 0.05, stopped)) == 0
    assert stopped == ["detail_pages"]


def test_phase_in_time_keeps_its_result():
    async def quick() -> int:
        return 7

    stopped: list[str] = []
    assert asyncio.run(rp.timeboxed("crawl", quick(), 5, stopped)) == 7
    assert stopped == []


def test_no_time_left_skips_the_phase():
    async def never() -> int:
        raise AssertionError("should not run")

    stopped: list[str] = []
    assert asyncio.run(rp.timeboxed("pdfs", never(), 0, stopped)) == 0
    assert stopped == ["pdfs"]


def test_budget_keeps_a_reserve_for_publishing():
    budget = rp.Budget(minutes=10)
    assert budget.left() <= 10 * 60 - rp.Budget.RESERVE_S
    assert budget.left(cap_s=30) == 30
    assert rp.Budget(minutes=1).left() == 0  # less than the reserve: nothing more starts
