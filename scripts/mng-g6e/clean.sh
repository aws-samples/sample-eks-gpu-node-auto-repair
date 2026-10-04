#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl terraform aws

CLUSTER_TF="${REPO_ROOT}/terraform/mng-g6e/cluster"
STORAGE_TF="${REPO_ROOT}/terraform/mng-g6e/storage"
# `terraform output` prints a warning to stdout (exit 0) when state is empty/absent, so validate
# the region looks real and otherwise fall back to AWS_REGION / aws config / the sample default.
REGION="$(terraform -chdir="${CLUSTER_TF}" output -raw region 2>/dev/null || true)"
if ! printf '%s' "${REGION}" | grep -Eq '^[a-z]{2}-[a-z]+-[0-9]$'; then
  REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
fi
[ -n "${REGION}" ] || REGION="us-west-2"
CLUSTER_NAME="$(terraform -chdir="${CLUSTER_TF}" output -raw cluster_name 2>/dev/null || echo eks-gpu-mng-node-repair)"

log "=== This will DESTROY the mng-g6e cluster and FSx storage (NOT the shared image-build infra) ==="
printf "Proceed? [y/N] "; read -r ans; [ "${ans}" = "y" ] || die "aborted"

log "Deleting training workload"
kubectl delete jobset train --ignore-not-found 2>/dev/null || true

log "Deleting spike/smoke pods (best-effort)"
# No Karpenter NodePool/NodeClass on the mng-g6e path: the managed node group is owned by
# Terraform and torn down by the cluster-layer destroy below.
kubectl delete pod dcgm-inject gpu-smoke --ignore-not-found 2>/dev/null || true

log "Deleting PVC (releases the FSx filesystem via reclaimPolicy Delete)"
kubectl delete pvc fsx-checkpoints --ignore-not-found 2>/dev/null || true
log "Waiting for PVC/FSx deletion to complete (up to 10 min) before destroying storage"
kubectl wait --for=delete pvc/fsx-checkpoints --timeout=600s 2>/dev/null || true
sleep 30

log "Destroying storage Terraform layer"
terraform -chdir="${STORAGE_TF}" destroy -auto-approve -input=false \
  -var "region=${REGION}" -var "cluster_name=${CLUSTER_NAME}" 2>/dev/null || \
  warn "storage layer destroy skipped/failed (may not be applied)"

log "Destroying cluster Terraform layer"
# EKS auto-creates a cluster security group (eks-cluster-sg-<cluster>-*, tagged
# kubernetes.io/cluster/<name>=owned) that Terraform does NOT manage. Once the cluster is gone
# it lingers and blocks VPC deletion, hanging `terraform destroy` indefinitely. Delete it in the
# background as soon as its ENIs are released, so the VPC destroy can complete unattended.
(
  for _ in $(seq 1 60); do
    SG="$(aws ec2 describe-security-groups --region "${REGION}" \
      --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
      --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null || true)"
    if [ -n "${SG}" ] && [ "${SG}" != "None" ]; then
      # Only deletable once no ENIs reference it (i.e. cluster teardown has progressed).
      for g in ${SG}; do aws ec2 delete-security-group --group-id "${g}" --region "${REGION}" >/dev/null 2>&1 && log "removed orphaned EKS cluster SG ${g}"; done
    fi
    sleep 30
  done
) &
SG_CLEANUP_PID=$!
terraform -chdir="${CLUSTER_TF}" destroy -auto-approve -input=false
kill "${SG_CLEANUP_PID}" 2>/dev/null || true

log "Removing FSx CSI Pod Identity association and IAM role (best-effort)"
FSX_ROLE="${CLUSTER_NAME}-fsx-csi"
ASSOC_ID="$(aws eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}" --region "${REGION}" \
  --query 'associations[?serviceAccount==`fsx-csi-controller-sa`].associationId' --output text 2>/dev/null || true)"
if [ -n "${ASSOC_ID}" ] && [ "${ASSOC_ID}" != "None" ]; then
  aws eks delete-pod-identity-association --cluster-name "${CLUSTER_NAME}" --region "${REGION}" \
    --association-id "${ASSOC_ID}" >/dev/null 2>&1 || true
fi
aws iam detach-role-policy --role-name "${FSX_ROLE}" \
  --policy-arn arn:aws:iam::aws:policy/AmazonFSxFullAccess >/dev/null 2>&1 || true
aws iam delete-role --role-name "${FSX_ROLE}" >/dev/null 2>&1 || true

log "NOTE: the training image (terraform/g6e/image) is SHARED with the g6e path and is NOT"
log "destroyed here. Run 'make g6e-clean' to remove the shared image-build infra."

log "Teardown complete."
