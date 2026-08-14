#!/usr/bin/env bash
# Build and push the training image using AWS CodeBuild (no local Docker).
# CodeBuild runs on a native linux/amd64 host, avoiding slow emulated cross-builds
# on Apple Silicon and keeping the sample reproducible without a local Docker daemon.
# The image-build infrastructure (ECR repo, S3 build-context bucket, CodeBuild project,
# IAM role) is declared in terraform/g6e/image and applied here; only the build run
# itself (start-build + poll) is imperative.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require aws jq zip terraform

CLUSTER_TF="${REPO_ROOT}/terraform/g6e/cluster"
IMAGE_TF="${REPO_ROOT}/terraform/g6e/image"
# Prefer the cluster layer's region output; but `terraform output` prints a warning to stdout
# (exit 0) when the state is empty/absent, so validate the value looks like a region and
# otherwise fall back to AWS_REGION / aws config / the sample default.
REGION="$(terraform -chdir="${CLUSTER_TF}" output -raw region 2>/dev/null || true)"
if ! printf '%s' "${REGION}" | grep -Eq '^[a-z]{2}-[a-z]+-[0-9]$'; then
  REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
fi
[ -n "${REGION}" ] || REGION="us-west-2"
TAG="${IMAGE_TAG:-latest}"

log "Applying image-build Terraform layer (ECR, S3, CodeBuild project, IAM role)"
terraform -chdir="${IMAGE_TF}" init -input=false
terraform -chdir="${IMAGE_TF}" apply -auto-approve -input=false -var "region=${REGION}"

REPO="$(terraform -chdir="${IMAGE_TF}" output -raw ecr_repo_name)"
BUCKET="$(terraform -chdir="${IMAGE_TF}" output -raw bucket_name)"
PROJECT="$(terraform -chdir="${IMAGE_TF}" output -raw project_name)"
ECR_URL="$(terraform -chdir="${IMAGE_TF}" output -raw ecr_repo_url)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
IMAGE="${ECR_URL}:${TAG}"
SRC_KEY="build-context/src.zip"

log "Packaging build context (src/g6e) -> s3://${BUCKET}/${SRC_KEY}"
TMPZIP="$(mktemp -t src-XXXX).zip"
( cd "${REPO_ROOT}/src/g6e" && zip -qr "${TMPZIP}" . -x '*/__pycache__/*' '*.pyc' 'tests/*' )
aws s3 cp "${TMPZIP}" "s3://${BUCKET}/${SRC_KEY}" >/dev/null
rm -f "${TMPZIP}"

log "Starting CodeBuild build"
ENV_OVERRIDE="[{\"name\":\"ACCOUNT_ID\",\"value\":\"${ACCOUNT_ID}\"},{\"name\":\"ECR_REPO\",\"value\":\"${REPO}\"},{\"name\":\"IMAGE_TAG\",\"value\":\"${TAG}\"}]"
BUILD_ID="$(aws codebuild start-build --project-name "${PROJECT}" --region "${REGION}" \
  --environment-variables-override "${ENV_OVERRIDE}" \
  --query 'build.id' --output text)"
log "Build started: ${BUILD_ID}"

log "Waiting for build to complete..."
while true; do
  STATUS="$(aws codebuild batch-get-builds --ids "${BUILD_ID}" --region "${REGION}" \
    --query 'builds[0].buildStatus' --output text)"
  case "${STATUS}" in
    SUCCEEDED) log "Build SUCCEEDED"; break ;;
    IN_PROGRESS) sleep 15 ;;
    *) die "Build ${STATUS}. Inspect: aws codebuild batch-get-builds --ids ${BUILD_ID} --region ${REGION}" ;;
  esac
done

echo "${IMAGE}" > "${REPO_ROOT}/.image-ref"
log "Wrote image reference to .image-ref: ${IMAGE}"
