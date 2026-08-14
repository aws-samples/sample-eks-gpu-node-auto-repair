#!/usr/bin/env bash
# Validate the p5en/EFA environment before running the workload.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require aws kubectl jq envsubst
check_aws_context

fail=0

log "Checking AWS credentials + account"
aws sts get-caller-identity >/dev/null 2>&1 || { warn "AWS credentials not configured"; fail=1; }

log "Checking kubectl context reaches the cluster"
kubectl get ns kube-system >/dev/null 2>&1 || { warn "kubectl cannot reach the cluster"; fail=1; }

log "Checking efa-gpu NodePool exists"
kubectl get nodepool.karpenter.sh efa-gpu >/dev/null 2>&1 \
  || { warn "NodePool 'efa-gpu' missing (run make p5en-efa-nodepool)"; fail=1; }

log "Checking FSx PVC is Bound"
phase="$(kubectl get pvc fsx-efa-checkpoints -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[ "${phase}" = "Bound" ] || { warn "PVC fsx-efa-checkpoints not Bound (run make p5en-efa-storage)"; fail=1; }

log "Checking JobSet CRD installed"
kubectl get crd jobsets.jobset.x-k8s.io >/dev/null 2>&1 \
  || { warn "JobSet CRD missing (run make p5en-efa-train once)"; fail=1; }

log "Checking training image reference exists"
[ -f "${REPO_ROOT}/.image-ref-p5en-efa" ] \
  || { warn ".image-ref-p5en-efa missing (run make p5en-efa-image)"; fail=1; }

log "Checking ODCR ${EFA_CR_ID} has free capacity"
free="$(aws ec2 describe-capacity-reservations --capacity-reservation-ids "${EFA_CR_ID}" \
  --region "${EFA_AWS_REGION}" \
  --query 'CapacityReservations[0].AvailableInstanceCount' --output text 2>/dev/null || echo 0)"
if [ "${free}" = "None" ] || [ -z "${free}" ]; then free=0; fi
# Need >=1 free slot for a repair to reprovision a replacement p5en.
if [ "${free}" -lt 1 ]; then
  warn "ODCR has ${free} free slots; node auto repair needs >=1 to reprovision"
  fail=1
else
  log "ODCR free slots: ${free}"
fi

log "Regression guard: no p5en manifest may request hugepages-2Mi"
if grep -rn "hugepages" "${REPO_ROOT}/kubernetes/p5en-efa/" >/dev/null 2>&1; then
  warn "hugepages request found in kubernetes/p5en-efa/ — this reintroduces the reserved-reprovision stall"
  fail=1
fi

if [ "${fail}" -eq 0 ]; then
  log "Preflight PASSED — environment ready."
else
  die "Preflight FAILED — resolve the warnings above."
fi
