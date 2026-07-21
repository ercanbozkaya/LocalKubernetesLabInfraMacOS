#!/usr/bin/env bash
# =============================================================================
# 04-install-cilium.sh - Install Cilium CNI with Hubble observability
# Installs Cilium using the official Helm chart onto the K8s cluster.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# Load shared configuration
source "$BASE_DIR/config.sh"

echo "============================================================"
echo "  Local Kubernetes Lab - Cilium CNI Installation"
echo "============================================================"
echo ""

# -----------------------
# Step -1: Ensure root has a working default kubeconfig on the controller
# (kubeadm only wrote it for the ubuntu user; every 'sudo kubectl/helm/cilium'
# call below runs as root, which has neither ~/.kube/config nor $KUBECONFIG set)
# -----------------------
ensure_root_kubeconfig() {
    log_info "Ensuring root has a working kubeconfig on controller..."
    multipass exec "$CONTROLLER_NAME" -- sudo bash <<'EOF'
set -e
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
EOF
}

# -----------------------
# Step 0: Verify cluster is ready before installing CNI
# -----------------------
verify_ready_for_cni() {
    log_info "Verifying cluster is ready for Cilium installation..."

    # NOTE: previously this ran a complex --jsonpath filter (with nested quotes/parens/@)
    # as a multipass exec command-line argument. Those special characters are exactly what
    # multipass exec's quote handling mangles, which could leave the remote shell waiting
    # on an unterminated quote/paren indefinitely (the hang you hit). Moving the query into
    # a heredoc avoids that entirely, since heredocs go over stdin, not argv.
    #
    # Also: this now checks that node OBJECTS exist, not that they're Ready — nodes can't
    # report Ready until a CNI plugin (Cilium) is actually running, so requiring Ready here
    # would always fail before we've even installed it.
    local node_status
    node_status=$(multipass exec "$CONTROLLER_NAME" -- sudo bash <<'EOF'
export KUBECONFIG=/etc/kubernetes/admin.conf
total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" {c++} END {print c+0}')
echo "${ready} ${total}"
EOF
)

    local ready_nodes total_nodes
    read -r ready_nodes total_nodes <<< "$node_status"

    log_info "Nodes registered: ${total_nodes:-0} (Ready: ${ready_nodes:-0} — NotReady is expected until Cilium is installed)"

    if [[ "${total_nodes:-0}" -lt 1 ]]; then
        log_error "Could not query any nodes from the API server. kubeadm init may have failed, or the API server is unreachable."
        exit 1
    fi

    # Check that no CNI is deployed yet ( Cilium should be the first )
    local existing_cni
    existing_cni=$(multipass exec "$CONTROLLER_NAME" -- sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -n kube-system \
        -l k8s-app=kube-proxy --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    log_info "Existing kube-proxy pods: $existing_cni (will be replaced by Cilium)"
}

# -----------------------
# Step 1: Install prerequisites on controller (kubectl, helm)
# -----------------------
install_controller_prerequisites() {
    log_info "Ensuring Helm is installed on controller..."

    multipass exec "$CONTROLLER_NAME" -- sudo bash <<'EOF'
set -e

# Install Helm 3 if not present
if ! command -v helm &>/dev/null; then
    echo "Installing Helm 3.15+ ..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
    echo "Helm already installed: $(helm version --short)"
fi

# Install the Cilium CLI too, so 'cilium status' works later
if ! command -v cilium &>/dev/null; then
    echo "Installing Cilium CLI..."
    CLI_ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    curl -fsSL "https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt" -o /tmp/cilium-cli-version
    CILIUM_CLI_VERSION=$(cat /tmp/cilium-cli-version)
    curl -fsSL "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz" \
        -o /tmp/cilium-linux.tar.gz
    tar -C /usr/local/bin -xzf /tmp/cilium-linux.tar.gz cilium
    rm -f /tmp/cilium-linux.tar.gz /tmp/cilium-cli-version
fi

echo "Helm on controller: DONE"
EOF
}

# -----------------------
# Step 2: Deploy Cilium with Helm (cross-namespace-safe, standard config)
# -----------------------
deploy_cilium() {
    log_info "Adding Cilium Helm repository..."

    multipass exec "$CONTROLLER_NAME" -- sudo helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
    multipass exec "$CONTROLLER_NAME" -- sudo helm repo update

    log_info "Deploying Cilium (cluster-wide, TaintNodesByDefault=false for mixed-version lab)..."

    # CILIUM_CHART_VERSION is intentionally blank in config.sh to mean "latest";
    # build the flag conditionally so we don't pass Helm an invalid empty --version.
    local version_flag=""
    if [[ -n "${CILIUM_CHART_VERSION}" ]]; then
        version_flag="--version ${CILIUM_CHART_VERSION}"
    fi

    # Cilium Helm values tuned for this multi-master lab:
    # - ipam mode k8s (uses Kubernetes native allocations)
    # - routingMode native + autoDirectNodeRoutes: no VXLAN/Geneve overlay, route pod
    #   traffic directly since all VMs share the same flat L2 network (multipass bridge)
    # - hubble relay + UI enabled for observability
    # - prometheus sidecar for metrics
    #
    # NOTE: unquoted heredoc delimiter (BEOF, not 'BEOF') so ${CILIUM_IPAM_MODE}
    # and $version_flag are expanded by the host from config.sh before sending.
    multipass exec "$CONTROLLER_NAME" -- sudo bash <<BEOF
set -e

helm upgrade --install cilium cilium/cilium \
    ${version_flag} \
    --namespace kube-system \
    --set ipam.mode=${CILIUM_IPAM_MODE} \
    --set routingMode=native \
    --set autoDirectNodeRoutes=true \
    --set ipv4NativeRoutingCIDR=${POD_NETWORK_CIDR} \
    --set operator.replicas=1 \
    --set hubble.enabled=true \
    --set hubble.metrics.enabled="{dns,drop,tcp,flow,port-distribution,icmp,http}" \
    --set hubble.metrics.serviceMonitor.enabled=false \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true \
    --set prometheus.serviceMonitor.enabled=false \
    --set kubeProxyReplacement=true \
    --set l2NeighDiscovery.enabled=true

echo "Cilium Helm release: DONE"
BEOF
}

# -----------------------
# Step 3: Wait for Cilium pods to become ready & verify connectivity
# -----------------------
wait_for_cilium_ready() {
    log_info "Waiting for Cilium pods to reach Ready state..."

    multipass exec "$CONTROLLER_NAME" -- sudo kubectl rollout status \
        daemonset/cilium -n kube-system --timeout=300s || true

    echo ""
    log_info "Cilium pods:"
    multipass exec "$CONTROLLER_NAME" -- sudo kubectl get pods -n kube-system \
        -l k8s-app=cilium --no-headers -o wide || true

    echo ""
    log_info "Cilium node status:"
    multipass exec "$CONTROLLER_NAME" -- sudo cilium status --wait || true

    echo ""
    log_info "Hubble relay and UI:"
    multipass exec "$CONTROLLER_NAME" -- sudo kubectl get pods -n kube-system \
        -l k8s-app=hubble 2>/dev/null || true

    # Port-forward readiness (not started here, but show how to access)
    echo ""
    log_info "Hubble UI will be available after:"
    echo '  kubectl -n kube-system port-forward svc/hubble-ui 12000:80 &'
    echo '  open http://localhost:12000'

    log_info "Cilium dashboard:"
    echo '  cilium status'
}

# -----------------------
# Step 4: Cross-verify pod networking with a quick curl test
# -----------------------
test_pod_networking() {
    log_info "Running inter-pod connectivity test across the 3 nodes..."

    # NOTE: previously this assumed all nodes register under FQDN (e.g.
    # k8slab-node01.k8slab.local), matching config.sh. In practice only the
    # controller does (kubeadm init was given --node-name); worker nodes joined
    # via `kubeadm join` with no --node-name, so kubeadm falls back to the VM's
    # short hostname (e.g. k8slab-node01, no domain suffix). Scheduling pods onto
    # the FQDN form for workers matched no real node, so they never got scheduled.
    # Look up the real names instead of assuming a naming convention.
    local all_nodes ctrl_node n1_node n2_node
    all_nodes=$(multipass exec "$CONTROLLER_NAME" -- sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    ctrl_node="" n1_node="" n2_node=""
    for n in $all_nodes; do
        case "$n" in
            "${NODE01_NAME}"*) n1_node="$n" ;;
            "${NODE02_NAME}"*) n2_node="$n" ;;
            "${CONTROLLER_NAME}"*) ctrl_node="$n" ;;
        esac
    done

    if [[ -z "$ctrl_node" || -z "$n1_node" || -z "$n2_node" ]]; then
        log_warn "Could not confidently match all 3 node names (got: $all_nodes) — skipping connectivity test."
        return 0
    fi

    log_info "Scheduling test pods on: controller=$ctrl_node node01=$n1_node node02=$n2_node"

    # Schedule a tiny test pod per node (one per node, each with nodeName affinity).
    # NOTE: unquoted heredoc so ${NODE01_NAME}/${NODE02_NAME}/${CONTROLLER_NAME}/${LAB_DOMAIN}
    # expand to the real FQDNs (e.g. k8slab-node01.k8slab.local) — the previous hardcoded
    # "node01.k8slab.local" etc. never matched an actual node, so pods stayed Pending forever.
    multipass exec "$CONTROLLER_NAME" -- sudo kubectl apply -f - <<MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: nettest-node01
  labels: { app: netcheck }
spec:
  nodeName: ${n1_node}
  containers:
    - name: alpine
      image: busybox:1.36
      command: ["sleep","infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: nettest-node02
  labels: { app: netcheck }
spec:
  nodeName: ${n2_node}
  containers:
    - name: alpine
      image: busybox:1.36
      command: ["sleep","infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: nettest-controller
  labels: { app: netcheck }
spec:
  nodeName: ${ctrl_node}
  tolerations:
    - operator: Exists
  containers:
    - name: alpine
      image: busybox:1.36
      command: ["sleep","infinity"]
MANIFEST

    log_info "Waiting for test pods to be Running (60s)..."
    multipass exec "$CONTROLLER_NAME" -- sudo kubectl wait pods \
        --for=condition=Ready -l app=netcheck -n default \
        --timeout=60s || true

    echo ""
    local pods
    pods=$(multipass exec "$CONTROLLER_NAME" -- sudo kubectl get pods -l app=netcheck \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    for src in $pods; do
        for dst in $pods; do
            [[ "$src" == "$dst" ]] && continue
            log_info "ping $src -> $dst ..."
            local dst_ip
            dst_ip=$(multipass exec "$CONTROLLER_NAME" -- sudo kubectl get pod "$dst" -o jsonpath='{.status.podIP}' 2>/dev/null)
            multipass exec "$CONTROLLER_NAME" -- sudo kubectl exec "$src" -c alpine \
                -- ping -c 2 -W 3 "$dst_ip" \
                2>/dev/null || echo "  [cross-ping: timed out — possible iptables conflict]"
        done
    done

    # Cleanup test pods
    log_info "Cleaning up networking test pods..."
    multipass exec "$CONTROLLER_NAME" -- sudo kubectl delete pods -l app=netcheck -n default 2>/dev/null || true
}

# -----------------------
# Main execution
# -----------------------
main() {
    validate_platform

    ensure_root_kubeconfig
    verify_ready_for_cni
    install_controller_prerequisites
    deploy_cilium
    wait_for_cilium_ready
    test_pod_networking

    echo ""
    log_info "============================================"
    log_info "Cilium CNI installation complete!"
    log_info ""
    log_info "  cilium status"
    log_info "  kubectl -n kube-system port-forward svc/hubble-ui 12000:80"
    log_info "============================================"
}

main "$@"