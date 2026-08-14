# Thin wrapper over scripts/*.sh. Real logic lives in the scripts.
# Two symmetric paths:
#   g6e-*       single-GPU L40S (g6e) LoRA sample — the entry-level path
#   p5en-efa-*  multi-node p5en (8xH200) FSDP sample over EFA — the large-scale path
SHELL := /usr/bin/env bash

.PHONY: help
.PHONY: g6e-up g6e-cluster g6e-nodepool g6e-storage g6e-image g6e-train g6e-demo g6e-inject-fault g6e-diagnose g6e-precheck g6e-clean
.PHONY: p5en-efa-up p5en-efa-cluster p5en-efa-nodepool p5en-efa-nccl-test p5en-efa-clean
.PHONY: p5en-efa-storage p5en-efa-image p5en-efa-train p5en-efa-demo p5en-efa-diagnose p5en-efa-inject-fault p5en-efa-precheck

help: ## Show available targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'

# ---- g6e path (single-GPU L40S LoRA) ----

g6e-up: ## (g6e) Stand up all infra: cluster -> nodepool -> storage -> image (stops before train)
	@$(MAKE) g6e-cluster
	@$(MAKE) g6e-nodepool
	@$(MAKE) g6e-storage
	@$(MAKE) g6e-image

g6e-cluster: ## (g6e) Provision the EKS Auto Mode cluster (~15 min)
	@scripts/g6e/cluster-up.sh

g6e-nodepool: ## (g6e) Apply the GPU NodePool and bring up a g6e node (~3 min)
	@scripts/g6e/nodepool-apply.sh

g6e-storage: ## (g6e) Provision FSx + CSI + StorageClass/PVC
	@scripts/g6e/storage-up.sh

g6e-image: ## (g6e) Build and push the training image to ECR
	@scripts/g6e/image-build.sh

g6e-train: ## (g6e) Install JobSet + launch the distributed LoRA fine-tune
	@scripts/g6e/train.sh

g6e-demo: ## (g6e) Full sequence: train -> XID inject -> hands-off repair -> resume
	@scripts/g6e/demo.sh

g6e-inject-fault: ## (g6e) Inject a GPU fault (primary: dcgmi --inject)
	@scripts/g6e/inject-fault.sh

g6e-diagnose: ## (g6e) Collect a node log bundle with no SSH (kubectl ekslogs / NodeDiagnostic)
	@scripts/g6e/diagnose.sh

g6e-precheck: ## (g6e) Validate prerequisites before running
	@scripts/g6e/precheck.sh

g6e-clean: ## (g6e) Destroy all resources
	@scripts/g6e/clean.sh

# ---- p5en/EFA path (multi-node H200 FSDP over EFA) ----

p5en-efa-up: ## (p5en/EFA) Stand up all infra: cluster -> nodepool -> storage -> image (stops before train)
	@$(MAKE) p5en-efa-cluster
	@$(MAKE) p5en-efa-nodepool
	@$(MAKE) p5en-efa-storage
	@$(MAKE) p5en-efa-image

p5en-efa-cluster: ## (p5en/EFA) Provision the temporary Auto Mode cluster (region from AWS_REGION)
	@scripts/p5en-efa/cluster-up.sh

p5en-efa-nodepool: ## (p5en/EFA) Apply p5en NodeClass/NodePool + EFA device plugin, bring up 2 nodes
	@scripts/p5en-efa/nodepool-apply.sh

p5en-efa-nccl-test: ## (p5en/EFA) Run NCCL all_reduce_perf across 2 nodes (EFA busbw proof)
	@scripts/p5en-efa/nccl-test.sh

p5en-efa-clean: ## (p5en/EFA) Full scoped teardown: storage + cluster + image-build infra
	@scripts/p5en-efa/clean.sh

p5en-efa-storage: ## (p5en/EFA) Provision FSx for Lustre + CSI + Pod Identity + PVC
	@scripts/p5en-efa/storage-up.sh

p5en-efa-image: ## (p5en/EFA) Build the DLC-based FSDP training image via CodeBuild
	@scripts/p5en-efa/image-build.sh

p5en-efa-train: ## (p5en/EFA) Launch the FSDP training JobSet
	@scripts/p5en-efa/train.sh

p5en-efa-demo: ## (p5en/EFA) Full sequence: NCCL -> FSDP -> XID inject -> hands-off repair -> resume
	@scripts/p5en-efa/demo.sh

p5en-efa-diagnose: ## (p5en/EFA) Collect a node log bundle with no SSH (kubectl ekslogs / NodeDiagnostic)
	@scripts/p5en-efa/diagnose.sh

p5en-efa-inject-fault: ## (p5en/EFA) Inject a GPU fault on the rank-0 node (primary: dcgmi --inject)
	@scripts/p5en-efa/inject-fault.sh

p5en-efa-precheck: ## (p5en/EFA) Validate prerequisites before running
	@scripts/p5en-efa/precheck.sh
