"""Checkpoint discovery for resumable training on shared storage."""
import os
import re

_CKPT_RE = re.compile(r"^checkpoint-(\d+)$")


def find_latest_checkpoint(output_dir: str):
    """Return the path to the highest-step *complete* HF checkpoint, or None.

    A checkpoint directory is considered complete only if it contains
    ``trainer_state.json`` (HuggingFace Trainer writes this last-ish and it
    records global_step). Incomplete dirs (e.g. a crash mid-write) are skipped.
    """
    if not os.path.isdir(output_dir):
        return None

    best_step = -1
    best_path = None
    for name in os.listdir(output_dir):
        m = _CKPT_RE.match(name)
        if not m:
            continue
        path = os.path.join(output_dir, name)
        if not os.path.isfile(os.path.join(path, "trainer_state.json")):
            continue  # incomplete checkpoint
        step = int(m.group(1))
        if step > best_step:
            best_step = step
            best_path = path
    return best_path
