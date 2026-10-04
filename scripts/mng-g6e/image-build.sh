#!/usr/bin/env bash
# The MNG g6e path reuses the g6e training image. This target ensures the image exists by
# delegating to the g6e image build; it never provisions a separate ECR/CodeBuild stack.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require bash
log "mng-g6e reuses the g6e training image; delegating to scripts/g6e/image-build.sh"
exec "${REPO_ROOT}/scripts/g6e/image-build.sh"
