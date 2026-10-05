#!/usr/bin/env bash
# Await the EFA GPU managed node group and finish node-side setup. On this MNG path the 2
# p5en.48xlarge nodes are provisioned by the cluster Terraform — there is NO
# Karpenter pool to apply and no warm-up Deployment to force provisioning. This script only
# waits for the nodes, installs the device plugins, and confirms EFA.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl aws jq helm

log "Waiting up to 10 min for the 2 EFA GPU MNG nodes to be Ready"
for _ in $(seq 1 60); do
  # `grep -c` exits 1 when the count is 0; under `set -e` that would abort the loop, so
  # guard with `|| true` and default an empty result to 0.
  ready="$(kubectl get nodes -l nodegroup=efa-gpu --no-headers 2>/dev/null | grep -c ' Ready ' || true)"
  [ "${ready:-0}" -ge 2 ] && { log "2 EFA GPU nodes Ready"; break; }
  sleep 10
done
kubectl get nodes -l nodegroup=efa-gpu -o wide

log "Installing the EFA device plugin (exposes vpc.amazonaws.com/efa)"
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install aws-efa-k8s-device-plugin eks/aws-efa-k8s-device-plugin \
  --namespace kube-system \
  --set tolerations[0].key=nvidia.com/gpu,tolerations[0].operator=Exists,tolerations[0].effect=NoSchedule

log "Ensuring the NVIDIA device plugin is present (install the DaemonSet if the add-on didn't)"
if ! kubectl -n kube-system get ds nvidia-device-plugin-daemonset >/dev/null 2>&1 \
   && ! kubectl get nodes -l nodegroup=efa-gpu -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null | grep -q '[1-9]'; then
  kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml
fi

log "Verifying the node monitoring agent DaemonSet is running"
kubectl -n kube-system get ds -l app.kubernetes.io/name=eks-node-monitoring-agent -o wide \
  || warn "NMA DaemonSet not found via label; check: kubectl -n kube-system get ds | grep node-monitoring"

log "EFA interfaces per node (vpc.amazonaws.com/efa allocatable); non-zero confirms EFA attached"
kubectl get nodes -l nodegroup=efa-gpu -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.vpc\.amazonaws\.com/efa}{"\n"}{end}'
