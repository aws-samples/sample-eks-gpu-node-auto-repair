#!/usr/bin/env bash
# Inject a well-known XID via dcgmi on the node running rank-0 of the FSDP JobSet (or the
# first EFA GPU node). XID is parameterized so the demo can sweep 79 / 64 / 63 / 95 to
# exercise each managed-node-group nodeRepairConfigOverride.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl jq envsubst

XID="${XID:-79}"
export XID

# `|| true` so the rank-0 lookup cannot abort the script under `set -e`: if the FSDP JobSet
# isn't running yet we fall back to the first efa-gpu node below.
TARGET_NODE="$(kubectl get pod -l jobset.sigs.k8s.io/jobset-name=fsdp-train \
  -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)"
[ -n "${TARGET_NODE}" ] || TARGET_NODE="$(kubectl get nodes -l nodegroup=efa-gpu \
  -o jsonpath='{.items[0].metadata.name}')"
[ -n "${TARGET_NODE}" ] || die "no EFA GPU node found"
export TARGET_NODE

log "Injecting XID ${XID} on node ${TARGET_NODE} via dcgmi --inject"
kubectl delete job dcgm-inject --ignore-not-found >/dev/null 2>&1 || true
envsubst '${TARGET_NODE} ${XID}' \
  < "${REPO_ROOT}/kubernetes/mng-p5en-efa/fault-injection/dcgm-inject-job.yaml" | kubectl apply -f -

log "Applied. The NMA add-on sets AcceleratedHardwareReady=False / NvidiaXID${XID}Error within seconds."
case "${XID}" in
  79) log "Expected repair: REPLACE after ~5 min (override). New instance ID." ;;
  64|48) log "Expected repair: REPLACE after ~10 min (override). New instance ID." ;;
  63) log "Expected repair: NoAction (override). Node stays Ready; condition flips but no repair." ;;
  95) log "Expected repair: default REBOOT after ~10 min (no override). SAME instance ID." ;;
  *) log "No override for XID ${XID}; default AcceleratedHardwareReady action (Reboot @10m) applies." ;;
esac
log "Watch: kubectl get nodes,pods -w   and   kubectl describe node ${TARGET_NODE} | grep -A3 AcceleratedHardwareReady"
