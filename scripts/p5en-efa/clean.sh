#!/usr/bin/env bash
# Full scoped teardown for the p5en/EFA path: FSx storage, then the cluster layer, then the
# image-build infra. Deletes ONLY resources this overlay created, matched by Terraform state +
# our unique prefix. NEVER touches the capacity reservation or any pre-existing resource.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require terraform kubectl aws
check_aws_context
require_az

CLUSTER_TF="${REPO_ROOT}/terraform/p5en-efa/cluster"
STORAGE_TF="${REPO_ROOT}/terraform/p5en-efa/storage"
IMAGE_TF="${REPO_ROOT}/terraform/p5en-efa/image"
CLUSTER_NAME="$(terraform -chdir="${CLUSTER_TF}" output -raw cluster_name 2>/dev/null || echo eks-gpu-efa)"

log "=== DRY-RUN: resources that will be deleted (all bearing prefix ${EFA_PREFIX}) ==="
echo "  k8s: JobSet/fsdp-train, JobSet/nccl-bench, Deployment/efa-warm, NodePool/efa-gpu, NodeClass/efa-gpu, dcgm-inject, PVC/fsx-efa-checkpoints"
echo "  terraform: FSx storage layer, VPC, EKS cluster ${EFA_CLUSTER_NAME}, placement group, EFA SG, reservations IAM policy, image-build infra (ECR/S3/CodeBuild/IAM)"
echo "  NOT touched: reservation ${EFA_CR_ID}, or any pre-existing resource in the account"
printf "Proceed? [y/N] "; read -r ans; [ "${ans}" = "y" ] || die "aborted"

log "Deleting training + benchmark workloads and PVC (releases FSx via reclaim Delete)"
kubectl delete jobset fsdp-train nccl-bench --ignore-not-found 2>/dev/null || true
kubectl delete deploy efa-warm --ignore-not-found 2>/dev/null || true
kubectl delete job dcgm-inject --ignore-not-found 2>/dev/null || true
kubectl delete pvc fsx-efa-checkpoints --ignore-not-found 2>/dev/null || true
log "Waiting for FSx deletion before destroying the storage layer"
kubectl wait --for=delete pvc/fsx-efa-checkpoints --timeout=900s 2>/dev/null || true
sleep 30

log "Destroying FSx storage Terraform layer"
terraform -chdir="${STORAGE_TF}" destroy -auto-approve -input=false \
  -var "region=${EFA_AWS_REGION}" -var "cluster_name=${CLUSTER_NAME}" -var "availability_zone=${EFA_AZ}" || \
  warn "storage layer destroy skipped/failed (may not be applied)"

log "Removing FSx CSI Pod Identity role (best-effort)"
FSX_ROLE="${CLUSTER_NAME}-fsx-csi"
ASSOC="$(aws eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}" --region "${EFA_AWS_REGION}" --query 'associations[?serviceAccount==`fsx-csi-controller-sa`].associationId' --output text 2>/dev/null || true)"
[ -n "${ASSOC}" ] && [ "${ASSOC}" != "None" ] && aws eks delete-pod-identity-association --cluster-name "${CLUSTER_NAME}" --region "${EFA_AWS_REGION}" --association-id "${ASSOC}" >/dev/null 2>&1 || true
aws iam detach-role-policy --role-name "${FSX_ROLE}" --policy-arn arn:aws:iam::aws:policy/AmazonFSxFullAccess >/dev/null 2>&1 || true
aws iam delete-role --role-name "${FSX_ROLE}" >/dev/null 2>&1 || true

log "Deleting NodePool/NodeClass and waiting 60s for Karpenter to release p5en nodes back to the reservation"
# --wait=false: Karpenter puts a finalizer on NodePool/NodeClass that only clears once the
# nodes it owns are fully drained. After a fault/repair the faulted node is often NotReady and
# never drains cleanly, so a blocking `kubectl delete` hangs forever. Request deletion without
# waiting; the cluster-layer `terraform destroy` below tears the nodes/instances down anyway.
kubectl delete -f "${REPO_ROOT}/kubernetes/p5en-efa/nodepool/gpu-nodepool.yaml" --ignore-not-found --wait=false 2>/dev/null || true
kubectl delete nodeclass.eks.amazonaws.com efa-gpu --ignore-not-found --wait=false 2>/dev/null || true
sleep 60

log "Destroying the EFA cluster Terraform layer (VPC, cluster, PG, SG, IAM policy)"
# EKS auto-creates a cluster security group (eks-cluster-sg-*, tagged
# kubernetes.io/cluster/<name>=owned) that Terraform does NOT manage; once the cluster is gone it
# lingers and blocks VPC deletion, hanging the destroy. Remove it in the background as soon as its
# ENIs release so the VPC destroy completes unattended.
(
  for _ in $(seq 1 60); do
    SG="$(aws ec2 describe-security-groups --region "${EFA_AWS_REGION}" \
      --filters "Name=tag:kubernetes.io/cluster/${EFA_CLUSTER_NAME},Values=owned" \
      --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null || true)"
    if [ -n "${SG}" ] && [ "${SG}" != "None" ]; then
      for g in ${SG}; do aws ec2 delete-security-group --group-id "${g}" --region "${EFA_AWS_REGION}" >/dev/null 2>&1 && log "removed orphaned EKS cluster SG ${g}"; done
    fi
    sleep 30
  done
) &
SG_CLEANUP_PID=$!
terraform -chdir="${CLUSTER_TF}" destroy -auto-approve -input=false \
  -var "region=${EFA_AWS_REGION}" -var "cluster_name=${EFA_CLUSTER_NAME}" \
  -var "availability_zone=${EFA_AZ}" -var "enable_nat_gateway=${EFA_ENABLE_NAT}" \
  -var "enable_vpc_endpoints=${EFA_ENABLE_VPCE}"
kill "${SG_CLEANUP_PID}" 2>/dev/null || true

log "Destroying image-build Terraform layer (ECR, S3, CodeBuild, IAM)"
terraform -chdir="${IMAGE_TF}" destroy -auto-approve -input=false \
  -var "region=${EFA_AWS_REGION}" 2>/dev/null || warn "image layer destroy skipped/failed (may not be applied)"

log "Teardown complete. The capacity reservation ${EFA_CR_ID} was NOT modified."
