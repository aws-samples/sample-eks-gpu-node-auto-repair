#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require terraform kubectl helm aws jq envsubst

CLUSTER_TF="${REPO_ROOT}/terraform/g6e/cluster"
STORAGE_TF="${REPO_ROOT}/terraform/g6e/storage"
REGION="$(terraform -chdir="${CLUSTER_TF}" output -raw region)"
CLUSTER_NAME="$(terraform -chdir="${CLUSTER_TF}" output -raw cluster_name)"

log "Applying storage Terraform layer (FSx security group)"
terraform -chdir="${STORAGE_TF}" init -input=false
terraform -chdir="${STORAGE_TF}" apply -auto-approve -input=false \
  -var "region=${REGION}" -var "cluster_name=${CLUSTER_NAME}"

FSX_SG_ID="$(terraform -chdir="${STORAGE_TF}" output -raw fsx_security_group_id)"
FSX_SUBNET_ID="$(terraform -chdir="${STORAGE_TF}" output -raw fsx_subnet_id)"
export FSX_SG_ID FSX_SUBNET_ID

log "Installing/upgrading the FSx for Lustre CSI driver (Auto Mode variant)"
helm repo add aws-fsx-csi-driver https://kubernetes-sigs.github.io/aws-fsx-csi-driver >/dev/null 2>&1 || true
helm repo update >/dev/null
# controller.region is REQUIRED on Auto Mode (IMDS is blocked for non-hostNetwork pods).
helm upgrade --install aws-fsx-csi-driver aws-fsx-csi-driver/aws-fsx-csi-driver \
  --namespace kube-system \
  --set controller.region="${REGION}"

log "Waiting for FSx CSI controller to be ready"
kubectl -n kube-system rollout status deploy/fsx-csi-controller --timeout=180s || \
  warn "FSx CSI controller not ready yet"

# The FSx CSI controller needs AWS credentials to call the FSx API. On EKS Auto Mode,
# IMDS is blocked for non-hostNetwork pods, so we grant the controller's service account
# (fsx-csi-controller-sa) an IAM role via EKS Pod Identity.
FSX_ROLE="${CLUSTER_NAME}-fsx-csi"
log "Ensuring FSx CSI IAM role ${FSX_ROLE} (EKS Pod Identity) exists"
if ! aws iam get-role --role-name "${FSX_ROLE}" >/dev/null 2>&1; then
  TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}'
  aws iam create-role --role-name "${FSX_ROLE}" --assume-role-policy-document "${TRUST}" >/dev/null
  aws iam attach-role-policy --role-name "${FSX_ROLE}" \
    --policy-arn arn:aws:iam::aws:policy/AmazonFSxFullAccess >/dev/null
fi
FSX_ROLE_ARN="$(aws iam get-role --role-name "${FSX_ROLE}" --query 'Role.Arn' --output text)"

# Associate the role with the CSI controller's service account (idempotent).
if ! aws eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}" --region "${REGION}" \
     --query 'associations[?serviceAccount==`fsx-csi-controller-sa`]' --output text 2>/dev/null | grep -q .; then
  log "Creating Pod Identity association for fsx-csi-controller-sa"
  aws eks create-pod-identity-association --cluster-name "${CLUSTER_NAME}" --region "${REGION}" \
    --namespace kube-system --service-account fsx-csi-controller-sa \
    --role-arn "${FSX_ROLE_ARN}" >/dev/null
  # Pod Identity env vars are injected at pod ADMISSION based on the association existing. The
  # association takes a short time to propagate to the admission webhook; if we restart the
  # controller immediately, the new pods are admitted WITHOUT the injection and fall back to
  # IMDS (blocked on Auto Mode) -> "no EC2 IMDS role found" and FSx creation fails. Wait for
  # propagation before restarting so the fresh pods pick up credentials.
  log "Waiting 30s for the Pod Identity association to propagate before restarting the controller"
  sleep 30
  log "Restarting FSx CSI controller to pick up Pod Identity credentials"
  kubectl -n kube-system rollout restart deploy/fsx-csi-controller
  kubectl -n kube-system rollout status deploy/fsx-csi-controller --timeout=180s || \
    warn "FSx CSI controller not ready yet"
  # Verify the injection actually landed; if not, the FSx CreateFileSystem call will fail.
  POD="$(kubectl -n kube-system get pods -l app=fsx-csi-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${POD}" ] && ! kubectl -n kube-system exec "${POD}" -c fsx-plugin -- \
       sh -c 'test -n "$AWS_CONTAINER_CREDENTIALS_FULL_URI"' 2>/dev/null; then
    warn "Pod Identity creds not yet injected into the FSx CSI controller; retrying a restart"
    sleep 20
    kubectl -n kube-system rollout restart deploy/fsx-csi-controller
    kubectl -n kube-system rollout status deploy/fsx-csi-controller --timeout=180s || true
  fi
fi

log "Applying StorageClass (subnet=${FSX_SUBNET_ID}, sg=${FSX_SG_ID})"
envsubst '${FSX_SUBNET_ID} ${FSX_SG_ID}' \
  < "${REPO_ROOT}/kubernetes/g6e/fsx/storageclass.yaml" | kubectl apply -f -

log "Applying PVC (this triggers FSx filesystem creation; ~6-10 min)"
kubectl apply -f "${REPO_ROOT}/kubernetes/g6e/fsx/pvc.yaml"

log "Waiting for PVC to bind (up to 15 min)"
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/fsx-checkpoints --timeout=1200s

kubectl get pvc fsx-checkpoints
log "FSx storage ready."
