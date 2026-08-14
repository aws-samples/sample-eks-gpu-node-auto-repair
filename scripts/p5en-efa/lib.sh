#!/usr/bin/env bash
# Shared helpers for the p5en/EFA overlay scripts.
# Provides logging, tool checks, an AWS context check, and the overridable environment context.
set -euo pipefail

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

require() {
  local missing=0 c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { warn "missing required tool: $c"; missing=1; }
  done
  [ "$missing" -eq 0 ] || die "install missing tools and retry"
}

# Environment context. Override any of these via the matching environment variable.
export EFA_AWS_PROFILE="${AWS_PROFILE:-default}"
export EFA_AWS_REGION="${AWS_REGION:-us-east-1}"
export EFA_PREFIX="eks-gpu-efa"
export EFA_CLUSTER_NAME="${EFA_CLUSTER_NAME:-eks-gpu-efa}"
# Capacity reservation + placement details. p5en.48xlarge is capacity-constrained, so this
# sample provisions from a reservation. Supply your own before running:
#   export CR_ID=<your-capacity-reservation-id>        # ODCR or Capacity Block id
#   export EFA_AZ=<az-of-your-reservation>             # e.g. us-east-1a
#   export CR_OWNER=<account-id>                        # only for cross-account reservations
export EFA_AZ="${EFA_AZ:-}"
export EFA_CR_ID="${CR_ID:-}"
export EFA_CR_OWNER="${CR_OWNER:-}"
export EFA_RESERVATION_TYPE="${RESERVATION_TYPE:-odcr}"
# NAT gateway needs 1 Elastic IP. Default true (general egress + third-party registries like
# nvcr.io/docker.io). VPC endpoints (AWS-service traffic on the backbone) are independent and
# also default true for the enterprise best-practice combo. Set ENABLE_NAT=false for an
# EIP-free cluster (then only AWS registries are reachable).
export EFA_ENABLE_NAT="${ENABLE_NAT:-true}"
export EFA_ENABLE_VPCE="${ENABLE_VPCE:-true}"

# Guard: confirm the caller has working AWS credentials and echo the target account so an
# operator can catch a wrong-profile mistake before this overlay creates resources. Set
# EXPECTED_ACCOUNT=<account-id> to hard-fail unless the caller is in that account.
check_aws_context() {
  local acct
  acct="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
  [ -n "${acct}" ] || die "no AWS credentials (configure your profile/region and retry)"
  if [ -n "${EXPECTED_ACCOUNT:-}" ] && [ "${acct}" != "${EXPECTED_ACCOUNT}" ]; then
    die "expected account ${EXPECTED_ACCOUNT}, got '${acct}' (check AWS_PROFILE)"
  fi
  log "Operating in account ${acct}, region ${EFA_AWS_REGION}"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# Fail fast with actionable guidance if the reservation context isn't supplied.
require_az() {
  [ -n "${EFA_AZ}" ] || die "EFA_AZ is not set — export EFA_AZ=<az-of-your-reservation> (e.g. us-east-1a)"
}
require_reservation() {
  require_az
  [ -n "${EFA_CR_ID}" ] || die "CR_ID is not set — export CR_ID=<your-capacity-reservation-id> (p5en.48xlarge is capacity-constrained; this sample provisions from a reservation)"
}
