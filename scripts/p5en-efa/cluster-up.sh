#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require terraform aws kubectl jq
check_aws_context
require_reservation

TF_DIR="${REPO_ROOT}/terraform/p5en-efa/cluster"

log "Verifying capacity reservation ${EFA_CR_ID} is available"
AVAIL="$(aws ec2 describe-capacity-reservations --capacity-reservation-ids "${EFA_CR_ID}" \
  --region "${EFA_AWS_REGION}" --query 'CapacityReservations[0].AvailableInstanceCount' --output text 2>/dev/null || echo 0)"
log "Reservation available instances: ${AVAIL}"
[ "${AVAIL}" != "None" ] && [ "${AVAIL}" -ge 2 ] 2>/dev/null || \
  warn "reservation has <2 available instances (${AVAIL}); the 2-node workload may not schedule"

log "Initializing Terraform"
terraform -chdir="${TF_DIR}" init -input=false

log "Applying EFA cluster layer (~15 min)"
terraform -chdir="${TF_DIR}" apply -auto-approve -input=false \
  -var "region=${EFA_AWS_REGION}" -var "cluster_name=${EFA_CLUSTER_NAME}" \
  -var "availability_zone=${EFA_AZ}" -var "enable_nat_gateway=${EFA_ENABLE_NAT}" \
  -var "enable_vpc_endpoints=${EFA_ENABLE_VPCE}"

CN="$(terraform -chdir="${TF_DIR}" output -raw cluster_name)"
log "Configuring kubectl for ${CN}"
aws eks update-kubeconfig --name "${CN}" --region "${EFA_AWS_REGION}"

log "Auto Mode cluster ready. Custom NodePools required (no built-in pools). Next: make p5en-efa-nodepool"
