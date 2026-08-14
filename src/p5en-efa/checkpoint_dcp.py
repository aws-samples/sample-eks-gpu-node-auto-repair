"""Latest-complete DCP checkpoint discovery for resumable FSDP training."""
import os
import re

_STEP_RE = re.compile(r"^step-(\d+)$")


def find_latest_dcp_checkpoint(output_dir: str):
    """Return the path to the highest-step *complete* DCP checkpoint dir, or None.

    A torch.distributed.checkpoint directory is complete only once it contains a
    ``.metadata`` file (written after all shards). Dirs without it (a crash mid-write)
    are skipped so resume never loads a torn checkpoint.
    """
    if not os.path.isdir(output_dir):
        return None
    best_step = -1
    best_path = None
    for name in os.listdir(output_dir):
        m = _STEP_RE.match(name)
        if not m:
            continue
        path = os.path.join(output_dir, name)
        if not os.path.isfile(os.path.join(path, ".metadata")):
            continue
        step = int(m.group(1))
        if step > best_step:
            best_step = step
            best_path = path
    return best_path
