#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl envsubst

JOBSET_VERSION="v0.8.2"

log "Ensuring JobSet controller is installed (${JOBSET_VERSION})"
if ! kubectl get crd jobsets.jobset.x-k8s.io >/dev/null 2>&1; then
  kubectl apply --server-side -f \
    "https://github.com/kubernetes-sigs/jobset/releases/download/${JOBSET_VERSION}/manifests.yaml"
  log "Waiting for JobSet controller to be ready"
  kubectl -n jobset-system rollout status deploy/jobset-controller-manager --timeout=180s
fi

[ -f "${REPO_ROOT}/.image-ref" ] || die "no .image-ref; run 'make g6e-image' first"
IMAGE="$(cat "${REPO_ROOT}/.image-ref")"
export IMAGE
log "Using training image: ${IMAGE}"

log "Applying JobSet"
envsubst '${IMAGE}' < "${REPO_ROOT}/kubernetes/g6e/train/jobset.yaml" | kubectl apply -f -

log "Waiting for worker pods to be created"
sleep 10
kubectl get pods -l jobset.sigs.k8s.io/jobset-name=train -o wide || true

log "Tailing rank-0 training log (Ctrl-C to stop tailing; training continues)"
kubectl logs -f job/train-workers-0 || \
  warn "rank-0 pod not ready yet; retry: kubectl logs -f job/train-workers-0"
