#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require terraform aws kubectl jq

TF_DIR="${REPO_ROOT}/terraform/g6e/cluster"
# Region and cluster name are env-driven (no need to edit any tfvars). AWS_REGION is the same
# knob the p5en path uses; both default sensibly. Only the cluster layer needs them — every
# downstream g6e script reads the region back from this layer's Terraform output.
REGION="${AWS_REGION:-us-west-2}"
CLUSTER_NAME="${CLUSTER_NAME:-eks-gpu-node-auto-repair}"

log "Initializing Terraform"
terraform -chdir="${TF_DIR}" init -input=false

log "Applying cluster in ${REGION} (this takes ~15 minutes)"
terraform -chdir="${TF_DIR}" apply -auto-approve -input=false \
  -var "region=${REGION}" -var "cluster_name=${CLUSTER_NAME}"

CLUSTER_NAME="$(terraform -chdir="${TF_DIR}" output -raw cluster_name)"
REGION="$(terraform -chdir="${TF_DIR}" output -raw region)"

log "Configuring kubectl for ${CLUSTER_NAME} in ${REGION}"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"

log "Waiting for cluster nodes/API to be reachable"
kubectl get nodes || true

log "Cluster ready. Verify Auto Mode with: kubectl get nodeclaims,nodepools"
