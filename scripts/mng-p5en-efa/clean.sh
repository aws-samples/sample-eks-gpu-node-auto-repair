#!/usr/bin/env bash
# Scoped teardown for the mng-p5en-efa path: FSx storage, then the cluster layer (which includes
# the EFA managed node group + its p5en instances, placement group, and EFA SG). Deletes ONLY
# resources this overlay created, matched by Terraform state + our unique prefix. NEVER touches
# the capacity reservation, nor the SHARED DLC training image infra (that lives in the p5en-efa
# path and is reused here).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require terraform kubectl aws
check_aws_context
require_az

CLUSTER_TF="${REPO_ROOT}/terraform/mng-p5en-efa/cluster"
STORAGE_TF="${REPO_ROOT}/terraform/mng-p5en-efa/storage"
CLUSTER_NAME="$(terraform -chdir="${CLUSTER_TF}" output -raw cluster_name 2>/dev/null || echo "${EFA_CLUSTER_NAME}")"
# Placement group name is deterministic ("<cluster_name>-pg"); prefer the Terraform output but
# fall back to the known pattern so we can still reap it if state is partially gone.
PG_NAME="$(terraform -chdir="${CLUSTER_TF}" output -raw placement_group_name 2>/dev/null || true)"
[ -n "${PG_NAME}" ] || PG_NAME="${CLUSTER_NAME}-pg"

log "=== This DESTROYS the mng-p5en-efa cluster (incl. the EFA GPU node group + its p5en"
log "    instances) and the FSx storage. It does NOT touch the capacity reservation"
log "    ${EFA_CR_ID:-<none>}, and it does NOT destroy the SHARED DLC training image infra. ==="
printf "Proceed? [y/N] "; read -r ans; [ "${ans}" = "y" ] || die "aborted"

log "Deleting training + benchmark workloads and PVC (releases FSx via reclaim Delete)"
# The EFA managed node group is owned by Terraform (no Karpenter autoscaling CRDs on this path),
# so it is torn down by the cluster-layer destroy below.
kubectl delete jobset fsdp-train nccl-bench --ignore-not-found 2>/dev/null || true
kubectl delete deploy efa-warm --ignore-not-found 2>/dev/null || true
kubectl delete job dcgm-inject --ignore-not-found 2>/dev/null || true
kubectl delete pvc fsx-efa-checkpoints --ignore-not-found 2>/dev/null || true
log "Waiting for PVC/FSx deletion to complete (up to 15 min) before destroying storage"
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

log "Destroying the mng-p5en-efa cluster Terraform layer (VPC, cluster, EFA node group, PG, SG, IAM policy)"
# EKS auto-creates a cluster security group (eks-cluster-sg-*, tagged
# kubernetes.io/cluster/<name>=owned) that Terraform does NOT manage; once the cluster is gone it
# lingers and blocks VPC deletion, hanging the destroy. Remove it in the background as soon as its
# ENIs release so the VPC destroy completes unattended. NOTE: the EFA SG + placement group can lag
# behind instance termination and this reaper can race the Terraform SG-rule revoke, which is why
# the destroy below is retried once.
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
# Teardown-race hardening: the EFA SG + placement group can lag behind
# instance termination, so the first destroy can fail on a still-referenced SG. Re-run once; the
# second pass clears resources that were mid-deletion.
if ! terraform -chdir="${CLUSTER_TF}" destroy -auto-approve -input=false \
     -var "region=${EFA_AWS_REGION}" -var "cluster_name=${EFA_CLUSTER_NAME}" \
     -var "availability_zone=${EFA_AZ}" \
     -var "capacity_reservation_id=${EFA_CR_ID}" \
     -var "capacity_type=${EFA_CAPACITY_TYPE}" \
     -var "enable_nat_gateway=${EFA_ENABLE_NAT}" \
     -var "enable_vpc_endpoints=${EFA_ENABLE_VPCE}"; then
  warn "cluster destroy exited non-zero (likely a lagging EFA SG / placement group); retrying once in 60s"
  sleep 60
  terraform -chdir="${CLUSTER_TF}" destroy -auto-approve -input=false \
    -var "region=${EFA_AWS_REGION}" -var "cluster_name=${EFA_CLUSTER_NAME}" \
    -var "availability_zone=${EFA_AZ}" \
    -var "capacity_reservation_id=${EFA_CR_ID}" \
    -var "capacity_type=${EFA_CAPACITY_TYPE}" \
    -var "enable_nat_gateway=${EFA_ENABLE_NAT}" \
    -var "enable_vpc_endpoints=${EFA_ENABLE_VPCE}" || warn "second cluster destroy still failed; inspect manually"
fi
kill "${SG_CLEANUP_PID}" 2>/dev/null || true

# Reap the EFA cluster placement group if Terraform left it behind (it can lag the node-group
# delete). A placement group refuses to delete while any instance remains in it, so confirm it's
# empty first.
if [ -n "${PG_NAME}" ]; then
  PG_INSTANCES="$(aws ec2 describe-instances --region "${EFA_AWS_REGION}" \
    --filters "Name=placement-group-name,Values=${PG_NAME}" "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
  if [ -z "${PG_INSTANCES}" ] || [ "${PG_INSTANCES}" = "None" ]; then
    aws ec2 delete-placement-group --group-name "${PG_NAME}" --region "${EFA_AWS_REGION}" >/dev/null 2>&1 \
      && log "removed orphaned placement group ${PG_NAME}" || true
  else
    warn "placement group ${PG_NAME} still has instances (${PG_INSTANCES}); not deleting — re-run clean once they terminate"
  fi
fi

log "NOTE: the DLC training image build infra is SHARED with the p5en-efa path and"
log "is NOT destroyed here. Run 'make p5en-efa-clean' to remove the shared image-build infra."

log "Teardown complete. The capacity reservation ${EFA_CR_ID:-<none>} was NOT modified."
