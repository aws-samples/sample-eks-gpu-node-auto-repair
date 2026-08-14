#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require terraform kubectl aws jq envsubst

TF_DIR="${REPO_ROOT}/terraform/g6e/cluster"
CLUSTER_NAME="$(terraform -chdir="${TF_DIR}" output -raw cluster_name)"
REGION="$(terraform -chdir="${TF_DIR}" output -raw region)"
export CLUSTER_NAME

# Resolve the EKS Auto Mode managed node IAM role name for this cluster.
NODE_ROLE="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" \
  --query 'cluster.computeConfig.nodeRoleArn' --output text 2>/dev/null | awk -F/ '{print $NF}')"
[ -n "${NODE_ROLE}" ] && [ "${NODE_ROLE}" != "None" ] || \
  die "could not resolve Auto Mode node role; check cluster computeConfig"
export NODE_ROLE

log "Applying GPU NodeClass (role=${NODE_ROLE}, cluster=${CLUSTER_NAME})"
# Inject role into the NodeClass spec.role field and cluster name into selectors.
sed "s|^  role:.*|  role: ${NODE_ROLE}|" "${REPO_ROOT}/kubernetes/g6e/nodepool/gpu-nodeclass.yaml" \
  | envsubst '${CLUSTER_NAME}' | kubectl apply -f -

log "Applying GPU NodePool"
kubectl apply -f "${REPO_ROOT}/kubernetes/g6e/nodepool/gpu-nodepool.yaml"

log "Launching a GPU smoke pod to force provisioning of a g6e node"
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: gpu-smoke
  labels: { app: gpu-smoke }
spec:
  restartPolicy: Never
  nodeSelector: { karpenter.sh/nodepool: gpu }
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: cuda
      image: nvidia/cuda:12.4.1-base-ubuntu22.04
      command: ["bash", "-c", "nvidia-smi && sleep 3600"]
      resources:
        limits:
          nvidia.com/gpu: "1"
EOF

log "Waiting for GPU node to join (up to 5 min)"
for i in $(seq 1 30); do
  if kubectl get nodes -l karpenter.sh/nodepool=gpu --no-headers 2>/dev/null | grep -q Ready; then
    log "GPU node Ready"; break
  fi
  sleep 10
done

kubectl get nodes -l karpenter.sh/nodepool=gpu -o wide
log "Waiting for gpu-smoke pod to run nvidia-smi"
kubectl wait --for=condition=Ready pod/gpu-smoke --timeout=180s || warn "pod not Ready yet"
kubectl logs gpu-smoke | head -20 || true
