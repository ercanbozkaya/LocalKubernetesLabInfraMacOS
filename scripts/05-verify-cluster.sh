#!/usr/bin/env bash
# =============================================================================
# 05-verify-cluster.sh - Verify full cluster health post-setup
# Checks nodes, pods (Cilium/Hubble), DNS resolution, and cross-namespace pod
# networking. All checks run against the controller VM via `multipass exec`
# (this lab does not use kubectl from the Mac itself — see README).
# This is the final "all clear" script to run after step 04.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

source "$BASE_DIR/config.sh"

echo "============================================================"
echo "  Local Kubernetes Lab - Health Verification"
echo "============================================================"
echo ""

KUBE_APPLY="kubectl apply -f -"
KUBECTL="sudo kubectl --kubeconfig /etc/kubernetes/admin.conf"

# -----------------------
# Section 1: node status
# -----------------------
section_nodes() {
    echo "===== NODES ====="
    multipass exec "$CONTROLLER_NAME" -- $KUBECTL get nodes -o wide
    echo ""
}

# -----------------------
# Section 2: system pods (Cilium / Hubble)
# -----------------------
section_system_pods() {
    echo "===== SYSTEM PODS (kube-system) ====="
    multipass exec "$CONTROLLER_NAME" -- $KUBECTL get pods -n kube-system \
        -l k8s-app=cilium --no-headers 2>/dev/null || true
    echo "Hubble components:"
    multipass exec "$CONTROLLER_NAME" -- $KUBECTL get pods -n kube-system \
        -o wide | egrep 'hubble-(relay|ui)'
    echo "" 

    # Ensure ALL pods are ready (filter out nodes we control)
    local not_ready
    not_ready=$(multipass exec "$CONTROLLER_NAME" -- sudo bash <<'EOF'
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl get pods -n kube-system --no-headers 2>/dev/null | awk '$3!="Running"{print $1"\t"$3}'
EOF
)

    if [[ -n "$not_ready" ]]; then
        log_warn "Some kube-system pods are not Running:"
        echo "$not_ready"
    else
        log_info "All kube-system pods are Running."
    fi
}

# -----------------------
# Section 3: DNS resolution inside cluster
# -----------------------
section_dns() {

echo "===== POD DNS RESOLUTION ====="

multipass exec "$CONTROLLER_NAME" -- sudo bash <<'EOF'
export KUBECONFIG=/etc/kubernetes/admin.conf

kubectl delete pod dns-test -n kube-system \
    --ignore-not-found >/dev/null 2>&1

kubectl run dns-test \
    --image=registry.k8s.io/e2e-test-images/agnhost:2.45 \
    --restart=Never \
    -n kube-system \
    --command -- nslookup kubernetes.default.svc.cluster.local

kubectl wait \
    --for=jsonpath='{.status.phase}'=Succeeded \
    pod/dns-test \
    -n kube-system \
    --timeout=60s

kubectl logs dns-test -n kube-system

kubectl delete pod dns-test \
    -n kube-system \
    --ignore-not-found >/dev/null
EOF

echo ""

}

# -----------------------
# Section 4: inter-pod ping test across nodes
# -----------------------
section_inter_pod_pings() {
    echo "===== INTER-POD PING TEST ====="

    # Look up real node names rather than assuming FQDN naming — only the
    # controller registers under its FQDN (kubeadm init sets --node-name);
    # workers join with no --node-name and register under their short hostname.
    local all_nodes ctrl_node n1_node n2_node
    all_nodes=$(multipass exec "$CONTROLLER_NAME" -- $KUBECTL get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    ctrl_node="" n1_node="" n2_node=""
    for n in $all_nodes; do
        case "$n" in
            "${NODE01_NAME}"*) n1_node="$n" ;;
            "${NODE02_NAME}"*) n2_node="$n" ;;
            "${CONTROLLER_NAME}"*) ctrl_node="$n" ;;
        esac
    done

    if [[ -z "$ctrl_node" || -z "$n1_node" || -z "$n2_node" ]]; then
        log_warn "Could not confidently match all 3 node names (got: $all_nodes) — skipping ping test."
        return 0
    fi

    # NOTE: unquoted heredoc so ${n1_node}/${n2_node}/${ctrl_node} expand; previous
    # version used a single-line compact YAML style ("metadata: name: x; labels: {...}"
    # and "{name:a,image:...}" with no space after ':') which is not valid YAML and was
    # silently failing since output was redirected to /dev/null. Also fixed the
    # toleration operator typo: "Exist" is not a valid value, it must be "Exists".
    multipass exec "$CONTROLLER_NAME" -- $KUBECTL delete pods -l app=pingtest --ignore-not-found
    multipass exec "$CONTROLLER_NAME" -- $KUBECTL wait --for=delete pod -l app=pingtest --timeout=60s

    multipass exec "$CONTROLLER_NAME" -- $KUBECTL apply -f - <<MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: ping-node01
  labels: { app: pingtest }
spec:
  nodeName: ${n1_node}
  containers:
    - name: a
      image: busybox:1.36
      command: ["sleep","infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: ping-node02
  labels: { app: pingtest }
spec:
  nodeName: ${n2_node}
  containers:
    - name: a
      image: busybox:1.36
      command: ["sleep","infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: ping-controller
  labels: { app: pingtest }
spec:
  nodeName: ${ctrl_node}
  tolerations:
    - operator: Exists
  containers:
    - name: a
      image: busybox:1.36
      command: ["sleep","infinity"]
MANIFEST

    log_info "Waiting for pingtest pods ready (60s)..."
    multipass exec "$CONTROLLER_NAME" -- $KUBECTL wait pods \
        --for=condition=Ready -l app=pingtest -n default --timeout=60s || true

    local pods
    pods=$(multipass exec "$CONTROLLER_NAME" -- $KUBECTL get pods -l app=pingtest \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    printf '<%s>\n' $pods

    for src in $pods; do
        for dst in $pods; do
            [[ "$src" == "$dst" ]] && continue
            local dst_ip
            dst_ip=$(multipass exec "$CONTROLLER_NAME" -- $KUBECTL get pod "$dst" \
                -o jsonpath='{.status.podIP}' 2>/dev/null)
            log_info "ping $src($dst_ip) -> ..."
            multipass exec "$CONTROLLER_NAME" -- \
                $KUBECTL exec "$src" -c a -- ping -c 2 "$dst_ip" && \
                echo "  ok" || echo "  timed out (expected if iptables/CNI conflict)"
        done
    done

    multipass exec "$CONTROLLER_NAME" -- $KUBECTL delete pods -l app=pingtest --ignore-not-found
    echo ""
}

# -----------------------
# Section 5: summary table
# -----------------------
section_summary() {
    echo "===== SUMMARY ====="

    # NOTE: same fix as verify_ready_for_cni in 04-install-cilium.sh — a complex
    # --jsonpath filter with nested quotes/parens/@ as a multipass exec argument
    # risks the remote shell hanging on mangled quoting. Heredoc avoids that.
    local node_status
    node_status=$(multipass exec "$CONTROLLER_NAME" -- sudo bash <<'EOF'
export KUBECONFIG=/etc/kubernetes/admin.conf
total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" {c++} END {print c+0}')
echo "${ready} ${total}"
EOF
)
    local nodes_ready total_nodes
    read -r nodes_ready total_nodes <<< "$node_status"
    nodes_ready="${nodes_ready:-0}"
    total_nodes="${total_nodes:-0}"

    [[ "$nodes_ready" -eq "$total_nodes" ]] && echo "ALL NODES: READY ($nodes_ready/$total_nodes)" \
        || echo "WARNING: $nodes_ready of $total_nodes nodes ready"

    echo ""
    log_info "Cluster is operational – you can now deploy workloads!"
}

# -----------------------
# Main
# -----------------------
main() {
    validate_platform
    section_nodes
    section_system_pods
    section_dns
    section_inter_pod_pings
    section_summary

    echo ""
    log_info "============================================"
    log_info "Verification complete."
    log_info ""
    log_info "Useful commands (run from inside the controller VM — see README):"
    log_info "  cilium status"
    log_info "  kubectl get pods -n kube-system"
    echo ""
}

main "$@"
