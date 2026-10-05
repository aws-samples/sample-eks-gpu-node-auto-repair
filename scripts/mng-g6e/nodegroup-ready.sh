#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl aws jq

log "Waiting for GPU MNG nodes to be Ready (up to 8 min)"
for _ in $(seq 1 48); do
  if kubectl get nodes -l nodegroup=gpu --no-headers 2>/dev/null | grep -q ' Ready'; then
    log "GPU node(s) Ready"; break
  fi
  sleep 10
done
kubectl get nodes -l nodegroup=gpu -o wide

log "Ensuring the NVIDIA device plugin is present (install the DaemonSet if the add-on didn't)"
if ! kubectl -n kube-system get ds nvidia-device-plugin-daemonset >/dev/null 2>&1 \
   && ! kubectl get nodes -l nodegroup=gpu -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null | grep -q '[1-9]'; then
  kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml
fi

log "Verifying the node monitoring agent DaemonSet is running"
kubectl -n kube-system get ds -l app.kubernetes.io/name=eks-node-monitoring-agent -o wide \
  || warn "NMA DaemonSet not found via label; check: kubectl -n kube-system get ds | grep node-monitoring"

log "Verifying GPU is schedulable"
kubectl get nodes -l nodegroup=gpu -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
