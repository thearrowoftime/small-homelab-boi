# Troubleshooting

## Containers exit immediately after `docker compose up`

The container needs to be privileged with cgroup access. The compose file sets
both (`privileged: true`, `cgroup: host`, `tmpfs` for `/run` and `/tmp`). If
you still see `Failed to mount cgroup` or `system has not been booted with
systemd`, double-check Docker Desktop is running on the WSL2 backend
(Settings → General → "Use the WSL 2 based engine").

## `ansible all -m ping` fails with `Permission denied (publickey)`

The container mounts `docker/ssh/id_ed25519.pub` as `authorized_keys`. Verify:

```bash
ls -l docker/ssh/id_ed25519*
docker compose -f docker/docker-compose.yml exec master \
    cat /home/ansible/.ssh/authorized_keys
```

If the file is empty inside the container, the bind-mount is wrong (most often
because you ran `make up` before `make ssh-key`). Recreate:

```bash
make down ssh-key up
```

## k3s server "fails to start" with `failed to find memory cgroup`

This happens when Docker Desktop is running with cgroup v1 but the image
expects v2 (or vice versa). The compose file pins `cgroup: host` which uses
the host's cgroup namespace and is the safest setting on modern Docker
Desktop. If you've customised Docker, set `cgroup: private` and retry.

## Workers stay `NotReady`

Check the agent logs in the worker container:

```bash
make ssh-worker1
journalctl -u k3s-agent -f --no-pager
```

The most common cause is the `K3S_TOKEN` not matching between server and
agent — that means `vault.yml` was edited but the server install isn't
re-running. Force a re-run:

```bash
make ssh-master
sudo /usr/local/bin/k3s-uninstall.sh   # nukes only k3s, not the container
exit
make provision
```

## Grafana NodePort not reachable on localhost:30030

Verify the Service exists and the pod is healthy:

```bash
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get svc -n monitoring kps-grafana
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana
```

The NodePort must be bound on the **master** node (that's the one whose ports
are forwarded by Docker). The chart values pin Grafana to `30030`, Prometheus to
`30090`, and Alertmanager to `30093`; if you change them, update
`group_vars/all.yml` and `docker/docker-compose.yml`.

## Alertmanager NodePort not reachable on localhost:30093

```bash
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get svc -n monitoring | grep -i alertmanager
```

If the Service is still ClusterIP, re-run `make monitoring` after pulling the
values that set `alertmanager.service.type=NodePort`.

## "Vault format unhexlify error"

You ran a playbook before encrypting `group_vars/vault.yml`. Either:

```bash
make vault-encrypt          # encrypt the file
# or, if you want to keep it plaintext for now:
make provision VAULT_OPTS=  # bypass --ask-vault-pass
```

## Reset everything

```bash
make nuke          # remove containers + image + kubeconfig
rm -rf docker/ssh  # remove SSH keys
make up provision  # start fresh
```
