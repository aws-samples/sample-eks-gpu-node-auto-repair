#!/usr/bin/env bash
# Full g6e self-healing workflow, in the intended order:
#   FSDP/LoRA JobSet -> wait for first checkpoint -> XID inject -> HANDS-OFF ~10-min Auto Mode
#   repair -> resume from checkpoint. It does NOT delete the NodeClaim; EKS Auto Mode replaces
#   the node itself after the toleration window.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl jq envsubst

log "STEP 1/4: launch the LoRA fine-tune JobSet"
# train.sh installs the JobSet CRD (up to ~180s on a cold cluster), applies the JobSet, then
# tails rank-0 logs in the foreground forever. Run it in the background with output suppressed;
# wait until the JobSet actually exists (rather than racing a fixed sleep), then stop train.sh
# and its child `kubectl logs -f` (portable: kill children via pkill -P, then the parent).
"${REPO_ROOT}/scripts/g6e/train.sh" >/dev/null 2>&1 &
TRAIN_PID=$!
log "Waiting for the JobSet to be created..."
for i in $(seq 1 60); do
  kubectl get jobset train >/dev/null 2>&1 && { log "JobSet created"; break; }
  sleep 5
done
pkill -P "${TRAIN_PID}" 2>/dev/null || true
kill "${TRAIN_PID}" 2>/dev/null || true

log "Waiting for a first checkpoint to land on FSx before injecting a fault..."
# JobSet names pods <jobset>-workers-0-0-<suffix>, so resolve the rank-0 pod by label
# (completion-index 0) rather than hardcoding a name.
for i in $(seq 1 120); do
  RANK0_POD="$(kubectl get pods -l jobset.sigs.k8s.io/jobset-name=train,batch.kubernetes.io/job-completion-index=0 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${RANK0_POD}" ]; then
    kubectl exec "${RANK0_POD}" -- ls /fsx/checkpoints 2>/dev/null | grep -q 'checkpoint-' && { log "checkpoint present"; break; }
  fi
  sleep 15
done

log "STEP 2/4: inject a GPU XID fault on the rank-0 node"
RANK0_NODE="$(kubectl get pod -l jobset.sigs.k8s.io/jobset-name=train -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)"
[ -n "${RANK0_NODE}" ] || die "could not resolve rank-0 node (is the JobSet running?)"
"${REPO_ROOT}/scripts/g6e/inject-fault.sh"

log "STEP 3/4: HANDS-OFF. Let EKS Auto Mode do the repair itself (~10-min toleration)."
log "Do NOT delete the NodeClaim. Watching the chain (up to 20 min)..."
FAULT_TS=$(date +%s)
while true; do
  NOW=$(( $(date +%s) - FAULT_TS ))
  COND="$(kubectl get node "${RANK0_NODE}" -o json 2>/dev/null | jq -r '.status.conditions[]?|select(.type=="AcceleratedHardwareReady")|.status+"/"+.reason' 2>/dev/null || echo 'gone')"
  [ -z "${COND}" ] && COND="gone"
  NODES=$(kubectl get nodes -l karpenter.sh/nodepool=gpu --no-headers 2>/dev/null | grep -cw Ready || true)
  RESTARTS=$(kubectl get jobset train -o jsonpath='{.status.restarts}' 2>/dev/null || echo 0)
  log "t+${NOW}s  rank0node=${COND}  readyGPUnodes=${NODES}  jobsetRestarts=${RESTARTS}"
  if [ "${COND}" = "gone" ] && [ "${RESTARTS}" != "0" ] && [ "${RESTARTS}" != "" ]; then
    log "node replaced + gang restarted"; break
  fi
  [ "${NOW}" -gt 1200 ] && { warn "20 min elapsed; inspect manually"; break; }
  sleep 20
done

log "STEP 4/4: confirm the job resumed from checkpoint on the fresh node"
sleep 30
POD="$(kubectl get pods -l jobset.sigs.k8s.io/jobset-name=train -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
kubectl logs "${POD}" 2>&1 | grep -iE 'resume|Resuming from|checkpoint' | tail -5 || warn "resume line not found yet; tail logs manually"
log "Complete. Tear down with: make g6e-clean"
