#!/usr/bin/env bash
# Hardened NCCL all_reduce over EFA using a static 2-pod JobSet with the SAME torchrun
# rendezvous as the FSDP job (no MPI operator / SSH). Frees GPUs first (removes any warm-up
# Deployment), then runs our nccl_allreduce.py in the training image and streams busbw.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl envsubst
check_aws_context

export EFA_COUNT="${EFA_COUNT:-16}"

[ -f "${REPO_ROOT}/.image-ref-p5en-efa" ] || die "no .image-ref-p5en-efa; run 'make p5en-efa-image' first"
export IMAGE="$(cat "${REPO_ROOT}/.image-ref-p5en-efa")"

log "Ensuring JobSet controller is installed"
if ! kubectl get crd jobsets.jobset.x-k8s.io >/dev/null 2>&1; then
  kubectl apply --server-side -f \
    "https://github.com/kubernetes-sigs/jobset/releases/download/v0.8.2/manifests.yaml"
  kubectl -n jobset-system rollout status deploy/jobset-controller-manager --timeout=180s
fi

log "Freeing GPUs: removing any warm-up Deployment"
kubectl delete deploy efa-warm --ignore-not-found >/dev/null 2>&1 || true

log "Submitting static NCCL all_reduce (image=${IMAGE}, EFA_COUNT=${EFA_COUNT})"
kubectl delete jobset nccl-bench --ignore-not-found >/dev/null 2>&1 || true
envsubst '${IMAGE} ${EFA_COUNT}' < "${REPO_ROOT}/kubernetes/p5en-efa/nccl-benchmark/nccl-static.yaml" | kubectl apply -f -

log "Waiting for rank-0 to start; then streaming the busbw output"
# JobSet names pods <jobset>-workers-0-0-<suffix>, so resolve the rank-0 pod by label
# (completion-index 0) rather than hardcoding a name.
RANK0_POD=""
for i in $(seq 1 40); do
  RANK0_POD="$(kubectl get pods -l jobset.sigs.k8s.io/jobset-name=nccl-bench,batch.kubernetes.io/job-completion-index=0 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "${RANK0_POD}" ] && break
  sleep 5
done
[ -n "${RANK0_POD}" ] || die "rank-0 pod for nccl-bench never appeared"
kubectl wait --for=condition=Ready "pod/${RANK0_POD}" --timeout=300s || warn "rank-0 not Ready yet"
kubectl logs -f "${RANK0_POD}" 2>&1 | tee /tmp/efa-nccl-busbw.log
log "busbw GB/s is in the table above (also /tmp/efa-nccl-busbw.log)."
