#!/usr/bin/env bash
# Provision the standard EKS cluster with its EFA GPU managed node group. Unlike the Auto Mode
# p5en-efa path, the managed node group (and its 2 p5en.48xlarge nodes) come up WITH this
# Terraform apply — there is no separate node-provisioning step.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require terraform aws kubectl jq
check_aws_context
require_reservation

TF_DIR="${REPO_ROOT}/terraform/mng-p5en-efa/cluster"

log "Verifying capacity reservation ${EFA_CR_ID} is available"
AVAIL="$(aws ec2 describe-capacity-reservations --capacity-reservation-ids "${EFA_CR_ID}" \
  --region "${EFA_AWS_REGION}" --query 'CapacityReservations[0].AvailableInstanceCount' --output text 2>/dev/null || echo 0)"
log "Reservation available instances: ${AVAIL}"
[ "${AVAIL}" != "None" ] && [ "${AVAIL}" -ge 2 ] 2>/dev/null || \
  warn "reservation has <2 available instances (${AVAIL}); the 2-node workload may not schedule"

log "Initializing Terraform"
terraform -chdir="${TF_DIR}" init -input=false

log "Applying MNG EFA cluster + GPU node group (~15-18 min)"
terraform -chdir="${TF_DIR}" apply -auto-approve -input=false \
  -var "region=${EFA_AWS_REGION}" -var "cluster_name=${EFA_CLUSTER_NAME}" \
  -var "availability_zone=${EFA_AZ}" \
  -var "capacity_reservation_id=${EFA_CR_ID}" \
  -var "capacity_type=${EFA_CAPACITY_TYPE}" \
  -var "enable_nat_gateway=${EFA_ENABLE_NAT}" \
  -var "enable_vpc_endpoints=${EFA_ENABLE_VPCE}"

CN="$(terraform -chdir="${TF_DIR}" output -raw cluster_name)"
log "Configuring kubectl for ${CN}"
aws eks update-kubeconfig --name "${CN}" --region "${EFA_AWS_REGION}"
kubectl get nodes || true

log "MNG cluster ready. The EFA node group + its nodes provision with the cluster (no separate node step)."
log "Next: make mng-p5en-efa-nodegroup to await the 2 EFA GPU nodes and install device plugins."
