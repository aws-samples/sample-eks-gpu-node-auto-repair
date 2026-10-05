#!/usr/bin/env bash
# Inject a well-known XID so the node monitoring agent sets AcceleratedHardwareReady=False and
# node auto repair applies the configured override. XID is parameterized to exercise each rule
# (79 / 64 / 63 / 95).
#
# The agent reads GPU health from the nv-hostengine run by the add-on's `dcgm-server` DaemonSet,
# so we inject into THAT hostengine by exec'ing dcgmi inside the dcgm-server pod on the target
# node (validated method). Injecting from a separate DCGM container or the host does NOT work:
# the agent only reads its own dcgm-server hostengine, and the host has no dcgmi.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl

XID="${XID:-79}"

# Target the node running rank-0 of the training job, else the first GPU node.
TARGET_NODE="$(kubectl get pod -l jobset.sigs.k8s.io/jobset-name=train \
  -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)"
[ -n "${TARGET_NODE}" ] || TARGET_NODE="$(kubectl get nodes -l nodegroup=gpu \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "${TARGET_NODE}" ] || die "no GPU node found"

# Find the dcgm-server pod on that node (the hostengine the agent reads).
DCGM_POD="$(kubectl get pods -n kube-system -l k8s-app=dcgm-server \
  -o jsonpath="{range .items[?(@.spec.nodeName==\"${TARGET_NODE}\")]}{.metadata.name}{end}" 2>/dev/null || true)"
[ -n "${DCGM_POD}" ] || die "no dcgm-server pod on ${TARGET_NODE} — is the node monitoring agent add-on healthy? (dcgm-server must tolerate the GPU taint; see the cluster add-on configuration_values)"

log "Injecting XID ${XID} on ${TARGET_NODE} via dcgmi in dcgm-server pod ${DCGM_POD}"
# Field 230 = DCGM_FI_DEV_XID_ERRORS.
kubectl exec -n kube-system "${DCGM_POD}" -- \
  /usr/bin/dcgmi test --inject --gpuid 0 -f 230 -v "${XID}" || \
  die "injection failed (is the GPU present and dcgm-server running nv-hostengine?)"

log "Injected. The agent sets AcceleratedHardwareReady=False / NvidiaXID${XID}Error shortly."
case "${XID}" in
  79) log "Expected repair: REPLACE after ~10 min (override). New instance ID." ;;
  64|48) log "Expected repair: REPLACE after ~30 min (override). New instance ID." ;;
  63) log "Expected repair: NoAction (override). Node stays Ready; condition flips but no repair." ;;
  95) log "Expected repair: default REBOOT after ~10 min (no override). SAME instance ID." ;;
  *) log "No override for XID ${XID}; default AcceleratedHardwareReady action (Reboot @10m) applies." ;;
esac
cat <<NOTE
NOTE: an injected value decays and the condition reason can oscillate between NvidiaXID${XID}Error
and a generic DCGMHealthCode. To hold it resident through the repair wait, re-inject periodically:
  while true; do kubectl exec -n kube-system ${DCGM_POD} -- /usr/bin/dcgmi test --inject --gpuid 0 -f 230 -v ${XID}; sleep 90; done
Watch: kubectl get nodes -w   and   kubectl describe node ${TARGET_NODE} | grep -A3 AcceleratedHardwareReady
NOTE
