#!/usr/bin/env bash
# Validate the mng-p5en-efa environment before running the workload.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require aws kubectl terraform jq envsubst

fail=0
log "Checking AWS credentials"
aws sts get-caller-identity >/dev/null 2>&1 || { warn "AWS credentials not configured"; fail=1; }

log "Checking kubectl reaches the cluster"
kubectl get ns kube-system >/dev/null 2>&1 || { warn "kubectl cannot reach the cluster"; fail=1; }

log "Checking 2 EFA GPU MNG nodes are Ready"
ready="$(kubectl get nodes -l nodegroup=efa-gpu --no-headers 2>/dev/null | grep -cw Ready || true)"
[ "${ready:-0}" -ge 2 ] 2>/dev/null \
  || { warn "need 2 Ready EFA GPU MNG nodes, found ${ready:-0} (run make mng-p5en-efa-cluster)"; fail=1; }

log "Checking node monitoring agent DaemonSet is present"
kubectl -n kube-system get ds -l app.kubernetes.io/name=eks-node-monitoring-agent >/dev/null 2>&1 \
  || { warn "NMA add-on DaemonSet missing"; fail=1; }

log "Checking FSx PVC is Bound"
[ "$(kubectl get pvc fsx-efa-checkpoints -o jsonpath='{.status.phase}' 2>/dev/null)" = "Bound" ] \
  || { warn "PVC fsx-efa-checkpoints not Bound (run make mng-p5en-efa-storage)"; fail=1; }

log "Checking training image reference exists"
[ -f "${REPO_ROOT}/.image-ref-p5en-efa" ] \
  || { warn ".image-ref-p5en-efa missing (run make mng-p5en-efa-image)"; fail=1; }

log "Checking EFA is allocatable on a GPU node (vpc.amazonaws.com/efa > 0)"
efa="$(kubectl get nodes -l nodegroup=efa-gpu \
  -o jsonpath='{.items[0].status.allocatable.vpc\.amazonaws\.com/efa}' 2>/dev/null || true)"
[ "${efa:-0}" -gt 0 ] 2>/dev/null \
  || { warn "EFA allocatable is ${efa:-0}; the EFA device plugin may not be ready (run make mng-p5en-efa-nodegroup)"; fail=1; }

[ "${fail}" -eq 0 ] && log "Preflight PASSED." || die "Preflight FAILED — resolve warnings above."
