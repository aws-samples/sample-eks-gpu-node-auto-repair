#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require aws kubectl terraform jq envsubst

fail=0
log "Checking AWS credentials"
aws sts get-caller-identity >/dev/null 2>&1 || { warn "AWS credentials not configured"; fail=1; }

log "Checking kubectl reaches the cluster"
kubectl get ns kube-system >/dev/null 2>&1 || { warn "kubectl cannot reach the cluster"; fail=1; }

log "Checking GPU MNG nodes are Ready"
kubectl get nodes -l nodegroup=gpu --no-headers 2>/dev/null | grep -q ' Ready' \
  || { warn "no Ready GPU MNG node (run make mng-g6e-cluster)"; fail=1; }

log "Checking node monitoring agent DaemonSet is present"
kubectl -n kube-system get ds -l app.kubernetes.io/name=eks-node-monitoring-agent >/dev/null 2>&1 \
  || { warn "NMA add-on DaemonSet missing"; fail=1; }

log "Checking FSx PVC is Bound"
[ "$(kubectl get pvc fsx-checkpoints -o jsonpath='{.status.phase}' 2>/dev/null)" = "Bound" ] \
  || { warn "PVC fsx-checkpoints not Bound (run make mng-g6e-storage)"; fail=1; }

log "Checking training image reference exists"
[ -f "${REPO_ROOT}/.image-ref" ] || { warn ".image-ref missing (run make mng-g6e-image)"; fail=1; }

[ "${fail}" -eq 0 ] && log "Preflight PASSED." || die "Preflight FAILED — resolve warnings above."
