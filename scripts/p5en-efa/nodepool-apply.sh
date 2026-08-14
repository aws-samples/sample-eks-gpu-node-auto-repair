#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require terraform kubectl aws jq envsubst helm
check_aws_context

require_reservation
TF_DIR="${REPO_ROOT}/terraform/p5en-efa/cluster"
export CLUSTER_NAME="$(terraform -chdir="${TF_DIR}" output -raw cluster_name)"
export NODE_ROLE="$(terraform -chdir="${TF_DIR}" output -raw node_role_name)"
export PLACEMENT_GROUP="$(terraform -chdir="${TF_DIR}" output -raw placement_group_name)"
export CLUSTER_SG="$(terraform -chdir="${TF_DIR}" output -raw cluster_security_group_id)"
export CR_ID="${EFA_CR_ID}"
export CR_OWNER="${EFA_CR_OWNER}"
export EFA_AZ="${EFA_AZ}"

log "Applying EFA NodeClass (role=${NODE_ROLE}, pg=${PLACEMENT_GROUP}, cr=${CR_ID})"
envsubst '${NODE_ROLE} ${CLUSTER_NAME} ${CLUSTER_SG} ${PLACEMENT_GROUP} ${CR_ID} ${CR_OWNER}' \
  < "${REPO_ROOT}/kubernetes/p5en-efa/nodepool/gpu-nodeclass.yaml" | kubectl apply -f -

log "Applying EFA NodePool"
envsubst '${EFA_AZ}' \
  < "${REPO_ROOT}/kubernetes/p5en-efa/nodepool/gpu-nodepool.yaml" | kubectl apply -f -

log "Installing aws-efa-k8s-device-plugin (exposes vpc.amazonaws.com/efa)"
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install aws-efa-k8s-device-plugin eks/aws-efa-k8s-device-plugin \
  --namespace kube-system \
  --set tolerations[0].key=nvidia.com/gpu,tolerations[0].operator=Exists,tolerations[0].effect=NoSchedule

log "Launching a 2-node placeholder to force provisioning from the reservation"
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: efa-warm
spec:
  replicas: 2
  selector: { matchLabels: { app: efa-warm } }
  template:
    metadata: { labels: { app: efa-warm } }
    spec:
      nodeSelector: { karpenter.sh/nodepool: efa-gpu }
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector: { matchExpressions: [ { key: app, operator: In, values: [efa-warm] } ] }
              topologyKey: kubernetes.io/hostname
      tolerations:
        - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
      containers:
        - name: pause
          image: public.ecr.aws/eks-distro/kubernetes/pause:3.10
          resources: { limits: { nvidia.com/gpu: "8" } }
EOF

log "Waiting up to 10 min for 2 p5en nodes to become Ready"
for i in $(seq 1 60); do
  # `grep -c` exits 1 when the count is 0; under `set -e` that would abort the loop, so
  # guard with `|| true` and default an empty result to 0.
  ready="$(kubectl get nodes -l karpenter.sh/nodepool=efa-gpu --no-headers 2>/dev/null | grep -c ' Ready ' || true)"
  [ "${ready:-0}" -ge 2 ] && { log "2 p5en nodes Ready"; break; }
  sleep 10
done
kubectl get nodes -l karpenter.sh/nodepool=efa-gpu -o wide
