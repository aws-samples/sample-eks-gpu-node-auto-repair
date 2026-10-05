#!/usr/bin/env bash
# Full mng-p5en-efa demo: prove EFA bandwidth with NCCL, launch FSDP training, then inject each
# XID in turn to exercise every nodeRepairConfigOverride (Replace@10m, Replace@30m, NoAction) plus
# the default Reboot (XID 95).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl envsubst

log "STEP 1/3: NCCL all_reduce busbw over EFA (proves EFA bandwidth)"
"${REPO_ROOT}/scripts/mng-p5en-efa/nccl-test.sh" || warn "NCCL test returned non-zero; review busbw log"
kubectl delete jobset nccl-bench --ignore-not-found >/dev/null 2>&1 || true

log "STEP 2/3: launch the FSDP training JobSet"
"${REPO_ROOT}/scripts/mng-p5en-efa/train.sh" &
sleep 60

log "=== STEP 3/3 — Behavior 1/4: XID 79 -> Replace @10m (override) ==="
XID=79 "${REPO_ROOT}/scripts/mng-p5en-efa/inject-fault.sh"
log "Observe for ~8-30 min: node Replaced, new instance ID, JobSet gang-restart, resume from checkpoint."
log "p5en recovery is slower than g6e (reserved reprovision + 16-rank EFA/NCCL re-init); watch up to ~30 min."
log "Advance to the next behavior only after the replacement node is Ready and training resumed."

cat <<'NOTE'
This demo intentionally stops after the first (Replace) behavior to keep a single run bounded.
To exercise the other behaviors, after training is healthy again run, one at a time, waiting for
each to complete before the next:
  XID=63 make mng-p5en-efa-inject-fault   # NoAction  — node stays Ready, no repair
  XID=64 make mng-p5en-efa-inject-fault   # Replace @30m
  XID=95 make mng-p5en-efa-inject-fault   # default Reboot @10m — SAME instance ID
Watch each with: kubectl get nodes,pods -w
NOTE
