#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require terraform kubectl helm aws jq envsubst
check_aws_context

require_az
CLUSTER_TF="${REPO_ROOT}/terraform/p5en-efa/cluster"
STORAGE_TF="${REPO_ROOT}/terraform/p5en-efa/storage"
CLUSTER_NAME="$(terraform -chdir="${CLUSTER_TF}" output -raw cluster_name)"

log "Applying FSx storage layer"
terraform -chdir="${STORAGE_TF}" init -input=false
terraform -chdir="${STORAGE_TF}" apply -auto-approve -input=false \
  -var "region=${EFA_AWS_REGION}" -var "cluster_name=${CLUSTER_NAME}" -var "availability_zone=${EFA_AZ}"

export FSX_SG_ID="$(terraform -chdir="${STORAGE_TF}" output -raw fsx_security_group_id)"
export FSX_SUBNET_ID="$(terraform -chdir="${STORAGE_TF}" output -raw fsx_subnet_id)"

log "Installing FSx CSI driver"
helm repo add aws-fsx-csi-driver https://kubernetes-sigs.github.io/aws-fsx-csi-driver >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install aws-fsx-csi-driver aws-fsx-csi-driver/aws-fsx-csi-driver \
  --namespace kube-system --set controller.region="${EFA_AWS_REGION}"
kubectl -n kube-system rollout status deploy/fsx-csi-controller --timeout=180s || warn "csi not ready"

# Grant the CSI controller AWS access via EKS Pod Identity (Auto Mode blocks IMDS).
FSX_ROLE="${CLUSTER_NAME}-fsx-csi"
if ! aws iam get-role --role-name "${FSX_ROLE}" >/dev/null 2>&1; then
  TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}'
  aws iam create-role --role-name "${FSX_ROLE}" --assume-role-policy-document "${TRUST}" >/dev/null
  aws iam attach-role-policy --role-name "${FSX_ROLE}" --policy-arn arn:aws:iam::aws:policy/AmazonFSxFullAccess >/dev/null
fi
FSX_ROLE_ARN="$(aws iam get-role --role-name "${FSX_ROLE}" --query 'Role.Arn' --output text)"
if ! aws eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}" --region "${EFA_AWS_REGION}" \
     --query 'associations[?serviceAccount==`fsx-csi-controller-sa`]' --output text 2>/dev/null | grep -q .; then
  aws eks create-pod-identity-association --cluster-name "${CLUSTER_NAME}" --region "${EFA_AWS_REGION}" \
    --namespace kube-system --service-account fsx-csi-controller-sa --role-arn "${FSX_ROLE_ARN}" >/dev/null
  # Pod Identity env is injected at pod ADMISSION; the association needs a moment to propagate to
  # the admission webhook. Restart too soon and the new pods are admitted without credentials and
  # fall back to IMDS (blocked on Auto Mode) -> FSx CreateFileSystem fails. Wait, then restart.
  log "Waiting 30s for the Pod Identity association to propagate before restarting the controller"
  sleep 30
  kubectl -n kube-system rollout restart deploy/fsx-csi-controller
  kubectl -n kube-system rollout status deploy/fsx-csi-controller --timeout=180s || warn "csi not ready"
  POD="$(kubectl -n kube-system get pods -l app=fsx-csi-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${POD}" ] && ! kubectl -n kube-system exec "${POD}" -c fsx-plugin -- \
       sh -c 'test -n "$AWS_CONTAINER_CREDENTIALS_FULL_URI"' 2>/dev/null; then
    warn "Pod Identity creds not yet injected; retrying a restart"
    sleep 20
    kubectl -n kube-system rollout restart deploy/fsx-csi-controller
    kubectl -n kube-system rollout status deploy/fsx-csi-controller --timeout=180s || true
  fi
fi

log "Applying StorageClass + PVC (FSx creation ~10-13 min)"
envsubst '${FSX_SUBNET_ID} ${FSX_SG_ID}' < "${REPO_ROOT}/kubernetes/p5en-efa/fsx/storageclass.yaml" | kubectl apply -f -
kubectl apply -f "${REPO_ROOT}/kubernetes/p5en-efa/fsx/pvc.yaml"
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/fsx-efa-checkpoints --timeout=1200s
kubectl get pvc fsx-efa-checkpoints
log "FSx ready."
