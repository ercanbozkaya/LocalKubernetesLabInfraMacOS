#!/usr/bin/env bash
# =============================================================================
# 99-cleanup.sh - Full teardown of the Kubernetes lab VMs and artifacts
# Usage: ./scripts/99-cleanup.sh [--yes] [--keep-artifacts]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

source "$BASE_DIR/config.sh"

KEEP_ARTIFACTS=false
AUTO_CONFIRM=false

# Parse flags
for arg in "$@"; do
    case "$arg" in
        --yes|-y) AUTO_CONFIRM=true ;;
        --keep-artifacts|--ka) KEEP_ARTIFACTS=true ;;
    esac
done

echo "============================================================"
echo "  Local Kubernetes Lab - Cleanup / Tear Down"
echo "============================================================"
echo ""

# -----------------------
# Step 1: stop & delete VMs
# -----------------------
cleanup_vms() {
    log_info "Stopping and deleting lab VMs..."

    for vm in "$CONTROLLER_NAME" "$NODE01_NAME" "$NODE02_NAME"; do
        if multipass info "$vm" &>/dev/null; then
            log_info "Stopping $vm..."
            multipass stop "$vm" 2>/dev/null || true

            log_info "Deleting $vm..."
            multipass delete "$vm"
        else
            log_info "$vm: not found — skipping."
        fi
    done

    multipass purge
    log_info "VMs purged."
}

# -----------------------
# Step 2: remove local artifacts (optional)
# -----------------------
cleanup_artifacts() {
    if [[ "$KEEP_ARTIFACTS" == "true" ]]; then
        log_info "Keeping artifacts/ directory (--keep-artifacts given)."
        return 0
    fi

    if [[ -d "$BASE_DIR/artifacts" ]]; then
        log_info "Removing artifacts/ directory..."
        rm -rf "$BASE_DIR/artifacts"
    fi

    log_info "Cleanup complete."
}

# -----------------------
# Main
# -----------------------
main() {
    validate_platform

    echo "This will DESTROY the entire lab (all 3 VMs + artifacts)."
    read -r -p "Continue? (type 'yes' to confirm): " answer
    if [[ "$answer" != "yes" && "$AUTO_CONFIRM" != "true" ]]; then
        log_info "Aborted."
        exit 0
    fi

    cleanup_vms
    cleanup_artifacts

    echo ""
    log_info "Lab teardown complete. Multipass is still installed."
}

main "$@"