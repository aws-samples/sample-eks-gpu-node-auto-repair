#!/usr/bin/env bash
# Primary fault path: inject a well-known XID via dcgmi on the node running rank-0.
# Validated viable on EKS Auto Mode.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl jq envsubst

XID="${XID:-79}"  # 79 = "GPU has fallen off the bus" (well-known Fatal).
export XID

# Target the node running the rank-0 training pod so the fault hits an active workload.
TARGET_NODE="$(kubectl get pod -l jobset.sigs.k8s.io/jobset-name=train \
  -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)"
[ -n "${TARGET_NODE}" ] || TARGET_NODE="$(kubectl get nodes -l karpenter.sh/nodepool=gpu \
  -o jsonpath='{.items[0].metadata.name}')"
[ -n "${TARGET_NODE}" ] || die "no GPU node found"
export TARGET_NODE

log "Injecting XID ${XID} on node ${TARGET_NODE} via dcgmi --inject"
kubectl delete job dcgm-inject --ignore-not-found >/dev/null 2>&1 || true
envsubst '${TARGET_NODE} ${XID}' \
  < "${REPO_ROOT}/kubernetes/g6e/fault-injection/dcgm-inject-job.yaml" | kubectl apply -f -

log "Injection Job applied. Watch the node condition flip with: kubectl get nodes,nodeclaims -w"
log "Node monitoring agent should set AcceleratedHardwareReady=False (Fatal) within seconds."
log "Node auto repair replaces the node after the ~10-minute toleration window."
