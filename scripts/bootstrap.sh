#!/usr/bin/env bash
# One-shot bootstrap for fresh checkouts. Run from the repo root in WSL2.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Installing Ansible collections"
make deps

echo "==> Generating SSH keypair (if missing)"
make ssh-key

echo "==> Preparing vault file"
if [ ! -f ansible/group_vars/vault.yml ]; then
    make vault-init
    echo
    echo "!!  Edit ansible/group_vars/vault.yml and replace the CHANGE_ME values."
    echo "!!  Then run:  make vault-encrypt   (you'll be asked for a vault password)"
    exit 0
fi

echo "==> Starting containers"
make up

echo "==> Waiting for SSH on all nodes (max 30s)"
for port in 2221 2222 2223; do
    for _ in $(seq 1 30); do
        if ssh -i docker/ssh/id_ed25519 -p $port \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=1 ansible@127.0.0.1 true 2>/dev/null; then
            echo "    port $port: OK"
            break
        fi
        sleep 1
    done
done

echo "==> Provisioning cluster (this takes a few minutes)"
make provision

echo
echo "Done."
make open
