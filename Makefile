# Home Lab control plane.
# Run from WSL2 (Ansible doesn't run natively on Windows).
# Requires: docker, docker compose, ansible-core, ssh-keygen.

SHELL              := /bin/bash
PROJECT            := small-homelab-boi
DOCKER_DIR         := docker
ANSIBLE_DIR        := ansible
SSH_DIR            := $(DOCKER_DIR)/ssh
SSH_KEY            := $(SSH_DIR)/id_ed25519
VAULT_PASS_FILE    ?= .vault_pass
KUBECONFIG_FILE    := kubeconfig
PYTHON             ?= python3

ANSIBLE            := cd $(ANSIBLE_DIR) && ansible-playbook
VAULT_OPTS         := $(shell test -f $(VAULT_PASS_FILE) && echo --vault-password-file=../$(VAULT_PASS_FILE) || echo --ask-vault-pass)

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage: make \033[36m<target>\033[0m\n\nTargets:\n"} \
	     /^[a-zA-Z0-9_.-]+:.*##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# ---------- Bootstrap ----------

.PHONY: deps
deps: ## Install Ansible collections required by the roles
	cd $(ANSIBLE_DIR) && ansible-galaxy collection install -r requirements.yml

.PHONY: ssh-key
ssh-key: ## Generate an SSH keypair used by Ansible to log into containers
	@mkdir -p $(SSH_DIR)
	@test -f $(SSH_KEY) || ssh-keygen -t ed25519 -N "" -C "ansible@homelab" -f $(SSH_KEY)
	@chmod 600 $(SSH_KEY)
	@echo "SSH key ready: $(SSH_KEY)"

.PHONY: vault-init
vault-init: ## Create group_vars/vault.yml from the example and encrypt it
	@if [ ! -f $(ANSIBLE_DIR)/group_vars/vault.yml ]; then \
	    cp $(ANSIBLE_DIR)/group_vars/vault.yml.example $(ANSIBLE_DIR)/group_vars/vault.yml; \
	    echo "Created group_vars/vault.yml — edit the placeholders, then run 'make vault-encrypt'"; \
	else \
	    echo "vault.yml already exists; skip."; \
	fi

.PHONY: vault-encrypt
vault-encrypt: ## Encrypt group_vars/vault.yml with ansible-vault
	cd $(ANSIBLE_DIR) && ansible-vault encrypt group_vars/vault.yml

.PHONY: vault-edit
vault-edit: ## Edit the encrypted vault file
	cd $(ANSIBLE_DIR) && ansible-vault edit group_vars/vault.yml $(VAULT_OPTS)

# ---------- Lifecycle ----------

.PHONY: up
up: ssh-key ## Build images and start the 3 node containers
	cd $(DOCKER_DIR) && docker compose up -d --build

.PHONY: down
down: ## Stop and remove all containers
	cd $(DOCKER_DIR) && docker compose down

.PHONY: nuke
nuke: ## Destroy containers AND remove the built image (clean slate)
	cd $(DOCKER_DIR) && docker compose down --volumes --rmi local
	@rm -f $(KUBECONFIG_FILE)

.PHONY: ps
ps: ## Show container status
	cd $(DOCKER_DIR) && docker compose ps

# ---------- Provision ----------

.PHONY: ping
ping: ## Verify Ansible can reach every container
	cd $(ANSIBLE_DIR) && ansible all -m ansible.builtin.ping

.PHONY: provision
provision: ## Run the full site playbook (common + k3s + monitoring + demo app)
	$(ANSIBLE) playbooks/site.yml $(VAULT_OPTS)

.PHONY: k3s
k3s: ## Provision only the k3s cluster (no monitoring / app)
	$(ANSIBLE) playbooks/01-common.yml $(VAULT_OPTS)
	$(ANSIBLE) playbooks/02-k3s-server.yml $(VAULT_OPTS)
	$(ANSIBLE) playbooks/03-k3s-agents.yml $(VAULT_OPTS)

.PHONY: monitoring
monitoring: ## (Re)install Prometheus + Grafana only
	$(ANSIBLE) playbooks/04-monitoring.yml $(VAULT_OPTS)

.PHONY: app
app: ## (Re)deploy the Nginx demo app only
	$(ANSIBLE) playbooks/05-demo-app.yml $(VAULT_OPTS)

# ---------- Cluster access ----------

.PHONY: kubeconfig
kubeconfig: ## Print the export needed to use kubectl from the host
	@echo "export KUBECONFIG=$$(pwd)/$(KUBECONFIG_FILE)"

.PHONY: status
status: ## Quick cluster status report (nodes, pods, services)
	@KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -o wide
	@echo
	@KUBECONFIG=$(KUBECONFIG_FILE) kubectl get pods -A
	@echo
	@KUBECONFIG=$(KUBECONFIG_FILE) kubectl get svc -A

.PHONY: open
open: ## Print URLs for the demo app, Prometheus and Grafana
	@echo "Demo app : http://localhost:30080"
	@echo "Grafana  : http://localhost:30030  (user: admin)"
	@echo "Prom UI  : http://localhost:30090"

.PHONY: ssh-master ssh-worker1 ssh-worker2
ssh-master: ## SSH into the master container
	ssh -i $(SSH_KEY) -p 2221 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ansible@127.0.0.1
ssh-worker1: ## SSH into worker1
	ssh -i $(SSH_KEY) -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ansible@127.0.0.1
ssh-worker2: ## SSH into worker2
	ssh -i $(SSH_KEY) -p 2223 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ansible@127.0.0.1
