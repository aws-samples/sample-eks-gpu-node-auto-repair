#!/usr/bin/env bash
# The MNG p5en-efa path reuses the p5en-efa DLC training image. This target ensures the image
# exists by delegating to the p5en-efa image build; it never provisions a separate ECR/CodeBuild
# stack and shares the resulting .image-ref-p5en-efa.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
log "mng-p5en-efa reuses the p5en-efa DLC training image; delegating to scripts/p5en-efa/image-build.sh"
exec "${REPO_ROOT}/scripts/p5en-efa/image-build.sh"
