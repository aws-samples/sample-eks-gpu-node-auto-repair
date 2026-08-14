#!/usr/bin/env bash
# Validate the environment before running the workload.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require aws kubectl terraform helm jq envsubst

fail=0

log "Checking AWS credentials"
aws sts get-caller-identity >/dev/null 2>&1 || { warn "AWS credentials not configured"; fail=1; }

log "Checking kubectl context reaches the cluster"
kubectl get ns kube-system >/dev/null 2>&1 || { warn "kubectl cannot reach the cluster"; fail=1; }

log "Checking GPU NodePool exists"
kubectl get nodepool.karpenter.sh gpu >/dev/null 2>&1 || { warn "GPU NodePool 'gpu' missing (run make g6e-nodepool)"; fail=1; }

log "Checking FSx PVC is Bound"
phase="$(kubectl get pvc fsx-checkpoints -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[ "${phase}" = "Bound" ] || { warn "PVC fsx-checkpoints not Bound (run make g6e-storage)"; fail=1; }

log "Checking JobSet CRD installed"
kubectl get crd jobsets.jobset.x-k8s.io >/dev/null 2>&1 || { warn "JobSet CRD missing (run make g6e-train once)"; fail=1; }

log "Checking training image reference exists"
[ -f "${REPO_ROOT}/.image-ref" ] || { warn ".image-ref missing (run make g6e-image)"; fail=1; }

if [ "${fail}" -eq 0 ]; then
  log "Preflight PASSED — environment ready."
else
  die "Preflight FAILED — resolve the warnings above."
fi
