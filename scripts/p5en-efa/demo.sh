#!/usr/bin/env bash
# Full p5en/EFA self-healing workflow, in the intended order:
#   NCCL busbw -> FSDP JobSet -> XID inject -> HANDS-OFF ~10-min Auto Mode repair -> resume.
# It does NOT delete the NodeClaim; EKS Auto Mode replaces the node itself after the toleration.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl jq envsubst
check_aws_context

log "STEP 1/5: NCCL all_reduce busbw over EFA (proves EFA bandwidth)"
"${REPO_ROOT}/scripts/p5en-efa/nccl-test.sh" || warn "NCCL test returned non-zero; review busbw log"
kubectl delete jobset nccl-bench --ignore-not-found >/dev/null 2>&1 || true

log "STEP 2/5: launch the FSDP training JobSet"
"${REPO_ROOT}/scripts/p5en-efa/train.sh"
log "Waiting for a first checkpoint to land on FSx before injecting a fault..."
# JobSet names pods <jobset>-workers-0-0-<suffix>, so resolve the rank-0 pod by label
# (completion-index 0) rather than hardcoding a name.
for i in $(seq 1 120); do
  RANK0_POD="$(kubectl get pods -l jobset.sigs.k8s.io/jobset-name=fsdp-train,batch.kubernetes.io/job-completion-index=0 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${RANK0_POD}" ]; then
    kubectl exec "${RANK0_POD}" -- ls /fsx/checkpoints 2>/dev/null | grep -q 'step-' && { log "checkpoint present"; break; }
  fi
  sleep 15
done

log "STEP 3/5: inject a GPU XID fault on the rank-0 node"
RANK0_NODE="$(kubectl get pod -l jobset.sigs.k8s.io/jobset-name=fsdp-train -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)"
[ -n "${RANK0_NODE}" ] || die "could not resolve rank-0 node (is the FSDP JobSet running?)"
"${REPO_ROOT}/scripts/p5en-efa/inject-fault.sh"

log "STEP 4/5: HANDS-OFF. Let EKS Auto Mode do the repair itself (~10-min toleration)."
log "Do NOT delete the NodeClaim. Watching the chain (up to 35 min)..."
FAULT_TS=$(date +%s)
while true; do
  NOW=$(( $(date +%s) - FAULT_TS ))
  COND="$(kubectl get node "${RANK0_NODE}" -o json 2>/dev/null | jq -r '.status.conditions[]?|select(.type=="AcceleratedHardwareReady")|.status+"/"+.reason' 2>/dev/null || echo 'gone')"
  [ -z "${COND}" ] && COND="gone"
  NODES=$(kubectl get nodes -l karpenter.sh/nodepool=efa-gpu --no-headers 2>/dev/null | grep -cw Ready || true)
  RESTARTS=$(kubectl get jobset fsdp-train -o jsonpath='{.status.restarts}' 2>/dev/null || echo 0)
  log "t+${NOW}s  rank0node=${COND}  readyGPUnodes=${NODES}  jobsetRestarts=${RESTARTS}"
  if [ "${COND}" = "gone" ] && [ "${RESTARTS}" != "0" ] && [ "${RESTARTS}" != "" ]; then
    log "node replaced + gang restarted"; break
  fi
  # p5en recovery is slower than g6e: node termination + reserved-capacity reprovision + a
  # 16-rank EFA/NCCL re-init on the fresh node, plus reloading the 32B model, routinely pushes
  # total time to ~25-30 min. Watch up to 35 min before handing off to manual inspection.
  [ "${NOW}" -gt 2100 ] && { warn "35 min elapsed; inspect manually"; break; }
  sleep 20
done

log "STEP 5/5: confirm the FSDP job resumed from checkpoint on the fresh node"
sleep 30
POD="$(kubectl get pods -l jobset.sigs.k8s.io/jobset-name=fsdp-train -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
kubectl logs "${POD}" 2>&1 | grep -iE 'resume|Resuming from|checkpoint' | tail -5 || warn "resume line not found yet; tail logs manually"
log "Complete. Tear down with: make p5en-efa-clean"
