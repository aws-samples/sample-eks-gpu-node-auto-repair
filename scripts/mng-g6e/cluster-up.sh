#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require terraform aws kubectl jq

TF_DIR="${REPO_ROOT}/terraform/mng-g6e/cluster"
REGION="${AWS_REGION:-us-west-2}"
CLUSTER_NAME="${CLUSTER_NAME:-eks-gpu-mng-node-repair}"

log "Initializing Terraform"
terraform -chdir="${TF_DIR}" init -input=false

log "Applying MNG cluster + GPU node group in ${REGION} (~15-18 min)"
terraform -chdir="${TF_DIR}" apply -auto-approve -input=false \
  -var "region=${REGION}" -var "cluster_name=${CLUSTER_NAME}"

CLUSTER_NAME="$(terraform -chdir="${TF_DIR}" output -raw cluster_name)"
REGION="$(terraform -chdir="${TF_DIR}" output -raw region)"

log "Configuring kubectl"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"
kubectl get nodes || true
log "Cluster ready. Node monitoring agent runs as the eks-node-monitoring-agent add-on (DaemonSet)."
