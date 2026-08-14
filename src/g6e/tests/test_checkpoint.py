import os
from pathlib import Path

import pytest

from checkpoint import find_latest_checkpoint


def _make_ckpt(root: Path, step: int, complete: bool = True) -> Path:
    d = root / f"checkpoint-{step}"
    d.mkdir(parents=True, exist_ok=True)
    # HuggingFace Trainer writes trainer_state.json in a complete checkpoint.
    if complete:
        (d / "trainer_state.json").write_text("{}")
    return d


def test_returns_none_when_no_dir(tmp_path):
    assert find_latest_checkpoint(str(tmp_path / "missing")) is None


def test_returns_none_when_empty(tmp_path):
    (tmp_path / "out").mkdir()
    assert find_latest_checkpoint(str(tmp_path / "out")) is None


def test_picks_highest_step(tmp_path):
    out = tmp_path / "out"
    out.mkdir()
    _make_ckpt(out, 50)
    _make_ckpt(out, 150)
    _make_ckpt(out, 100)
    result = find_latest_checkpoint(str(out))
    assert result is not None
    assert os.path.basename(result) == "checkpoint-150"


def test_ignores_incomplete_checkpoint(tmp_path):
    out = tmp_path / "out"
    out.mkdir()
    _make_ckpt(out, 100, complete=True)
    _make_ckpt(out, 200, complete=False)  # no trainer_state.json -> incomplete
    result = find_latest_checkpoint(str(out))
    assert os.path.basename(result) == "checkpoint-100"
