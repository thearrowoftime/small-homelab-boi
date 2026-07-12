# Architecture

## Topology

```
Host (Windows + Docker Desktop / WSL2)
│
├─ Docker network: small-homelab (bridge)
│  ├─ container "master"   hostname=master   SSH→ 127.0.0.1:2221, K8s API→ 127.0.0.1:6443
│  ├─ container "worker1"  hostname=worker1  SSH→ 127.0.0.1:2222
│  └─ container "worker2"  hostname=worker2  SSH→ 127.0.0.1:2223
│
└─ Port forwards from master:
   30080 → demo Nginx
   30030 → Grafana
   30090 → Prometheus
   30093 → Alertmanager
```

Each container is privileged, runs `systemd` as PID 1, and behaves like a tiny
VM. Ansible doesn't need to know it's Docker - it just SSHes in and configures
"machines".

Container names on the Docker host: `shb-master`, `shb-worker1`, `shb-worker2`.
Those names are what companion tools such as
[notears](https://github.com/thearrowoftime/notears) target for chaos experiments.

## Provisioning flow

`make provision` runs `playbooks/site.yml`, which imports five playbooks:

| # | Playbook              | Hosts            | What it does                              |
|---|-----------------------|------------------|-------------------------------------------|
| 1 | `01-common.yml`       | `k3s_cluster`    | hostnames, /etc/hosts, packages, sysctls  |
| 2 | `02-k3s-server.yml`   | `server`         | install k3s server, fetch kubeconfig      |
| 3 | `03-k3s-agents.yml`   | `agent` (serial) | join workers to the cluster               |
| 4 | `04-monitoring.yml`   | `server`         | helm install kube-prometheus-stack        |
| 5 | `05-demo-app.yml`     | `server`         | kubectl apply Nginx demo                  |

## Secrets

Two secrets live in `ansible/group_vars/vault.yml` (encrypted with
`ansible-vault`):

- `vault_k3s_token` - shared pre-auth token for agents joining the server.
- `vault_grafana_admin_password` - admin password for Grafana.

`group_vars/all.yml` references them through plain variable names
(`k3s_token`, `grafana_admin_password`) so role code never sees the `vault_*`
prefix directly.

## Why these choices

- **k3s, not kubeadm** - single binary, fast install, production-grade. Same
  API as upstream Kubernetes; recruiters and engineers recognize it.
- **`--disable=traefik --disable=servicelb`** - keeps the cluster minimal,
  predictable port behaviour, and lets us expose Services via NodePort that
  the host can reach through Docker's published ports.
- **kube-prometheus-stack** - the canonical Prometheus + Grafana + Alertmanager
  bundle. One Helm release, working dashboards out of the box.
- **NodePort, not Ingress** - Ingress would need DNS or extra rewriting; for a
  laptop demo, three forwarded ports is the simpler, honest choice.
- **`serial: 1` on agents** - one worker joins at a time. Makes failures
  obvious in the log; in production it would protect rolling upgrades.

## Moving to a VPS later

The inventory is the only thing that needs to change. Replace
`ansible_host: 127.0.0.1` with the VPS IPs and adjust `ansible_port` back to
22. Everything else (roles, vault, manifests) is identical.
