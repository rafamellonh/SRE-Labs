# Troubleshooting

Problems actually hit while building this, with the fix that was applied.

---

## `conntrack not found in system path` on `kubeadm init`

```
[ERROR FileExisting-conntrack]: conntrack not found in system path
```

**Cause:** Ubuntu Server minimal doesn't ship the binary. `kube-proxy` needs it
to track connections in the Services' NAT rules — without it, ClusterIP doesn't
work.

**Fix** — on all three nodes:

```bash
sudo apt install -y conntrack socat ethtool
```

`socat` is used by `kubectl port-forward`; `ethtool` belongs to the same group of
preflight checks.

Preflight fails **before** changing anything, so just re-run `kubeadm init` — no
`reset` needed.

**How to read this error:** the `FileExisting-` prefix means "does this binary
exist in PATH?". kubeadm doesn't say which package provides it. When the command
name doesn't match the package name:

```bash
conntrack                        # Ubuntu suggests the package
apt-file search bin/conntrack    # or search explicitly
```

---

## `Invalid callback for stdout specified: yaml`

**Cause:** the `yaml` callback lives in the `community.general` collection, which
isn't bundled with plain `ansible-core`.

**Fix A** — remove it from `ansible.cfg`:

```bash
sed -i '/stdout_callback = yaml/d' ansible.cfg
```

**Fix B** — install the collection and use the fully qualified name:

```bash
ansible-galaxy collection install community.general
# ansible.cfg: stdout_callback = community.general.yaml
```

---

## `No package matching 'zabbix-agent2' is available`

Failed on all five Ubuntu hosts; worked on `zbx-01`, which already had the
repository installed manually.

**Cause:** `update_cache: true` on the generic `package` module doesn't reliably
pass the refresh through to APT. The repository was added, but the index was
never read.

**Fix:** explicit refresh tasks between the repository and the install:

```yaml
- name: Refresh APT cache
  apt:
    update_cache: true
  when: ansible_os_family == 'Debian'

- name: Refresh DNF cache
  dnf:
    update_cache: true
  when: ansible_os_family == 'RedHat'
```

And drop `update_cache` from the install task, where it does nothing useful.

**Useful diagnostic:**

```bash
ansible k8s-cp-01 -m shell -a 'apt-cache policy zabbix-agent2' --ask-pass
```

---

## Zabbix: `Cannot establish TCP connection to [[127.0.0.1]:10050]`

**Cause:** the built-in "Zabbix server" host points at `127.0.0.1:10050`,
expecting a local agent. But `zabbix-server` runs in a container — `127.0.0.1`
there is the container itself, which has no agent.

**Fix:** install the native agent on `zbx-01` and change the host's interface in
the frontend from `127.0.0.1` to `192.168.2.157`.

In `zabbix_agent2.conf`, `Server=` must include the Docker range, because the
connection from the container arrives with an IP from that network:

```
Server=192.168.2.157,172.16.0.0/12
```

---

## `Incorrect value for field "value": cannot be empty` on the Zabbix action

**Cause:** the "New condition" dialog was opened, and it requires a value.

**Fix:** `Cancel`. To accept any host, the Conditions section must be left
**untouched** — don't click Add. An action with no conditions accepts every host
that announces itself.

---

## `Field "roleid" is mandatory` when creating a Zabbix user

**Cause:** Role lives on the **Permissions** tab, not the User tab.

**Fix:** Permissions tab → Role → `Admin role`. Data already entered on other
tabs persists while navigating between them.

---

## Duplicate host in Zabbix

`Zabbix server` and `zbx-01` both pointing at `192.168.2.157:10050` — duplicate
collection on the same VM.

**Cause:** the built-in host plus the one created by autoregistration.

**Fix:** disable `zbx-01` (the autoregistered one) and keep `Zabbix server`,
which carries extra internal-monitoring templates — 160 items versus 73.
Disable rather than delete: if autoregistration recreates it, that stays
visible.

---

## `kubectl get pods -w` appears to hang

It didn't hang — `-w` (watch) keeps listening for changes and never returns on
its own.

`Ctrl+C` to exit. Alternatives:

```bash
kubectl -n monitoring get pods            # returns immediately
watch -n5 kubectl -n monitoring get pods  # redraws the screen, more readable
```

---

## Symptom quick reference

| Symptom | Likely cause |
|---|---|
| MetalLB `EXTERNAL-IP` stuck `<pending>` | `MacAddressSpoofing` off, or `L2Advertisement` not applied |
| Pods on different nodes can't reach each other | `MacAddressSpoofing` off in Hyper-V |
| Node flapping `NotReady` | cgroup driver mismatch — `SystemdCgroup` must be `true` |
| kubelet won't start | swap still enabled |
| PVC stuck `Pending` | no default StorageClass |
| ServiceMonitor ignored with no error | `serviceMonitorSelectorNilUsesHelmValues` not set to `false` |
| `gpg: cannot open` when adding k8s repo | `/etc/apt/keyrings` doesn't exist |
| IP conflict | range not excluded from router DHCP |
| Seemingly random TLS errors | clock drift — a saved VM wakes up behind, chrony missing |

---

## Cross-host network test

Worth running whenever networking changes. It forces pods on different nodes to
talk to each other — this is the test that actually catches MAC spoofing
problems, which `get nodes` won't reveal:

```bash
kubectl create deployment netcheck --image=nginx --replicas=4
kubectl expose deployment netcheck --port=80
kubectl run tester --image=busybox:1.36 --rm -it --restart=Never -- \
  sh -c 'for i in 1 2 3 4 5; do wget -qO- --timeout=3 netcheck | head -1; done'
kubectl delete deployment netcheck && kubectl delete svc netcheck
```

Intermittent timeouts = spoofing off on one of the VMs.
