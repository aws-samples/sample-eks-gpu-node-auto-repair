#!/usr/bin/env bash
# Build the FSDP training image via CodeBuild, based on the AWS DLC PyTorch training image.
# The image-build infrastructure (ECR repo, S3 build-context bucket, CodeBuild project,
# IAM role) is declared in terraform/p5en-efa/image and applied here; only the build run
# itself (start-build + poll) is imperative. AWS Deep Learning Containers are not replicated
# to every region, so CodeBuild pulls the DLC cross-region from DLC_SOURCE_REGION and pushes
# the derived image to the target-region ECR (the image IAM policy grants that pull).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require aws jq zip terraform
check_aws_context

REGION="${EFA_AWS_REGION}"
IMAGE_TF="${REPO_ROOT}/terraform/p5en-efa/image"
TAG="${IMAGE_TAG:-latest}"
DLC_SOURCE_REGION="${DLC_SOURCE_REGION:-us-west-2}"
DLC_IMAGE="${DLC_IMAGE_OVERRIDE:-763104351884.dkr.ecr.${DLC_SOURCE_REGION}.amazonaws.com/pytorch-training:2.6.0-gpu-py312-cu126-ubuntu22.04-ec2}"

log "Applying image-build Terraform layer (ECR, S3, CodeBuild project, IAM role)"
terraform -chdir="${IMAGE_TF}" init -input=false
terraform -chdir="${IMAGE_TF}" apply -auto-approve -input=false \
  -var "region=${REGION}" -var "dlc_source_region=${DLC_SOURCE_REGION}"

REPO="$(terraform -chdir="${IMAGE_TF}" output -raw ecr_repo_name)"
BUCKET="$(terraform -chdir="${IMAGE_TF}" output -raw bucket_name)"
PROJECT="$(terraform -chdir="${IMAGE_TF}" output -raw project_name)"
ECR_URL="$(terraform -chdir="${IMAGE_TF}" output -raw ecr_repo_url)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
IMAGE="${ECR_URL}:${TAG}"
SRC_KEY="build-context/efa-src.zip"

log "Packaging src/p5en-efa -> s3://${BUCKET}/${SRC_KEY}"
TMPZIP="$(mktemp -t efa-src-XXXX).zip"
( cd "${REPO_ROOT}/src/p5en-efa" && zip -qr "${TMPZIP}" . -x '*/__pycache__/*' '*.pyc' 'tests/*' )
aws s3 cp "${TMPZIP}" "s3://${BUCKET}/${SRC_KEY}" >/dev/null
rm -f "${TMPZIP}"

log "Starting CodeBuild"
ENV_OVERRIDE="[{\"name\":\"ACCOUNT_ID\",\"value\":\"${ACCOUNT_ID}\"},{\"name\":\"ECR_REPO\",\"value\":\"${REPO}\"},{\"name\":\"IMAGE_TAG\",\"value\":\"${TAG}\"},{\"name\":\"DLC_IMAGE\",\"value\":\"${DLC_IMAGE}\"},{\"name\":\"DLC_SOURCE_REGION\",\"value\":\"${DLC_SOURCE_REGION}\"}]"
BUILD_ID="$(aws codebuild start-build --project-name "${PROJECT}" --region "${REGION}" \
  --environment-variables-override "${ENV_OVERRIDE}" \
  --query 'build.id' --output text)"
while true; do
  ST="$(aws codebuild batch-get-builds --ids "${BUILD_ID}" --region "${REGION}" --query 'builds[0].buildStatus' --output text)"
  case "${ST}" in
    SUCCEEDED) log "Build SUCCEEDED"; break ;;
    IN_PROGRESS) sleep 20 ;;
    *) die "Build ${ST}; inspect: aws codebuild batch-get-builds --ids ${BUILD_ID} --region ${REGION}" ;;
  esac
done

echo "${IMAGE}" > "${REPO_ROOT}/.image-ref-p5en-efa"
log "Wrote .image-ref-p5en-efa: ${IMAGE}"
