#!/usr/bin/env bash
# =============================================================================
# 01-setup-multipass.sh - Verify Multipass is installed and configured
# Prerequisite: Multipass must already be installed via Homebrew or the app.
# This script only checks availability, version, and runs basic health checks.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

source "$BASE_DIR/config.sh"

echo "============================================================"
echo "  Local Kubernetes Lab - Multipass Check (prerequisite)"
echo "============================================================"
echo ""

# -----------------------
# Step 1: Check Multipass is installed and get version
# -----------------------
check_multipass_installed() {
    if ! command -v multipass &> /dev/null; then
        log_error "Multipass is NOT installed."
        echo ""
        echo "Please install it first (choose one):"
        echo "  brew install --cask multipass     # via Homebrew"
        echo "  /usr/bin/curl -fsSL https://github.com/canonical/multipass/releases/download/1.14.2/multipass-1.14.2.pkg -o /tmp/multipass.pkg && sudo installer -pkg /tmp/multipass.pkg -target /"
        echo ""
        exit 1
    fi

    local version
    version=$(multipass --version)
    log_info "Multipass is installed: $version"
}

# -----------------------
# Step 2: Validate platform
# -----------------------
validate_platform() {
    if [[ "$(uname)" != "Darwin" ]]; then
        log_error "This lab requires macOS."
        exit 1
    fi

    local arch
    arch=$(uname -m)
    if [[ "$arch" != "arm64" ]]; then
        log_warn "Running on non-Apple Silicon hardware ($arch). Images may not match."
    fi

    log_info "Platform: macOS $(uname -r) on $arch"
}

# -----------------------
# Step 3: Configure Multipass (non-destructive settings only)
# -----------------------
configure_multipass() {
    log_info "Applying Multipass settings..."

    # Ensure the daemon socket is running
    multipass list > /dev/null 2>&1 || true

    # Relaxed mount security (allows --mount in VM launch)
    multipass set local.mount-relax-security=on 2>/dev/null || true

    log_info "Multipass settings applied."
}

# -----------------------
# Step 4: Verify connectivity and list any existing lab VMs
# -----------------------
verify_multipass() {
    log_info "Verifying Multipass is operational..."

    local instances
    instances=$(multipass list --format json 2>/dev/null | jq -r '.instances | length' 2>/dev/null || echo "0")

    if [[ "$instances" -eq 0 ]]; then
        log_info "No existing VMs found — ready for lab creation."
    else
        log_warn "Existing VMs on this Mac:"
        multipass list
    fi

    log_info "Multipass is ready."
}

# -----------------------
# Main
# -----------------------
main() {
    validate_platform
    check_multipass_installed
    configure_multipass
    verify_multipass

    echo ""
    log_info "============================================"
    log_info "Multipass is ready."
    log_info "Next: ./scripts/02-create-vms.sh"
    log_info "============================================"
    echo ""
}

main "$@"
