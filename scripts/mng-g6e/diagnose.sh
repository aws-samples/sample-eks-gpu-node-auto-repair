#!/usr/bin/env bash
# Diagnose a node WITHOUT SSH, using the EKS-native NodeDiagnostic API via the
# `kubectl ekslogs` plugin. This is the "diagnose" third of the EKS detect -> repair -> diagnose
# story: the node monitoring agent collects a full system log bundle (kernel dmesg, containerd,
# kubelet, networking, ipamd, and the agent's own log) into a tarball and streams it out through
# the Kubernetes node proxy API -- no SSH, no SSM, no security-group changes. This works on MNG
# nodes too: the NMA add-on provides the NodeDiagnostic CRD and its controller.
#
# Ref: https://github.com/aws/eks-node-monitoring-agent/tree/main/tools/kubectl-ekslogs
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl curl

OUT_DIR="${OUT_DIR:-./node-logs}"

# Install the kubectl-ekslogs plugin on demand if it isn't already on PATH.
if ! kubectl ekslogs --help >/dev/null 2>&1; then
  log "kubectl-ekslogs plugin not found; installing to ~/.local/bin"
  mkdir -p "${HOME}/.local/bin"
  curl -fsSL -o "${HOME}/.local/bin/kubectl-ekslogs" \
    https://raw.githubusercontent.com/aws/eks-node-monitoring-agent/refs/heads/main/tools/kubectl-ekslogs/kubectl-ekslogs
  chmod +x "${HOME}/.local/bin/kubectl-ekslogs"
  export PATH="${HOME}/.local/bin:${PATH}"
  kubectl ekslogs --help >/dev/null 2>&1 || die "plugin install failed; ensure ~/.local/bin is on PATH"
fi

# Target: an explicit NODE, else the node running rank-0 of the training job, else
# the first GPU node. This lets you grab logs from the node you just faulted.
NODE="${NODE:-}"
if [ -z "${NODE}" ]; then
  NODE="$(kubectl get pod -l jobset.sigs.k8s.io/jobset-name=train \
    -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)"
fi
[ -n "${NODE}" ] || NODE="$(kubectl get nodes -l nodegroup=gpu \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "${NODE}" ] || die "no node found; pass NODE=<node-name> explicitly"

mkdir -p "${OUT_DIR}"
log "Collecting a diagnostic log bundle from ${NODE} (no SSH) -> ${OUT_DIR}"
log "This creates a NodeDiagnostic resource; the agent collects logs and the plugin"
log "downloads + cleans up automatically."
kubectl ekslogs --timeout "${EKSLOGS_TIMEOUT:-300s}" --output-dir "${OUT_DIR}" "${NODE}"

log "Done. Inspect with: tar tzf ${OUT_DIR}/${NODE}-logs.tar.gz"
log "The agent's own detections are in: automode/eks-node-monitoring-agent.txt"
