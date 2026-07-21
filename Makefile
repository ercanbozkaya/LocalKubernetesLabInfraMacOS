# =============================================================================
# Makefile - Local Kubernetes Lab on Apple Silicon MacBooks
#
# Prerequisites: macOS, Homebrew, Multipass installed.
# Usage: make [target]
# =============================================================================

SHELL := /bin/bash
.PHONY: all setup vms k8s cilium verify status destroy ssh-controller ssh-node01 ssh-node02 help

# ---------- helpers ----------------------------------------------------------

## ANSI color codes — these are expanded at runtime via shell, NOT by Make
CYAN   := \033[96m
RESET  := \033[0m

help: ## Show this help text
	@echo "============================================"
	@echo "  Local Kubernetes Lab - Makefile Targets"
	@echo "============================================"
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'
	@echo ""

setup: ## Install & configure Multipass (step 1)
	@printf "$(CYAN)>>> Step 1/6: Multipass Setup$(RESET)\n"
	@./scripts/01-setup-multipass.sh

vms: ## Create 3 Ubuntu VMs (step 2)
	@printf "$(CYAN)>>> Step 2/6: VM Creation$(RESET)\n"
	@./scripts/02-create-vms.sh

k8s: ## Install kubeadm 1.35 on controller+node01, 1.34 on node02 (step 3)
	@printf "$(CYAN)>>> Step 3/6: kubeadm Installation$(RESET)\n"
	@./scripts/03-install-k8s.sh

cilium: ## Install Cilium CNI with Hubble (step 4)
	@printf "$(CYAN)>>> Step 4/6: Cilium CNI$(RESET)\n"
	@./scripts/04-install-cilium.sh

verify: ## Run all health checks (step 5)
	@printf "$(CYAN)>>> Step 5/6: Verification$(RESET)\n"
	@./scripts/05-verify-cluster.sh

status: ## Quick cluster status summary (no setup)
	@./scripts/05-verify-cluster.sh

destroy: ## Tear down the entire lab (--yes to skip confirmation)
	@printf "$(CYAN)>>> Lab Teardown$(RESET)\n"
	@./scripts/99-cleanup.sh --yes

# ---------- convenience targets ----------------------------------------------

all: setup vms k8s cilium verify ## Full end-to-end lab build (recommended)

ssh-controller: ## SSH into controller VM (alias for ssh-helper.sh)
	@./scripts/ssh-helper.sh k8slab-controller

ssh-node01: ## SSH into node01 VM (alias for ssh-helper.sh)
	@./scripts/ssh-helper.sh k8slab-node01

ssh-node02: ## SSH into node02 VM (alias for ssh-helper.sh)
	@./scripts/ssh-helper.sh k8slab-node02

ssh-%: ## SSH into any lab VM — e.g. make ssh-controller
	@./scripts/ssh-helper.sh $*

# internal alias — kept for backwards compatibility
status-check: status;
