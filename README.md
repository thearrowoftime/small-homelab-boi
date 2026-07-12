# small-homelab-boi

A from-scratch home lab: three Docker “machines”, a Kubernetes cluster (k3s),
Prometheus + Grafana monitoring, and a demo app — all provisioned with Ansible.
One `make provision` and you have a mini datacenter on a laptop.

**Companion tools:**

- [notears](https://github.com/thearrowoftime/notears) — chaos engineering + detection validation
- [sneaky-boi](https://github.com/thearrowoftime/sneaky-boi) — secret scanner for ansible / compose / k8s

---

## Table of contents

- [What it builds](#what-it-builds)
- [Architecture](#architecture)
- [Tech stack](#tech-stack)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [What happens under the hood](#what-happens-under-the-hood)
- [Repository layout](#repository-layout)
- [Makefile cheatsheet](#makefile-cheatsheet)
- [Security and secrets](#security-and-secrets)
- [Demo talking points](#demo-talking-points)
- [Moving to a VPS](#moving-to-a-vps)
- [Chaos testing with NoTears](#chaos-testing-with-notears)
- [Secret scanning with sneaky-boi](#secret-scanning-with-sneaky-boi)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## What it builds

This repository is **not a ready-made cluster** — it is the **automation that builds one**.

| Stage | Tool | Result |
|-------|------|--------|
| 1. “Machines” | Docker Compose | 3 Ubuntu containers with `systemd` + SSH (mini-VMs) |
| 2. Bootstrap | Ansible (`common`) | Hostname, `/etc/hosts`, packages, sysctls for K8s |
| 3. Kubernetes | Ansible (`k3s_server`, `k3s_agent`) | k3s cluster: 1 master + 2 workers |
| 4. Monitoring | Ansible + Helm | Prometheus, Grafana, Alertmanager |
| 5. Application | Ansible + YAML manifests | Nginx with a custom HTML page (2 replicas) |

**When provisioning finishes you get:**

| URL / path | Service |
|------------|---------|
| http://localhost:30080 | Demo app (Nginx) |
| http://localhost:30030 | Grafana (`admin` + password from vault) |
| http://localhost:30090 | Prometheus UI |
| http://localhost:30093 | Alertmanager UI |
| `kubectl` + `./kubeconfig` | Full cluster control |

---

## Architecture

```
┌─────────────────── Docker network: small-homelab ───────────────────┐
│                                                                     │
│   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐            │
│   │   master    │    │   worker1   │    │   worker2   │            │
│   │ k3s server  │    │  k3s agent  │    │  k3s agent  │            │
│   │ shb-master  │    │ shb-worker1 │    │ shb-worker2 │            │
│   └──────┬──────┘    └──────┬──────┘    └──────┬──────┘            │
│          │                  │                  │                    │
└──────────┼──────────────────┼──────────────────┼────────────────────┘
           │ SSH :2221        │ SSH :2222        │ SSH :2223
           ▼                  ▼                  ▼
    ┌──────────────────────────────────────────────────┐
    │  Ansible (WSL2 on your laptop)                   │
    │  inventory → roles → playbooks → vault           │
    └──────────────────────────────────────────────────┘

Ports published on the host (Windows):
  6443  → Kubernetes API
  30080 → demo app (NodePort)
  30030 → Grafana (NodePort)
  30090 → Prometheus (NodePort)
  30093 → Alertmanager (NodePort)
```

## Tech stack

| Layer | Technology | Notes |
|-------|------------|-------|
| “Hypervisor” | Docker Desktop + WSL2 | Privileged containers |
| Guest OS | Ubuntu 22.04 | systemd as PID 1 |
| IaC | Ansible | Roles, inventory, `ansible-vault` |
| Orchestration | k3s | v1.31, Traefik and ServiceLB disabled |
| K8s packages | Helm 3 | `kube-prometheus-stack` |
| Workload | Nginx | Deployment + ConfigMap + NodePort Service |
| CI | GitHub Actions | yamllint, ansible-lint, shellcheck |

---

## Requirements

### Hardware (minimum)

- **RAM:** ~6 GB free (3 containers × ~1.5 GB + k3s + monitoring)
- **CPU:** 4 cores recommended
- **Disk:** ~5 GB for Docker images

### Software

**Windows:** Docker Desktop with the WSL2 backend.

**WSL2** (Ubuntu / Debian / Kali):

```bash
# Ubuntu/Debian
sudo apt update && sudo apt install -y python3 python3-venv make openssh-client
sudo curl -fsSL https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl -o /usr/local/bin/kubectl && sudo chmod +x /usr/local/bin/kubectl

# Ansible — project venv (recommended on Kali)
python3 -m venv .venv
.venv/bin/pip install ansible-core
export PATH="$(pwd)/.venv/bin:$PATH"
```

> **Important:** run `ansible-playbook` in WSL, not PowerShell.

In Docker Desktop: **Settings → Resources → WSL Integration** — enable your distro.

---

## Quick start

```bash
# 1. Clone
git clone https://github.com/thearrowoftime/small-homelab-boi
cd small-homelab-boi

# 2. Ansible in a venv (if you do not have a global install)
python3 -m venv .venv && .venv/bin/pip install ansible-core
export PATH="$(pwd)/.venv/bin:$PATH"

# 3. Ansible collections
make deps

# 4. SSH key for Ansible → containers
make ssh-key

# 5. Secrets (vault)
make vault-init
$EDITOR ansible/group_vars/vault.yml   # replace CHANGE_ME with real values
make vault-encrypt                    # set a vault password — remember it!

# 6. Start containers (Docker Desktop must be running)
make up

# 7. Verify connectivity
make ping

# 8. Provision the full stack (5–15 min)
make provision

# 9. Check the result
make status
make open
```

### kubectl from the host

```bash
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get nodes -o wide
kubectl get pods -A
```

---

## What happens under the hood

`make provision` runs `ansible/playbooks/site.yml`, which imports five playbooks:

### 01 — `common` (all nodes)

- Sets hostnames (`master`, `worker1`, `worker2`)
- Writes nodes into `/etc/hosts` (so workers can resolve `master`)
- Installs packages (`curl`, `jq`, `htop`, …)
- Loads kernel modules (`br_netfilter`, `overlay`) and sysctls required by Kubernetes

### 02 — `k3s_server` (master)

- Installs k3s in server mode (`get.k3s.io`)
- Disables Traefik and klipper ServiceLB (clean NodePorts)
- Waits for the API on port 6443
- Fetches `kubeconfig` to `./kubeconfig` on the host
- Installs Helm (needed by the monitoring role)

### 03 — `k3s_agent` (workers, one at a time)

- Joins the cluster via `K3S_URL` + `K3S_TOKEN` from vault
- `serial: 1` — workers join one by one (easier debugging)

### 04 — `monitoring` (master)

- Helm: `prometheus-community/kube-prometheus-stack`
- Grafana, Prometheus, and Alertmanager exposed as NodePorts (`30030`, `30090`, `30093`)
- etcd / scheduler / controller-manager scrapers disabled (k3s does not expose them like kubeadm)

### 05 — `demo_app` (master)

- Namespace `demo`
- ConfigMap with a custom HTML page
- Nginx Deployment (2 replicas) + Service NodePort `30080`

---

## Repository layout

```
small-homelab-boi/
├── docker/
│   ├── Dockerfile.node       # Ubuntu + systemd + SSH + Python
│   ├── docker-compose.yml    # master, worker1, worker2 (shb-*)
│   └── ssh/                  # SSH keys (gitignored)
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/hosts.yml
│   ├── group_vars/
│   │   ├── all.yml
│   │   ├── k3s_cluster.yml
│   │   └── vault.yml.example
│   ├── playbooks/
│   │   ├── site.yml          # imports 01–05
│   │   ├── 01-common.yml
│   │   ├── 02-k3s-server.yml
│   │   ├── 03-k3s-agents.yml
│   │   ├── 04-monitoring.yml
│   │   └── 05-demo-app.yml
│   └── roles/
│       ├── common/
│       ├── k3s_server/
│       ├── k3s_agent/
│       ├── monitoring/
│       └── demo_app/
├── scripts/bootstrap.sh
├── docs/
│   ├── architecture.md
│   └── troubleshooting.md
├── Makefile
└── .github/workflows/lint.yml
```

---

## Makefile cheatsheet

```bash
make help         # list all targets
make up           # docker compose up --build
make down         # stop containers
make nuke         # remove containers, image, and kubeconfig
make ping         # ansible ping all nodes
make provision    # full site.yml
make k3s          # common + k3s only (no monitoring / app)
make monitoring   # kube-prometheus-stack only
make app          # Nginx demo only
make status       # nodes + pods + services
make ssh-master   # SSH into the master container
make open         # print URLs
make secrets      # scan ansible/ + docker/ for leaked secrets (sneaky-boi)
```

---

## Security and secrets

**This repository does not contain real secrets.** It only has:

- `vault.yml.example` — `CHANGE_ME` placeholders
- Jinja references (`{{ vault_k3s_token }}`) with no values

**Local only (gitignored — do not commit):**

| File | Contents |
|------|----------|
| `ansible/group_vars/vault.yml` | k3s token + Grafana password (vault-encrypted) |
| `docker/ssh/id_ed25519` | SSH private key |
| `kubeconfig` | cluster certificates |
| `.vault_pass` | ansible-vault password |

```bash
# An encrypted vault looks like this — safe to commit once encrypted:
$ANSIBLE_VAULT;1.1;AES256
663863...
```

Scan before you push or provision:

```bash
pip install 'git+https://github.com/thearrowoftime/sneaky-boi.git'
# or sibling: pip install -e ../sneaky-boi
make secrets
```

CI runs the same scan on every PR (see `.github/workflows/lint.yml`).

---

## Demo talking points

1. **Role layout** — `ansible/roles/`, one responsibility per role.
2. **Vault** — show the encrypted file, then `make vault-edit` (live decrypt).
3. **Provision** — `make provision`, timed output per task.
4. **Grafana** — *Kubernetes / Compute Resources / Cluster* dashboard on live data.
5. **Scale** — `kubectl scale deployment nginx-demo -n demo --replicas=5`, refresh `localhost:30080`.
6. **Chaos** — run [notears](https://github.com/thearrowoftime/notears) against the lab (dry-run first).
7. **Secrets** — `make secrets` with [sneaky-boi](https://github.com/thearrowoftime/sneaky-boi) before sharing the repo.

---

## Moving to a VPS

1. Rent a VPS.
2. Edit `ansible/inventory/hosts.yml`:

```yaml
master:   { ansible_host: 1.2.3.4,  ansible_port: 22 }
worker1:  { ansible_host: 1.2.3.5,  ansible_port: 22 }
worker2:  { ansible_host: 1.2.3.6,  ansible_port: 22 }
```

3. Skip `make up` — you already have real machines.
4. `make ping && make provision` — everything else stays the same.

---

## Chaos testing with NoTears

[NoTears](https://github.com/thearrowoftime/notears) is designed to pair with this lab:

| Lab resource | NoTears target |
|--------------|----------------|
| Containers `shb-master` / `shb-worker1` / `shb-worker2` | `kill_container` (workers only by default) |
| SSH `127.0.0.1:2222/2223` | `restart_service`, `break_dns`, … |
| Prometheus `:30090` | detection PromQL checks |
| Alertmanager `:30093` | alert presence checks |

```bash
# Next to this repo:
git clone https://github.com/thearrowoftime/notears
cd notears
python -m venv .venv && .venv/bin/pip install -e .
cp config.example.yaml config.yaml   # already points at shb-* + this SSH layout

notears -c config.yaml doctor
notears -c config.yaml chaos once          # dry-run
```

Control-plane (`shb-master` / host `master`) is deny-listed by default in NoTears.

---

## Secret scanning with sneaky-boi

[sneaky-boi](https://github.com/thearrowoftime/sneaky-boi) scans this repo’s ansible vars, compose files, and manifests for leaked tokens/passwords.

```text
~/Projects/
  small-homelab-boi/
  notears/
  sneaky-boi/
```

```bash
pip install -e ../sneaky-boi   # or pip install 'git+https://github.com/thearrowoftime/sneaky-boi.git'
make secrets
```

Config: `.sneaky-boi.toml` (skips `vault.yml.example`, allowlists `CHANGE_ME_` placeholders).

---

## Troubleshooting

| Symptom | What to do |
|---------|------------|
| `dockerDesktopLinuxEngine` pipe error | Start Docker Desktop |
| `docker` does not work in WSL | Enable WSL Integration in Docker Desktop |
| `make ping` → Permission denied | `make ssh-key` → `make down && make up` |
| Worker `NotReady` | Wait ~2 min; check the token in vault |
| Grafana unreachable | `kubectl get svc -n monitoring` |

Full list: [`docs/troubleshooting.md`](docs/troubleshooting.md).

---

## License

Copyright (c) ([@thearrowoftime](https://github.com/thearrowoftime)).
