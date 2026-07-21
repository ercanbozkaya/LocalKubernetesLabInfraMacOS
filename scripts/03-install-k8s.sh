#!/usr/bin/env bash
# =============================================================================
# 03-install-k8s.sh - Install Kubernetes components via kubeadm
# Controller & Node01: kubectl, kubelet, kubeadm v${K8S_VERSION_NODE01}
# Node02:              kubectl, kubelet, kubeadm v${K8S_VERSION_NODE02}
# Uses FQDN (hostname.$LAB_DOMAIN) for all join commands.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# Load shared configuration
source "$BASE_DIR/config.sh"

echo "============================================================"
echo "  Local Kubernetes Lab - kubeadm Installation"
echo "  Controller/Node01: k8s v${K8S_VERSION_NODE01}"
echo "  Node02:          k8s v${K8S_VERSION_NODE02}"
echo "============================================================"
echo ""

# -----------------------
# Helper: determine k8s version for a node
# -----------------------
get_k8s_version_for_node() {
    local node="$1"
    case "$node" in
        "$NODE02_NAME") echo "$K8S_VERSION_NODE02" ;;
        *)            echo "$K8S_VERSION_NODE01" ;;
    esac
}

# -----------------------
# Helper: format version string for apt repo (e.g. "1.35")
# -----------------------
k8s_version_abbrev() {
    local ver="$1"
    # Return major.minor (e.g. "1.35"); if a patch version is present ("1.35.0"), strip it
    echo "$ver" | awk -F. '{if (NF>=3) printf "%s.%s", $1, $2; else print $0}'
}

# -----------------------
# Step 0: Verify FQDN resolution works from all nodes
# -----------------------
verify_fqdn_resolution() {
    log_info "Verifying FQDN resolution on all nodes..."

    for vm in "$CONTROLLER_NAME" "$NODE01_NAME" "$NODE02_NAME"; do
        log_info "Checking $vm hostname resolution..."
        multipass exec "$vm" -- sh -c "hostname && hostname -f || true"
        multipass exec "$vm" -- sh -c "cat /etc/hosts | grep -v '^#' | grep -v '^$' || true"
        echo ""
    done
}

# -----------------------
# Step 1: Install prerequisites on all nodes (kernel + sysctl)
# -----------------------
install_prerequisites_on_node() {
    local vm="$1"

    log_info "Installing prerequisites on $vm..."

    multipass exec "$vm" -- sudo bash <<'BEOF'
set -e
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsof \
    iproute2 \
    conntrack \
    socat \
    dnsutils \
    openssh-client \
    rsync

# Enable required kernel modules for Kubernetes (quoted heredoc delimiter prevents host expansion)
modprobe -- configs 2>/dev/null || true
cat > /etc/modules-load.d/k8s.conf <<'MKMODS'
overlay
br_netfilter
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
MKMODS

# Set sysctls for Kubernetes networking (bridge-nf-call-iptables required by kubeadm)
cat > /etc/sysctl.d/99-kubernetes-cri.conf <<'SYSCTL'
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv6.conf.all.disable_ipv6    = 0
net.netfilter.nf_conntrack_max    = 1000000
SYSCTL

sysctl --system

echo "Kernel prerequisites: DONE"
BEOF
}

# -----------------------
# Step 2: Install containerd on all nodes
# -----------------------
install_containerd_on_node() {
    local vm="$1"

    log_info "Installing containerd on $vm..."

    multipass exec "$vm" -- sudo bash <<'BEOF'
set -e

# Install containerd from official Ubuntu repos (bundled with kernel modules)
DEBIAN_FRONTEND=noninteractive apt-get install -y containerd

# Generate default config and ensure systemd CRI is enabled
if [ ! -f /etc/containerd/config.toml ]; then
    mkdir -p /etc/containerd
    containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' > /etc/containerd/config.toml
fi

# Enable and start containerd (systemd runtime)
systemctl enable --now containerd 2>/dev/null || {
    systemctl enable containerd
    systemctl start containerd
}

# Disable swap (kubeadm requires no swap)
swapoff -a 2>/dev/null || true
sed -i '/\\bswap\\b/d' /etc/fstab 2>/dev/null || true

echo "Containerd: DONE"
BEOF
}

# -----------------------
# Step 3: Install kubeadm/kubelet/kubectl on a node (version-specific)
# -----------------------
install_k8s_packages_on_node() {
    local vm="$1"
    local ver_abbrev="$2"  # abbreviated e.g. "1.35"

    log_info "Installing K8s v${ver_abbrev} packages on $vm (repo abbreviation: ${ver_abbrev})..."

    # Determine the exact installable version string from the K8s apt repo.
    local kube_ver="${ver_abbrev}."

    multipass exec "$vm" -- sudo bash <<BEOF
set -euo pipefail

mkdir -p /etc/apt/keyrings
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${ver_abbrev}/deb/Release.key" | \
    gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# sanity check: fail loudly instead of silently apt-updating with a bad key
if [ ! -s /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
    echo "ERROR: kubernetes-apt-keyring.gpg is empty — key download failed" >&2
    exit 1
fi

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${ver_abbrev}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    "kubelet=${kube_ver}*" \
    "kubectl=${kube_ver}*" \
    "kubeadm=${kube_ver}*"

# Pin packages so 'apt upgrade' won't bump them off this minor version.
# (Previously this also wrote a second, freeform "kubernetes-pin" file that
# wasn't valid APT preferences syntax and had no effect — removed.)
cat > /etc/apt/preferences.d/kubernetes.pin <<PIN
Package: kubelet kubeadm kubectl
Pin: version ${kube_ver}*
Pin-Priority: 1001
PIN

apt-mark hold kubelet kubeadm kubectl

kubelet --version || true
echo "K8s v${ver_abbrev} packages: DONE"
BEOF
}

# -----------------------
# Step 4: Initialize the cluster on controller (as FQDN, Cilium CIDR)
# -----------------------
kubeadm_init() {
    log_info "Initializing Kubernetes cluster on controller..."

    # Build ip-forwarding flag for Cilium's internal pod CIDR
    local cidr_mask="${CIDR_NOTATION##*/}"   # "24" from "10.5.0.0/24"

    log_info "Running kubeadm init with pod-cidr /${cidr_mask}..."

multipass exec "$CONTROLLER_NAME" -- sudo bash <<BEOF
set -e

# Config: API server advertises the controller's FQDN (not its IP)
kubeadm init \
    --pod-network-cidr=${POD_NETWORK_CIDR} \
    --apiserver-advertise-address=\$(hostname -i) \
    --apiserver-cert-extra-sans="${CONTROLLER_NAME},${CONTROLLER_NAME}.${LAB_DOMAIN}" \
    --node-name "${CONTROLLER_NAME}.${LAB_DOMAIN}"

# Copy kubeconfig for the ubuntu user
mkdir -p /home/ubuntu/.kube
cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown -R 1000:1000 /home/ubuntu/.kube

echo "Cluster init: DONE"
BEOF

    echo ""

    # Verify control-plane is up before extracting the join command
    log_info "Waiting for API server to become ready..."
    wait_kube_api_ready "$CONTROLLER_NAME" 60

    # Extract join commands (both discovery-token and bootstrap-token methods)
    extract_and_distribute_join_commands
}

# -----------------------
# Helper: wait_for_api_server_ready
# -----------------------
wait_kube_api_ready() {
    local vm="$1"
    local timeout_sec="${2:-90}"

    for i in $(seq 1 "$timeout_sec"); do
        if multipass exec "$vm" -- sudo curl -sk --max-time 2 https://127.0.0.1:6443/livez 2>/dev/null | grep -q "ok"; then
            log_info "API server ready on $vm after ${i}s."
            return 0
        fi
        sleep 1
    done

    log_error "Timeout waiting for API server on $vm."
    return 1
}

# -----------------------
# Helper: extract join commands from controller and save to host
# -----------------------
extract_and_distribute_join_commands() {
    log_info "Extracting join commands from controller..."

    local join_cmd
    join_cmd=$(multipass exec "$CONTROLLER_NAME" -- sudo kubeadm token create --print-join-command 2>/dev/null)

    # Get controller's IP address (as a plain variable, not nested in a substitution)
    # so we can swap it for the FQDN below.
    local controller_ip
    controller_ip=$(multipass info "$CONTROLLER_NAME" --format json 2>/dev/null | jq -r ".info.\"${CONTROLLER_NAME}\".ipv4[0] // empty")

    local fqdn_join="$join_cmd"
    if [[ -n "$controller_ip" ]]; then
        fqdn_join="${join_cmd//$controller_ip/${CONTROLLER_NAME}.${LAB_DOMAIN}}"
    else
        log_warn "Could not determine controller IP via 'multipass info'; join command will use whatever address kubeadm printed."
    fi

    # Both worker nodes join the same single controller, so they use the same command.
    mkdir -p "$BASE_DIR/artifacts"
    cat > "$BASE_DIR/artifacts/join-commands.sh" <<JOINFILE
#!/usr/bin/env bash
# Auto-generated join commands (FQDN-based) — last generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Regenerate on controller with: kubeadm token create --print-join-command

node01_join="${fqdn_join}"
node02_join="${fqdn_join}"
JOINFILE

    # This file carries a live cluster bootstrap token — restrict it to the
    # owner. (chmod +x kept: the file is also meant to be sourced/executed.)
    chmod 700 "$BASE_DIR/artifacts/join-commands.sh"
    log_info "Join commands saved to artifacts/join-commands.sh (FQDN-based, chmod 700)."
}

# -----------------------
# Step 5: Join worker nodes (controller added first, then workers)
# -----------------------
join_node() {
    local vm="$1" ver="$2"

    log_info "Joining $vm (k8s v${ver}) to cluster using FQDN..."

    # Source the join command file
    source "$BASE_DIR/artifacts/join-commands.sh"

    local target_node="node01"
    [[ "$vm" == "$NODE02_NAME" ]] && target_node="node02"

    local join_cmd
    eval "join_cmd=\${${target_node}_join}"

    log_info "Executing: $join_cmd"

    # NOTE: previously this used `sudo bash -c "$join_cmd || {...}"`. multipass exec does
    # not reliably preserve shell quoting for multi-word -c arguments — it was silently
    # word-splitting the command remotely, which ran bare `kubeadm` (printing its help
    # banner) instead of `kubeadm join ...`. That returned exit 0, so the script logged
    # "joined successfully" even though the node never actually joined. Heredocs go over
    # stdin and aren't subject to this. We also now check the real exit status.
    if multipass exec "$vm" -- sudo bash <<EOF
set -e
$join_cmd
EOF
    then
        log_info "$vm joined successfully."
    else
        log_warn "$vm join failed, retrying in 5s..."
        sleep 5
        multipass exec "$vm" -- sudo bash <<EOF
set -e
$join_cmd
EOF
        log_info "$vm joined successfully (after retry)."
    fi
}

# -----------------------
# Step 6: Verify cluster membership on controller
# -----------------------
verify_cluster_members() {
    log_info "Verifying cluster membership (controller)..."

    multipass exec "$CONTROLLER_NAME" -- sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide
}

# -----------------------
# Main execution
# -----------------------
main() {
    validate_platform

    verify_fqdn_resolution

    # Run prerequisite steps on ALL nodes in parallel-ish order
    for vm in "$CONTROLLER_NAME" "$NODE01_NAME" "$NODE02_NAME"; do
        install_prerequisites_on_node "$vm"
    done

    for vm in "$CONTROLLER_NAME" "$NODE01_NAME" "$NODE02_NAME"; do
        install_containerd_on_node "$vm"
    done

    # Install packages — controller & node01 get ${K8S_VERSION_NODE01},
    #                                 node02 gets  ${K8S_VERSION_NODE02}
    for vm in "$CONTROLLER_NAME" "$NODE01_NAME"; do
        install_k8s_packages_on_node "$vm" "$(k8s_version_abbrev "$(get_k8s_version_for_node "$vm")")"
    done

    install_k8s_packages_on_node "$NODE02_NAME" "$(k8s_version_abbrev "$(get_k8s_version_for_node "$NODE02_NAME")")"

    # Init cluster
    kubeadm_init

    # Join workers (controllers are already control-plane)
    join_node "$NODE01_NAME" "$(get_k8s_version_for_node "$NODE01_NAME")"
    join_node "$NODE02_NAME" "$(get_k8s_version_for_node "$NODE02_NAME")"

    verify_cluster_members

    echo ""
    log_info "============================================"
    log_info "kubeadm installation complete!"
    log_info ""
    log_info "  Controller : k8s v${K8S_VERSION_NODE01}"
    log_info "  Node 01    : k8s v${K8S_VERSION_NODE01}"
    log_info "  Node 02    : k8s v${K8S_VERSION_NODE02}"
    log_info ""
    log_info "Next: ./scripts/04-install-cilium.sh"
    log_info "============================================"
}

main "$@"
