#!/usr/bin/env bash
# Primary fault path: inject a well-known XID via dcgmi on the node running rank-0 of the
# FSDP JobSet. On EKS Auto Mode the node monitoring agent sets AcceleratedHardwareReady=False
# and node auto repair replaces the node after the ~10-minute toleration.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl jq envsubst
check_aws_context

XID="${XID:-79}"  # 79 = "GPU has fallen off the bus" (well-known Fatal).
export XID

# Target the node running the rank-0 FSDP pod so the fault hits an active workload.
TARGET_NODE="$(kubectl get pod -l jobset.sigs.k8s.io/jobset-name=fsdp-train \
  -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)"
[ -n "${TARGET_NODE}" ] || TARGET_NODE="$(kubectl get nodes -l karpenter.sh/nodepool=efa-gpu \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "${TARGET_NODE}" ] || die "no efa-gpu node found (is the FSDP JobSet running?)"
export TARGET_NODE

log "Injecting XID ${XID} on node ${TARGET_NODE} via dcgmi --inject"
kubectl delete job dcgm-inject --ignore-not-found >/dev/null 2>&1 || true
envsubst '${TARGET_NODE} ${XID}' \
  < "${REPO_ROOT}/kubernetes/p5en-efa/fault-injection/dcgm-inject-job.yaml" | kubectl apply -f -

log "Injection Job applied. Watch the node condition flip with: kubectl get nodes,nodeclaims -w"
log "Agent sets AcceleratedHardwareReady=False (Fatal) within seconds."
log "Node auto repair replaces the node after the ~10-minute toleration window."
