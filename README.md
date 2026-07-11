# small-homelab-boi

**Autor:** [MK (@thearrowoftime)](https://github.com/thearrowoftime)

Lokalny home lab zbudowany od zera: trzy „maszyny” w Dockerze, klaster Kubernetes (k3s),
monitoring Prometheus + Grafana oraz demo aplikacja — wszystko provisionowane przez Ansible.
Jeden `make provision` i masz działający mini-datacenter na laptopie.

> Projekt portfolio pod DevOps / Platform / SRE. Ten sam kod działa na VPS za ~5 €/mies. —
> zmieniasz tylko inventory, reszta zostaje.

---

## Spis treści

- [Co to robi](#co-to-robi)
- [Architektura](#architektura)
- [Stack technologiczny](#stack-technologiczny)
- [Wymagania](#wymagania)
- [Szybki start](#szybki-start)
- [Co dzieje się pod spodem](#co-dzieje-się-pod-spodem)
- [Struktura repozytorium](#struktura-repozytorium)
- [Makefile — skróty](#makefile--skróty)
- [Bezpieczeństwo i sekrety](#bezpieczeństwo-i-sekrety)
- [Jak pokazać to na rozmowie](#jak-pokazać-to-na-rozmowie)
- [Przeniesienie na VPS](#przeniesienie-na-vps)
- [Rozwiązywanie problemów](#rozwiązywanie-problemów)
- [Licencja](#licencja)

---

## Co to robi

To repozytorium **nie jest gotowym klastrem** — to **automatyzacja**, która go buduje.

| Etap | Narzędzie | Efekt |
|------|-----------|-------|
| 1. „Maszyny” | Docker Compose | 3 kontenery Ubuntu z `systemd` + SSH (jak mini-VM) |
| 2. Bootstrap | Ansible (`common`) | Hostname, `/etc/hosts`, pakiety, sysctl pod K8s |
| 3. Kubernetes | Ansible (`k3s_server`, `k3s_agent`) | Klaster k3s: 1 master + 2 workery |
| 4. Monitoring | Ansible + Helm | Prometheus, Grafana, Alertmanager |
| 5. Aplikacja | Ansible + manifesty YAML | Nginx z własną stroną HTML (2 repliki) |

**Po zakończeniu** masz:

| Adres | Usługa |
|-------|--------|
| http://localhost:30080 | Demo aplikacja (Nginx) |
| http://localhost:30030 | Grafana (`admin` + hasło z vault) |
| http://localhost:30090 | Prometheus UI |
| `kubectl` + `./kubeconfig` | Pełna kontrola klastra |

---

## Architektura

```
┌─────────────────── Docker network: small-homelab ───────────────────┐
│                                                                     │
│   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐            │
│   │   master    │    │   worker1   │    │   worker2   │            │
│   │ k3s server  │    │  k3s agent  │    │  k3s agent  │            │
│   └──────┬──────┘    └──────┬──────┘    └──────┬──────┘            │
│          │                  │                  │                    │
└──────────┼──────────────────┼──────────────────┼────────────────────┘
           │ SSH :2221        │ SSH :2222        │ SSH :2223
           ▼                  ▼                  ▼
    ┌──────────────────────────────────────────────────┐
    │  Ansible (WSL2 na Twoim laptopie)                │
    │  inventory → role → playbook → vault           │
    └──────────────────────────────────────────────────┘

Porty wystawione na host (Windows):
  6443  → Kubernetes API
  30080 → demo app (NodePort)
  30030 → Grafana (NodePort)
  30090 → Prometheus (NodePort)
```

**Dlaczego kontenery zamiast prawdziwych VM?**

- Lżej na laptopie (mniej RAM niż 3× VirtualBox).
- Ansible i tak widzi je jak serwery — łączy się po SSH.
- Ten sam playbook działa na VPS po zmianie IP w inventory.

Szczegóły: [`docs/architecture.md`](docs/architecture.md).

---

## Stack technologiczny

| Warstwa | Technologia | Wersja / uwagi |
|---------|-------------|----------------|
| „Hypervisor” | Docker Desktop + WSL2 | privileged containers, cgroup v2 |
| OS w kontenerach | Ubuntu 22.04 | systemd jako PID 1 |
| IaC | Ansible | role, inventory, `ansible-vault` |
| Orchestracja | k3s | v1.31, Traefik i ServiceLB wyłączone |
| Pakiety K8s | Helm 3 | `kube-prometheus-stack` |
| Workload | Nginx | Deployment + ConfigMap + NodePort Service |
| CI | GitHub Actions | yamllint, ansible-lint, shellcheck |

---

## Wymagania

### Sprzęt (minimum)

- **RAM:** ~6 GB wolnej (3 kontenery × ~1.5 GB + k3s + monitoring)
- **CPU:** 4 rdzenie (zalecane)
- **Dysk:** ~5 GB na obrazy Docker

### Oprogramowanie

**Windows:** Docker Desktop z backendem WSL2.

**WSL2** (Ubuntu / Debian / Kali):

```bash
# Ubuntu/Debian
sudo apt update && sudo apt install -y python3 python3-venv make openssh-client
sudo curl -fsSL https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl \
    -o /usr/local/bin/kubectl && sudo chmod +x /usr/local/bin/kubectl

# Ansible — venv w katalogu projektu (zalecane na Kali)
python3 -m venv .venv
.venv/bin/pip install ansible-core
export PATH="$(pwd)/.venv/bin:$PATH"
```

> **Ważne:** `ansible-playbook` uruchamiaj w WSL, nie w PowerShell.

W Docker Desktop: **Settings → Resources → WSL Integration** — włącz swoją dystrybucję.

---

## Szybki start

```bash
# 1. Klonuj
git clone https://github.com/thearrowoftime/small-homelab-boi
cd small-homelab-boi

# 2. Ansible w venv (jeśli nie masz globalnego)
python3 -m venv .venv && .venv/bin/pip install ansible-core
export PATH="$(pwd)/.venv/bin:$PATH"

# 3. Kolekcje Ansible
make deps

# 4. Klucz SSH dla Ansible → kontenery
make ssh-key

# 5. Sekrety (vault)
make vault-init
$EDITOR ansible/group_vars/vault.yml   # zamień CHANGE_ME na prawdziwe wartości
make vault-encrypt                    # ustaw hasło vault — zapamiętaj!

# 6. Uruchom kontenery (Docker Desktop musi działać!)
make up

# 7. Sprawdź połączenie
make ping

# 8. Provision całego stacku (5–15 min)
make provision

# 9. Sprawdź wynik
make status
make open
```

### kubectl z hosta

```bash
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get nodes -o wide
kubectl get pods -A
```

---

## Co dzieje się pod spodem

`make provision` odpala `ansible/playbooks/site.yml`, który importuje pięć playbooków:

### 01 — `common` (wszystkie nody)

- Ustawia hostname (`master`, `worker1`, `worker2`)
- Wpisuje węzły do `/etc/hosts` (żeby `master` rozwiązywał się z workerów)
- Instaluje pakiety (`curl`, `jq`, `htop`, …)
- Ładuje moduły jądra (`br_netfilter`, `overlay`) i sysctl wymagane przez Kubernetes

### 02 — `k3s_server` (master)

- Instaluje k3s w trybie server (`get.k3s.io`)
- Wyłącza Traefik i klipper ServiceLB (czyste NodePorty)
- Czeka na API na porcie 6443
- Pobiera `kubeconfig` do `./kubeconfig` na hoście
- Instaluje Helm (potrzebny w roli monitoring)

### 03 — `k3s_agent` (workery, po jednym)

- Join do klastra przez `K3S_URL` + `K3S_TOKEN` z vault
- `serial: 1` — worker dołącza pojedynczo (łatwiejszy debug)

### 04 — `monitoring` (master)

- Helm: `prometheus-community/kube-prometheus-stack`
- Grafana i Prometheus wystawione jako NodePort (`30030`, `30090`)
- Wyłączone scrapery etcd/scheduler/cm (k3s ich nie eksponuje jak kubeadm)

### 05 — `demo_app` (master)

- Namespace `demo`
- ConfigMap z customową stroną HTML
- Deployment Nginx (2 repliki) + Service NodePort `30080`

---

## Struktura repozytorium

```
small-homelab-boi/
├── docker/
│   ├── Dockerfile.node       # Ubuntu + systemd + SSH + Python
│   ├── docker-compose.yml    # master, worker1, worker2
│   └── ssh/                  # klucze SSH (gitignored)
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/hosts.yml
│   ├── group_vars/
│   │   ├── all.yml
│   │   ├── k3s_cluster.yml
│   │   └── vault.yml.example
│   ├── playbooks/
│   │   ├── site.yml          # master — importuje 01–05
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

## Makefile — skróty

```bash
make help         # lista wszystkich targetów
make up           # docker compose up --build
make down         # zatrzymaj kontenery
make nuke         # usuń kontenery, obraz i kubeconfig
make ping         # ansible ping na wszystkie nody
make provision    # pełny site.yml
make k3s          # tylko common + k3s (bez monitoringu i apki)
make monitoring   # tylko kube-prometheus-stack
make app          # tylko Nginx demo
make status       # nodes + pods + services
make ssh-master   # SSH do kontenera master
make open         # wypisz URL-e
```

---

## Bezpieczeństwo i sekrety

**W repozytorium NIE MA prawdziwych sekretów.** Są tylko:

- `vault.yml.example` — placeholdery `CHANGE_ME`
- odwołania Jinja (`{{ vault_k3s_token }}`) bez wartości

**Lokalnie (gitignored, nie commituj):**

| Plik | Zawartość |
|------|-----------|
| `ansible/group_vars/vault.yml` | token k3s + hasło Grafana (zaszyfrowane vault-em) |
| `docker/ssh/id_ed25519` | klucz prywatny SSH |
| `kubeconfig` | certyfikaty klastra |
| `.vault_pass` | hasło do ansible-vault |

```bash
# Zaszyfrowany vault wygląda tak — bezpiecznie do commita, jeśli zaszyfrowany:
$ANSIBLE_VAULT;1.1;AES256
663863...
```

---

## Jak pokazać to na rozmowie

1. **Struktura ról** — `ansible/roles/`, każda rola = jedna odpowiedzialność.
2. **Vault** — pokaż zaszyfrowany plik, potem `make vault-edit` (odszyfrowanie na żywo).
3. **Provision** — `make provision`, output z timerami per task.
4. **Grafana** — dashboard *Kubernetes / Compute Resources / Cluster*, dane z żywego klastra.
5. **Skalowanie** — `kubectl scale deployment nginx-demo -n demo --replicas=5`, odśwież `localhost:30080`.

---

## Przeniesienie na VPS

1. Wynajmij VPS (np. Hetzner CX22: 2 vCPU, 4 GB RAM, ~4 €/mies.).
2. Edytuj `ansible/inventory/hosts.yml`:

```yaml
master:   { ansible_host: 1.2.3.4,  ansible_port: 22 }
worker1:  { ansible_host: 1.2.3.5,  ansible_port: 22 }
worker2:  { ansible_host: 1.2.3.6,  ansible_port: 22 }
```

3. Pomiń `make up` — masz prawdziwe maszyny.
4. `make ping && make provision` — reszta bez zmian.

---

## Rozwiązywanie problemów

| Objaw | Co zrobić |
|-------|-----------|
| `dockerDesktopLinuxEngine` pipe error | Uruchom Docker Desktop |
| `docker` nie działa w WSL | Włącz WSL Integration w Docker Desktop |
| `make ping` → Permission denied | `make ssh-key` → `make down && make up` |
| Worker `NotReady` | Poczekaj 2 min; sprawdź token w vault |
| Grafana niedostępna | `kubectl get svc -n monitoring` |

Pełna lista: [`docs/troubleshooting.md`](docs/troubleshooting.md).

---

## Licencja

MIT — zobacz [LICENSE](LICENSE).  
Copyright (c) 2026 MK ([@thearrowoftime](https://github.com/thearrowoftime)).
