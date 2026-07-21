#!/usr/bin/env bash
# =============================================================================
# Local Kubernetes Lab - Configuration
# For Apple Silicon MacBooks (M1/M2/M3/M4)
# =============================================================================

# -----------------------------------------------------------------------------
# Load user overrides FIRST. Everything below is declared `readonly`, and Bash
# cannot re-assign a readonly variable — sourcing .env after the readonly
# declarations either silently no-ops the override or aborts the script with
# "readonly variable" (fatal, since every caller runs with `set -euo pipefail`).
# Defaults are set here as plain (non-readonly) vars using ${VAR:=default} so
# a value already present in .env / the environment wins, then everything is
# locked down with `readonly` afterwards so the rest of the codebase can still
# rely on these being immutable for the remainder of the run.
# -----------------------------------------------------------------------------
if [[ -f ".env" ]]; then
    set -a
    source .env
    set +a
fi

# VM Configuration
: "${LAB_PREFIX:=k8slab}"
: "${CONTROLLER_NAME:=${LAB_PREFIX}-controller}"
: "${NODE01_NAME:=${LAB_PREFIX}-node01}"
: "${NODE02_NAME:=${LAB_PREFIX}-node02}"

# Ubuntu standard image (ARM64 - Apple Silicon compatible)
: "${UBUNTU_RELEASE:=24.04}"

# VM Resource Allocation (Apple Silicon optimized)
: "${CONTROLLER_CPUS:=2}"
: "${CONTROLLER_MEMORY:=4096}"     # 4GB RAM for control plane
: "${NODE_CPUS:=2}"
: "${NODE_MEMORY:=4096}"           # 4GB RAM per worker

# Disk space
: "${VM_DISK_SIZE:=25G}"           # 25GB per VM

# Network Configuration - Using Multipass internal networking
: "${LAB_DOMAIN:=k8slab.local}"
: "${CIDR_NOTATION:=10.5.0.0/24}"

# Pod network CIDR - must match what kubeadm init uses (--pod-network-cidr) AND
# what Cilium is told (ipv4NativeRoutingCIDR), or Cilium agents will crash-loop.
: "${POD_NETWORK_CIDR:=10.244.0.0/16}"

# Kubernetes Versions
: "${K8S_VERSION_NODE01:=1.35}"
: "${K8S_VERSION_NODE02:=1.34}"

# Container Runtime
: "${CONTAINER_RUNTIME:=containerd}"

# Cilium Installation (unset = latest stable auto-detected by Helm)
: "${CILIUM_CHART_VERSION:=}"

# Kubernetes Package Mirror (for faster downloads in restricted networks)
: "${KUBE_mIRROR:=https://pkgs.k8s.io}"

# IPAM Mode for Cilium (Kubernetes native mode)
: "${CILIUM_IPAM_MODE:=kubernetes}"
: "${CILIUM_MODE:=native}"

# Logging
: "${LOG_LEVEL:=info}"

# Now lock everything down — no further reassignment allowed for the rest of
# the run, regardless of where a script sources config.sh from.
readonly LAB_PREFIX CONTROLLER_NAME NODE01_NAME NODE02_NAME
readonly UBUNTU_RELEASE
readonly CONTROLLER_CPUS CONTROLLER_MEMORY NODE_CPUS NODE_MEMORY VM_DISK_SIZE
readonly LAB_DOMAIN CIDR_NOTATION POD_NETWORK_CIDR
readonly K8S_VERSION_NODE01 K8S_VERSION_NODE02
readonly CONTAINER_RUNTIME CILIUM_CHART_VERSION
readonly KUBE_mIRROR
readonly CILIUM_IPAM_MODE CILIUM_MODE
readonly LOG_LEVEL

# Validate we're on macOS with Apple Silicon
validate_platform() {
    if [[ "$(uname)" != "Darwin" ]]; then
        echo "ERROR: This script requires macOS."
        exit 1
    fi

    local arch
    arch=$(uname -m)
    if [[ "$arch" != "arm64" ]]; then
        echo "WARNING: Running on non-Apple Silicon hardware ($arch). Some features may not work optimally."
    fi
}

# Log helper with timestamp and level
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
}

log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

export -n LAB_PREFIX CONTROLLER_NAME NODE01_NAME NODE02_NAME
export -n UBUNTU_RELEASE
export -n CONTROLLER_CPUS CONTROLLER_MEMORY NODE_CPUS NODE_MEMORY VM_DISK_SIZE
export -n LAB_DOMAIN CIDR_NOTATION POD_NETWORK_CIDR
export -n K8S_VERSION_NODE01 K8S_VERSION_NODE02
export -n CONTAINER_RUNTIME CILIUM_CHART_VERSION
export -n CILIUM_IPAM_MODE CILIUM_MODE
export -n LOG_LEVEL
export validate_platform log log_info log_warn log_error
