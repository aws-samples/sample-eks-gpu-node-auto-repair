#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl envsubst
check_aws_context

if ! kubectl get crd jobsets.jobset.x-k8s.io >/dev/null 2>&1; then
  kubectl apply --server-side -f \
    "https://github.com/kubernetes-sigs/jobset/releases/download/v0.8.2/manifests.yaml"
  kubectl -n jobset-system rollout status deploy/jobset-controller-manager --timeout=180s
fi

[ -f "${REPO_ROOT}/.image-ref-p5en-efa" ] || die "no .image-ref-p5en-efa; run 'make mng-p5en-efa-image' first"
export IMAGE="$(cat "${REPO_ROOT}/.image-ref-p5en-efa")"
log "Launching FSDP JobSet with image ${IMAGE}"
envsubst '${IMAGE}' < "${REPO_ROOT}/kubernetes/mng-p5en-efa/train/jobset.yaml" | kubectl apply -f -
sleep 10
kubectl get pods -l jobset.sigs.k8s.io/jobset-name=fsdp-train -o wide || true
log "Tail rank-0: kubectl logs -f job/fsdp-train-workers-0"
