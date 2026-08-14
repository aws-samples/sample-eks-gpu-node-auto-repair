import os
from pathlib import Path

from checkpoint_dcp import find_latest_dcp_checkpoint


def _make_ckpt(root: Path, step: int, complete: bool = True) -> Path:
    d = root / f"step-{step}"
    d.mkdir(parents=True, exist_ok=True)
    (d / "__0_0.distcp").write_text("shard")
    if complete:
        (d / ".metadata").write_text("meta")
    return d


def test_returns_none_when_missing(tmp_path):
    assert find_latest_dcp_checkpoint(str(tmp_path / "nope")) is None


def test_returns_none_when_empty(tmp_path):
    (tmp_path / "out").mkdir()
    assert find_latest_dcp_checkpoint(str(tmp_path / "out")) is None


def test_picks_highest_complete_step(tmp_path):
    out = tmp_path / "out"
    out.mkdir()
    _make_ckpt(out, 100)
    _make_ckpt(out, 300)
    _make_ckpt(out, 200)
    result = find_latest_dcp_checkpoint(str(out))
    assert os.path.basename(result) == "step-300"


def test_skips_incomplete(tmp_path):
    out = tmp_path / "out"
    out.mkdir()
    _make_ckpt(out, 100, complete=True)
    _make_ckpt(out, 200, complete=False)  # no .metadata
    result = find_latest_dcp_checkpoint(str(out))
    assert os.path.basename(result) == "step-100"
