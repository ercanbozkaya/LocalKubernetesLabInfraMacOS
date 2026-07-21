# 🐧 Local Kubernetes Lab on Apple Silicon MacBooks

A fully automated, script-driven guide to spin up a **3-node Kubernetes lab** entirely inside virtual machines on your Apple Silicon Mac (M1/M2/M3/M4/M5).

| VM | Role | Kubernetes version |
|---|---|---|
| `k8slab-controller` | Control plane (master) + worker | **kubeadm v1.35** |
| `k8slab-node01` | Worker | **kubeadm v1.35** |
| `k8slab-node02` | Worker | **kubeadm v1.34** (mixed-version demo) |

- **CNI:** Cilium with Hubble observability
- **Container runtime:** containerd (systemd Cgroup)
- **Naming:** FQDN-based (`k8slab-controller.k8slab.local`, `k8slab-node01.k8slab.local`, `k8slab-node02.k8slab.local`)
- **Hypervisor:** [Multipass](https://multipass.run/) (VMs are Ubuntu 24.04 standard, ARM64)
- **kubectl:** used only *inside* the controller VM — this lab does not rely on a copy of the kubeconfig on the Mac (see [Using kubectl](#using-kubectl-inside-the-controller-vm))

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start (one command)](#quick-start-one-command)
- [Step-by-step](#step-by-step)
- [Cluster topology](#cluster-topology)
- [Daily-use commands](#daily-use-commands)
- [Using kubectl (inside the controller VM)](#using-kubectl-inside-the-controller-vm)
- [Hubble UI & observability](#hubble-ui--observability)
- [Troubleshooting](#troubleshooting)
- [Resource requirements](#resource-requirements)
- [File layout](#file-layout)

---

## Prerequisites

| Item | Why | Install command |
|---|---|---|
| **macOS** (Tahoe / Sonoma / Ventura) | Multipass only ships for macOS currently | *(built-in)* |
| **Apple Silicon** (M1…M4, ARM64) | Images are `arm64`; Intel Macs need Rosetta or an upgrade path — not officially supported | *(built-in)* |
| **Multipass** ≥ 1.14 | Hypervisor for Ubuntu VMs | `brew install --cask multipass` or [download the PKG](https://github.com/canonical/multipass/releases) |
| **Homebrew** | Package manager | `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` |
| **jq** | Required — scripts parse `multipass ... --format json` with `jq` | `brew install jq` |

Note: **plain `kubectl` on the Mac is not part of this workflow** — you don't need it installed locally. All cluster interaction happens inside the controller VM (via SSH or `multipass exec`).

---

## Quick Start (one command)

```bash
git clone https://github.com/ercanbozkaya/LocalKubernetesLabInfraMacOS.git
cd LocalKubernetesLabInfraMacOS

make all      # builds the full lab end-to-end (expects Multipass pre-installed)
```

> **Note:** running bare `make` (no target) prints the help text — `help` is the
> first target defined in the `Makefile`, so it's what runs by default. Use
> `make all` (or `make help` to see every target) to kick off the full build.

The `all` target runs every script in order: **Setup → VMs → kubeadm → Cilium → Verify**.
Expect ~15–25 minutes depending on Internet speed.

---

## Step-by-step

You can also run steps individually (useful for debugging or re-running a failed step):

```bash
./scripts/01-setup-multipass.sh    # verify: Multipass is installed and configured
./scripts/02-create-vms.sh         # launches 3 Ubuntu VMs via Multipass
./scripts/03-install-k8s.sh        # bootstraps kubeadm (mixed k8s versions)
./scripts/04-install-cilium.sh     # deploys Cilium + Hubble via Helm
./scripts/05-verify-cluster.sh     # runs health checks, inter-pod ping test
```

---

## Cluster topology

```
                  ┌──────────────────────┐
                  │  Your MacBook (host) │
                  │  no local kubectl —  │──────┐
                  │  drives everything   │      │   (via `multipass exec`)
                  │  via multipass exec  │      │    
                  └──────────────────────┘      │    
                                                │
                  ┌──────────────────────────┐  │
   FQDN           │  k8slab-controller       │ ─┼── kubeadm init (v1.35)
  .local   ──────▶│  .k8slab.local           │  │   Cilium CNI (routingMode=native,
  pod CIDR        │  Control Plane           │  │               ipam=k8s, Hubble relay+UI)
  /16             ├──────────────────────────┤  │
                  │  k8slab-node01           │ ─┼── kubeadm join (v1.35)
                  │  .k8slab.local (Worker)  │  │
                  ├──────────────────────────┤  │
                  │  k8slab-node02           │ ─┼── kubeadm join (v1.34)
                  │  .k8slab.local (Worker)  │
                  └──────────────────────────┘
```

**Key networking facts**

- Multipass uses an internal NAT subnet; VMs talk to each other via that private network.
- `kubectl` never runs on your Mac in this lab. The automation scripts drive the cluster
  by issuing `multipass exec … sudo kubectl …` against the controller VM; as a human, you
  do the same thing interactively by SSH-ing into the controller (see [Using kubectl](#using-kubectl-inside-the-controller-vm)).
  Copying `admin.conf` to the Mac and pointing a local `kubectl` at it is **not supported**
  by this lab — the API server only advertises the controller's internal/FQDN address, and
  Multipass's networking model doesn't reliably expose that to the host for TLS-verified API
  access. Don't spend time trying to make this work; use the in-VM workflow instead.
- Pods get IPs from Cilium's pod CIDR (`10.244.0.0/16`, set via `POD_NETWORK_CIDR` in `config.sh`); services get IPs from kubeadm's default service range (`10.96.0.0/12` — not overridden by any script).
- Only the controller registers in the API server under its full FQDN (`kubeadm init` is given `--node-name`); `node01`/`node02` join with no `--node-name` override and register under their short hostname (`k8slab-node01`, `k8slab-node02`). Scripts that schedule pods onto specific nodes look up the real registered names rather than assuming the FQDN form.

---

## Daily-use commands

### Make targets (`make <target>`)

| Target | Description |
|---|---|
| `make all` | Full end-to-end build: setup → vms → k8s → cilium → verify |
| `make setup` | Install / upgrade Multipass |
| `make vms` | Create 3 Ubuntu VMs |
| `make k8s` | Bootstrap kubeadm cluster (mixed versions) |
| `make cilium` | Deploy Cilium CNI + Hubble |
| `make verify` / `make status` | Run health checks |
| `make destroy` | Tear down the entire lab (always non-interactive, runs `99-cleanup.sh --yes`) |
| `make ssh-controller` | SSH into controller VM (`ubuntu` user, sudo) |
| `make ssh-node01` / `make ssh-node02` | SSH into worker VMs |
| `make help` | List all targets with descriptions (also the default target if you just type `make`) |

`make destroy` always deletes `artifacts/` too — it does not forward extra flags
like `--keep-artifacts` (Make treats them as its own arguments, not the script's).
To keep the generated join commands, call the script directly instead:

```bash
./scripts/99-cleanup.sh --yes --keep-artifacts
```

### Direct script usage

```bash
./scripts/ssh-helper.sh k8slab-controller    # interactive shell on controller
./scripts/ssh-helper.sh -c "kubectl get nodes" k8slab-controller   # run a one-shot command
./scripts/99-cleanup.sh               # interactive teardown (press 'yes' to confirm)
```

---

## Using kubectl (inside the controller VM)

This lab intentionally has **no local kubectl / copied kubeconfig workflow**. Everything runs
inside the controller VM, which already has a working kubeconfig for the `ubuntu` user
(`kubeadm init` copies `/etc/kubernetes/admin.conf` to `/home/ubuntu/.kube/config` during
`03-install-k8s.sh`).

**Interactive use — SSH in and just run `kubectl` (no `sudo` needed):**

```bash
make ssh-controller
kubectl get nodes
kubectl get pods -A
```

**One-off commands from the Mac, without an interactive shell:**

```bash
./scripts/ssh-helper.sh -c "kubectl get nodes" k8slab-controller
```

**Optional alias**, once you're SSH'd in (add to the VM's `~/.bashrc`):

```bash
alias k='kubectl'
```

> The automation scripts (`04-install-cilium.sh`, `05-verify-cluster.sh`, etc.) instead use
> `multipass exec … sudo kubectl --kubeconfig /etc/kubernetes/admin.conf …` from the host.
> That's a deliberate choice for the *scripts* — it doesn't depend on any particular shell
> session's environment — but as a human working interactively, plain `kubectl` as the
> `ubuntu` user (shown above) is simpler and works just as well.

---

## Hubble UI & observability

The Hubble UI runs inside the cluster; to view it in a browser on your Mac, port-forward
**from inside the controller VM**, bound to all interfaces, and browse to the VM's IP:

```bash
# 1) SSH into the controller
make ssh-controller

# 2) Port-forward, bound to 0.0.0.0 so it's reachable from outside the VM
kubectl -n kube-system port-forward --address 0.0.0.0 svc/hubble-ui 12000:80 &
exit
```

```bash
# 3) From your Mac, find the controller's IP and open it in a browser
multipass info k8slab-controller | grep IPv4
open http://<controller-ip>:12000
```

For a quick text-only health view instead, run this inside the controller VM:

```bash
cilium status --wait
```

---

## Troubleshooting

| Symptom | Likely cause & fix |
|---|---|
| `multipass: command not found` | Multipass isn't installed — run `make setup`. Ensure Homebrew is up-to-date (`brew update && brew upgrade`). |
| `jq: command not found` | Several scripts require `jq` to parse `multipass ... --format json` — install with `brew install jq`. |
| VM won't get an IP after `make vms` | Your Mac's DNS/mDNS service may block the `.local` FQDN. Try `sudo multipass set local.dns-mode=off`. |
| kubeadm init fails with "cgroup driver mismatch" | containerd was started **before** the systemd Cgroup config was written. Re-run `03-install-k8s.sh`; it detects the existing `/etc/containerd/config.toml`. |
| Nodes show `NotReady` after Cilium install | Wait 2–3 minutes; the CNI daemonset needs a few cycles to provision. Check `kubectl -n kube-system get pods -l k8s-app=cilium` (run this inside the controller VM). |
| `kubectl: command not found` on the Mac, or a copied `admin.conf` can't reach the API server | Expected — this lab doesn't support driving the cluster from a local kubectl. SSH into the controller (`make ssh-controller`) or use `./scripts/ssh-helper.sh -c "..."` instead. |
| Mixed-version join fails on node02 (v1.34) | Ensure node02's `/etc/apt/sources.list.d/kubernetes.list` points to **its own** repo (`core-1.34`). The script handles this per-node already — re-run `./scripts/03-install-k8s.sh`. |
| Cilium logs: `Node has no IPv4` or NAT errors | This is normal on Multipass's NAT; Cilium falls back to host-firewall-less mode. Works fine for intra-cluster traffic. |
| `kubectl exec … ping` hangs inside pod | Expected if a CNI conflict (e.g., previous flannel/weave) remains. Re-run setup from scratch (`make destroy && make all`). |

### Resetting the lab entirely

```bash
make destroy    # or: ./scripts/99-cleanup.sh --yes
make all        # rebuild from scratch
```

Your `artifacts/join-commands.sh` (auto-generated kubeadm join commands) can be
preserved across rebuilds by calling the cleanup script directly with
`--keep-artifacts` (see [Make targets](#make-targets-make-target) above).

---

## Resource requirements

| Config | Default | Notes |
|---|---|---|
| Controller RAM / CPU | 4 GB / 2 vCPU | Control plane needs more than workers |
| Worker RAM / CPU (each) | 4 GB / 2 vCPU | |
| Disk per VM | 25 GB | Sufficient for ~10–20 small Deployments |
| **Total required** | ~12 GB RAM, 6 vCPU | Adjust in `.env` (see below) or directly in `config.sh` |

If your Mac has only **8 GB total RAM**, consider reducing `CONTROLLER_MEMORY` and
`NODE_MEMORY` to **2048**:

```bash
# .env  (placed alongside Makefile)
NODE_MEMORY=2048
CONTROLLER_MEMORY=2048
```

`config.sh` sources `.env` *before* declaring its variables `readonly`, so overrides
placed there take effect normally — no special ordering caveats to worry about.

---

## File layout

```
LocalKubernetesLabInfraMacOS/
├── Makefile                      # make all | setup | vms | k8s | cilium | verify | destroy | help
├── config.sh                     # shared variables (VMs, versions, CNI)
├── scripts/
│   ├── 01-setup-multipass.sh     # step 1 — install Multipass
│   ├── 02-create-vms.sh          # step 2 — launch VMs, populate /etc/hosts
│   ├── 03-install-k8s.sh         # step 3 — kubeadm init + join (mixed versions)
│   ├── 04-install-cilium.sh      # step 4 — Cilium + Hubble via Helm
│   ├── 05-verify-cluster.sh      # step 5 — node/pod/DNS/inter-pod checks
│   ├── ssh-helper.sh             # SSH convenience wrapper (interactive + -c)
│   └── 99-cleanup.sh             # teardown (with --keep-artifacts flag)
├── artifacts/                    # auto-generated: join-commands.sh (regenerates on each k8s run, gitignored)
└── .env                          # optional user override (see Resource requirements section above)
```

---

## License

MIT — use freely for learning and experimentation.

---

**Built for Apple Silicon (ARM64) MacBooks.** If you encounter issues, open a GitHub Issue with `multipass list` output and the last 30 lines of `./scripts/05-verify-cluster.sh`.
