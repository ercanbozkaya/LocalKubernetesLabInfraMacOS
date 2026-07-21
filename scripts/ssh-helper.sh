#!/usr/bin/env bash
# =============================================================================
# ssh-helper.sh - Convenience script to SSH into lab VMs from the host Mac.
# Usage: ./scripts/ssh-helper.sh [controller|node01|node02]
#        ./scripts/ssh-helper.sh -s node01    (no sudo)
#        ./scripts/ssh-helper.sh -c "kubectl get nodes"   (run a command)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

source "$BASE_DIR/config.sh"

usage() {
    echo "Usage: $0 [OPTIONS] [NODE]"
    echo ""
    echo "Options:"
    echo "  -s           No sudo (login as 'ubuntu')"
    echo "  -c CMD       Execute CMD on node (requires sudo)"
    echo "  -h           Show this help"
    echo ""
    echo "Nodes: k8slab-controller, k8slab-node01, k8slab-node02"
}

NODE=""
NO_SUDO=false
COMMAND=""

while getopts "sc:h" opt; do
    case "$opt" in
        s) NO_SUDO=true ;;
        c) COMMAND="$OPTARG" ;;
        h) usage; exit 0 ;;
    esac
done
shift $((OPTIND - 1))

[[ $# -ge 1 ]] && NODE="$1"

resolve_node_name() {
    case "$NODE" in
        k8slab-controller|ctrl) echo "$CONTROLLER_NAME" ;;
        k8slab-node01|n01)      echo "$NODE01_NAME" ;;
        k8slab-node02|n02)      echo "$NODE02_NAME" ;;
        *)               echo "" ;;
    esac
}

resolve_node_name

if [[ -z "$NODE" ]]; then
    echo "Error: NODE argument is required."
    usage
    exit 1
fi

VM_NAME="$NODE"   # already resolved above

if ! multipass info "$VM_NAME" &>/dev/null; then
    log_error "VM '$VM_NAME' not found. Run 'multipass list' to see available VMs."
    exit 1
fi

if [[ -n "$COMMAND" ]]; then
    log_info "Running on $VM_NAME: $COMMAND"
    multipass exec "$VM_NAME" -- $COMMAND
else
    vm_ip=$(multipass info "$VM_NAME" --format json 2>/dev/null | jq -r ".info.\"${VM_NAME}\".ipv4[0] // \"N/A\"")
    log_info "Connecting to $VM_NAME ($vm_ip) ..."

    # Use ssh via Multipass's built-in shell (handlesPTY, keeps connection alive)
    multipass shell "$VM_NAME"
fi
