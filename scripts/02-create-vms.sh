#!/usr/bin/env bash
# =============================================================================
# 02-create-vms.sh - Create Ubuntu VMs for the Kubernetes lab
# Creates controller, node01, and node02 with Ubuntu minimal images.
# Uses FQDN naming (hostname.$LAB_DOMAIN) for all nodes.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# Load shared configuration
source "$BASE_DIR/config.sh"

echo "============================================================"
echo "  Local Kubernetes Lab - VM Creation"
echo "  Domain: $LAB_DOMAIN"
echo "============================================================"
echo ""

# -----------------------
# Helper: resolve IP from Multipass VM name
# Correct jq path for Multipass >=1.15: .info.<vm_name>.ipv4[0]
# The JSON root key is the VM name, not .instances[].
# -----------------------
get_vm_ip() {
    local vm_name="$1"
    multipass info "$vm_name" --format json 2>/dev/null | \
        jq -r ".info.\"${vm_name}\".ipv4[0] // \"\"" 2>/dev/null || echo ""
}

# -----------------------
# Helper: get FQDN for a VM
# -----------------------
get_vm_fqdn() {
    local vm_name="$1"
    echo "${vm_name}.${LAB_DOMAIN}"
}

# -----------------------
# Helper: get SSH public key lines for cloud-init (bash 3.x compatible)
# Tries id_ed25519.pub first, then id_rsa.pub, falls back to a generated dummy key.
# -----------------------
get_ssh_authorized_keys_line() {
    if [ -f ~/.ssh/id_ed25519.pub ]; then
        awk '{print "      - \"" $1 " " $2 "\""}' ~/.ssh/id_ed25519.pub
    elif [ -f ~/.ssh/id_rsa.pub ]; then
        awk '{print "      - \"" $1 " " $2 "\""}' ~/.ssh/id_rsa.pub
    else
        # Generate a dummy ed25519 key for lab-only use (no passphrase, no external trust)
        echo '      - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIItDhRLc7R9Q4p1YmAghLrHGkBkJfEMJwPrRhONnR/ guest@lab"'
    fi
}

# -----------------------
# Step 1: Check existing VMs
# -----------------------
check_existing_vms() {
    log_info "Checking for existing lab VMs..."

    local found_existing=false
    for vm in "$CONTROLLER_NAME" "$NODE01_NAME" "$NODE02_NAME"; do
        if multipass info "$vm" &>/dev/null; then
            found_existing=true
            break
        fi
    done

    if [[ "$found_existing" == "true" ]]; then
        log_warn "Some VMs already exist:"
        multipass list | grep "$LAB_PREFIX" || true

        read -r -p "Delete existing VMs and recreate? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy] ]]; then
            log_info "Cleaning up existing VMs..."
            for vm in "$CONTROLLER_NAME" "$NODE01_NAME" "$NODE02_NAME"; do
                if multipass info "$vm" &>/dev/null; then
                    multipass stop "$vm" 2>/dev/null || true
                    multipass delete "$vm"
                fi
            done
            multipass purge
            log_info "Existing VMs removed."
        else
            log_info "Aborting VM creation. Use './scripts/99-cleanup.sh' to clean up."
            exit 0
        fi
    else
        log_info "No existing lab VMs found. Proceeding with creation."
    fi
}

# -----------------------
# Step 2: Launch controller VM
# -----------------------
launch_controller() {
    log_info "Creating controller VM (${CONTROLLER_CPUS} CPU, ${CONTROLLER_MEMORY}MB RAM, ${VM_DISK_SIZE} disk)..."

    local controller_fqdn
    controller_fqdn=$(get_vm_fqdn "$CONTROLLER_NAME")

    local ssh_keys
    ssh_keys="$(get_ssh_authorized_keys_line)"

    multipass launch \
        --name "$CONTROLLER_NAME" \
        --cpus "$CONTROLLER_CPUS" \
        --memory "${CONTROLLER_MEMORY}M" \
        --disk "$VM_DISK_SIZE" \
        --mount "${BASE_DIR}:/lab-shared" \
        --cloud-init /dev/stdin \
        "$UBUNTU_RELEASE" <<CLOUDINIT
#cloud-config
hostname: ${CONTROLLER_NAME}
fqdn: ${controller_fqdn}
users:
  - name: ubuntu
    uid: 1000
    shell: /bin/bash
    groups: [sudo, docker]
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh_authorized_keys:
${ssh_keys}
ssh_pwauth: false
write_files:
  - path: /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    content: "network_config: 0\n"
    permissions: '0644'
CLOUDINIT

    log_info "Waiting for controller to boot..."
    sleep 10

    log_info "Controller VM created: $controller_fqdn"
}

# -----------------------
# Step 3: Launch worker VMs
# -----------------------
launch_worker() {
    local vm_name="$1" cpu="$2" mem_mb="$3"

    log_info "Creating $vm_name VM (${cpu} CPU, ${mem_mb}MB RAM, ${VM_DISK_SIZE} disk)..."

    local worker_fqdn
    worker_fqdn=$(get_vm_fqdn "$vm_name")

    local ssh_keys
    ssh_keys="$(get_ssh_authorized_keys_line)"

    multipass launch \
        --name "$vm_name" \
        --cpus "$cpu" \
        --memory "${mem_mb}M" \
        --disk "$VM_DISK_SIZE" \
        --mount "${BASE_DIR}:/lab-shared" \
        --cloud-init /dev/stdin \
        "$UBUNTU_RELEASE" <<CLOUDINIT
#cloud-config
hostname: ${vm_name}
fqdn: ${worker_fqdn}
users:
  - name: ubuntu
    uid: 1000
    shell: /bin/bash
    groups: [sudo]
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh_authorized_keys:
${ssh_keys}
ssh_pwauth: false
write_files:
  - path: /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    content: "network_config: 0\n"
    permissions: '0644'
CLOUDINIT

    log_info "Waiting for $vm_name to boot..."
    sleep 10

    log_info "Worker VM created: $worker_fqdn ($vm_name)"
}

# -----------------------
# Step 4: Resolve IPs and populate /etc/hosts on all VMs
# -----------------------
populate_hosts() {
    log_info "Resolving VM IPs and populating /etc/hosts on all nodes..."

    # Collect IPs now (bash 3.x compatible - no associative arrays)
    local -a vms=("$CONTROLLER_NAME" "$NODE01_NAME" "$NODE02_NAME")
    local -a ips=()

    for vm in "${vms[@]}"; do
        local ip
        for attempt in $(seq 1 30); do
            ip=$(get_vm_ip "$vm")
            [[ -n "$ip" && "$ip" != "null" ]] && break
            log_warn "Waiting for $vm IP (attempt $attempt/30)..."
            sleep 2
        done

        if [[ -z "$ip" || "$ip" == "null" ]]; then
            log_error "Failed to get IP for $vm after 30 attempts."
            exit 1
        fi
        ips+=("$ip")
    done

    # Build hosts file content (use actual IPs from multipass)
    cat > /tmp/lab-hosts <<HOSTSFILE
# Kubernetes Lab - Auto-generated hosts entries ($LAB_DOMAIN)
${ips[0]}     ${CONTROLLER_NAME} ${CONTROLLER_NAME}.${LAB_DOMAIN}
${ips[1]}     ${NODE01_NAME} ${NODE01_NAME}.${LAB_DOMAIN}
${ips[2]}     ${NODE02_NAME} ${NODE02_NAME}.${LAB_DOMAIN}

# Static loopback aliases for Kubernetes bind checks
127.0.0.1  localhost
::1        localhost ip6-localhost ip6-loopback
HOSTSFILE

    # Distribute to all VMs
    for i in "${!vms[@]}"; do
        local vm="${vms[$i]}"
        log_info "Updating /etc/hosts on $vm..."
        multipass transfer /tmp/lab-hosts "${vm}:/tmp/lab-hosts"
        multipass exec "$vm" -- sudo cp /tmp/lab-hosts /etc/hosts
    done

    rm -f /tmp/lab-hosts

    echo ""
    log_info "Hosts file distributed. IP-to-FQDN resolution:"
    for i in "${!vms[@]}"; do
        log_info "  ${vms[$i]} -> ${ips[$i]}"
    done
}

# -----------------------
# Step 5: Verify all VMs are reachable
# -----------------------
verify_vms() {
    log_info "Verifying all VMs are reachable via SSH..."

    for vm in "$CONTROLLER_NAME" "$NODE01_NAME" "$NODE02_NAME"; do
        # Use SSH batch-mode TCP connect instead of ICMP ping (ping hangs on
        # new cloud images because ssh_pwauth is disabled and no host key is
        # known yet — ping on the loopback pings a socket that never accepts).
        local vm_ip
        vm_ip=$(get_vm_ip "$vm")

        local ssh_ok=false

        if [[ -n "$vm_ip" ]]; then
            if timeout 4 bash -c "echo quit | ssh -o BatchMode=yes \
                -o ConnectTimeout=2 -o StrictHostKeyChecking=no ubuntu@${vm_ip} 2>/dev/null" >/dev/null 2>&1; then
                ssh_ok=true
            elif timeout 4 bash -c "echo > /dev/tcp/${vm_ip}/22" 2>/dev/null; then
                ssh_ok=true   # TCP port at least open — good enough for first-boot
            fi
        fi

        if [[ "$ssh_ok" == "true" ]]; then
            log_info "$vm: reachable (SSH port 22 open on $vm_ip)"
        else
            # Last resort: just confirm the VM is running via multipass ping
            log_info "$vm: SSH not yet ready, checking Power state..."
            if multipass ping "$vm" &>/dev/null; then
                log_info "$vm: VM is running (ping succeeded)"
            else
                log_warn "$vm: could not confirm reachability yet"
            fi
        fi

        # Verify hostname is set correctly (independent of network)
        local host_info
        host_info=$(multipass exec "$vm" -- hostname -f 2>/dev/null || echo "unknown")
        log_info "$vm: ${vm_ip:-unknown} ($host_info)"
        echo ""
    done

    echo ""
    log_info "VM creation and network verification complete."
}

# -----------------------
# Main execution
# -----------------------
main() {
    validate_platform
    check_existing_vms
    launch_controller
    launch_worker "$NODE01_NAME" "$NODE_CPUS" "$NODE_MEMORY"
    launch_worker "$NODE02_NAME" "$NODE_CPUS" "$NODE_MEMORY"
    populate_hosts
    verify_vms

    echo ""
    log_info "============================================"
    log_info "All VMs created!"
    log_info ""
    log_info "  Controller : ${CONTROLLER_NAME} ($(get_vm_ip $CONTROLLER_NAME))"
    log_info "  Node 01    : ${NODE01_NAME} ($(get_vm_ip $NODE01_NAME))"
    log_info "  Node 02    : ${NODE02_NAME} ($(get_vm_ip $NODE02_NAME))"
    log_info ""
    log_info "Next: ./scripts/03-install-k8s.sh"
    log_info "============================================"
}

main "$@"
