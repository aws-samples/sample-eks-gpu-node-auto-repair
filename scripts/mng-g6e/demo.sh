#!/usr/bin/env bash
# Full mng-g6e demo: launch training, then inject each XID in turn to exercise every
# nodeRepairConfigOverride (Replace@10m, Replace@30m, NoAction) plus the default Reboot (XID 95).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl envsubst

log "Launching training (JobSet)"
"${REPO_ROOT}/scripts/mng-g6e/train.sh" &
sleep 60

log "=== Behavior 1/4: XID 79 -> Replace @10m (override) ==="
XID=79 "${REPO_ROOT}/scripts/mng-g6e/inject-fault.sh"
log "Observe for ~8 min: node Replaced, new instance ID, JobSet gang-restart, resume from checkpoint."
log "Advance to the next behavior only after the replacement node is Ready and training resumed."

cat <<'NOTE'
This demo intentionally stops after the first (Replace) behavior to keep a single run bounded.
To exercise the other behaviors, after training is healthy again run, one at a time, waiting for
each to complete before the next:
  XID=63 make mng-g6e-inject-fault   # NoAction  — node stays Ready, no repair
  XID=64 make mng-g6e-inject-fault   # Replace @30m
  XID=95 make mng-g6e-inject-fault   # default Reboot @10m — SAME instance ID
Watch each with: kubectl get nodes,pods -w
NOTE
