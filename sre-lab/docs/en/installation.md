# Installation

The sequence as actually executed, in order. Each section states where the
commands run.

---

## Phase 0 — Hyper-V hosts

**Where:** PowerShell as administrator, on both mini PCs.

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart

$nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
New-VMSwitch -Name 'vSwitch-ext' -NetAdapterName $nic.Name -AllowManagementOS $true

New-Item -ItemType Directory -Path 'D:\VMs','D:\ISO' -Force
```

Reboot after enabling Hyper-V. ISOs downloaded to `D:\ISO`:

- `ubuntu-24.04-live-server-amd64.iso`
- `CentOS-Stream-9-latest-x86_64-dvd1.iso`

---

## Phase 1 — Create the VMs

**Where:** PowerShell on both hosts. Scripts in [`hyperv/`](../../hyperv/).

```powershell
.\hyperv\create-vms-pc01.ps1   # on pc-01
.\hyperv\create-vms-pc02.ps1   # on pc-02
```

---

## Phase 2 — Static networking

**Where:** on each VM, via the Hyper-V console.

Ubuntu — `/etc/netplan/00-lab.yaml`:

```yaml
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      addresses: [192.168.2.152/24]   # adjust per VM
      routes:
        - to: default
          via: 192.168.2.1
      nameservers:
        addresses: [192.168.2.1, 1.1.1.1]
```

```bash
sudo chmod 600 /etc/netplan/00-lab.yaml
sudo netplan apply
```

CentOS Stream 9 (`ansible-ctl`) — no netplan:

```bash
sudo nmcli con mod 'System eth0' \
  ipv4.addresses 192.168.2.156/24 \
  ipv4.gateway 192.168.2.1 \
  ipv4.dns "192.168.2.1,1.1.1.1" \
  ipv4.method manual
sudo nmcli con up 'System eth0'
```

Validation:

```bash
for ip in 151 152 153 154 155 156 157; do
  ping -c1 -W1 192.168.2.$ip >/dev/null 2>&1 \
    && echo "192.168.2.$ip  OK" || echo "192.168.2.$ip  FAILED"
done
```

---

## Phase 4 — Kubernetes cluster

**Where:** `k8s-cp-01`, `k8s-worker-01`, `k8s-worker-02`.

Prerequisites were done manually on each node (swap, kernel modules, sysctl,
containerd, kubeadm/kubelet/kubectl). The automated equivalent lives in
[`ansible/playbooks/k8s-prereq.yml`](../../ansible/playbooks/k8s-prereq.yml),
useful for rebuilding the lab and as EX294 study material.

Packages missing from Ubuntu Server minimal that blocked preflight:

```bash
sudo apt install -y conntrack socat ethtool
```

Init — **on `k8s-cp-01` only**:

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=192.168.2.151

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
```

Join the workers with the command printed by `init`. If the token expired (24h):

```bash
kubeadm token create --print-join-command   # on the control plane
```

Result:

```
NAME            STATUS   ROLES           VERSION
k8s-cp-01       Ready    control-plane   v1.31.14
k8s-worker-01   Ready    <none>          v1.31.14
k8s-worker-02   Ready    <none>          v1.31.14
```

---

## Phase 5 — MetalLB + ingress-nginx

**Where:** `k8s-cp-01`.

```bash
# Helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml
kubectl -n metallb-system wait --for=condition=ready pod --all --timeout=180s
kubectl apply -f manifests/metallb/pool.yaml

# ingress-nginx
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace
```

Validation — an nginx 404 is the correct response here:

```bash
kubectl -n ingress-nginx get svc
curl -I http://192.168.2.200
```

---

## Phase 7 — kube-prometheus-stack

**Where:** `k8s-cp-01`.

StorageClass first — kubeadm ships none, and Prometheus' PVC would sit
`Pending`:

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

Stack:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kps prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace -f manifests/monitoring/values.yaml
```

Grafana password:

```bash
kubectl -n monitoring get secret kps-grafana -o jsonpath="{.data.admin-password}" | base64 -d; echo
```

---

## Phase 6 — Zabbix

### Server

**Where:** `zbx-01`.

Docker and the Compose plugin installed from Docker's official repository. Then:

```bash
mkdir -p ~/zabbix && cd ~/zabbix
# copy zabbix/docker-compose.yml from this repo
echo "DB_PASSWORD=$(openssl rand -base64 24)" > .env
chmod 600 .env
docker compose up -d
```

First startup takes a while — the server creates the full schema in PostgreSQL.

Frontend at `http://192.168.2.157:8080`, initial login `Admin` / `zabbix`
(changed immediately).

### Agents

**Where:** `ansible-ctl`.

```bash
sudo dnf install -y ansible-core sshpass
cd ~/lab
ansible all -m ping --ask-pass --ask-become-pass
ansible-playbook playbooks/zabbix-agent.yml --check --diff --ask-pass --ask-become-pass
ansible-playbook playbooks/zabbix-agent.yml --ask-pass --ask-become-pass
```

### Autoregistration

In the frontend: **Alerts → Actions → Autoregistration actions → Create action**

- Name: `Auto-registro Linux`
- Conditions: **none** (accepts any host)
- Operations: `Add host` · `Add to host group: Linux servers` ·
  `Link template: Linux by Zabbix agent`
- Enabled: yes

Agents announce themselves on restart:

```bash
ansible all -m systemd -a 'name=zabbix-agent2 state=restarted' --ask-pass --ask-become-pass
```

### Grafana datasource

API user in Zabbix: **Users → Users → Create user**, alias `grafana`, group
`Zabbix administrators`, **Permissions** tab → Role `Admin role`.

In Grafana: **Connections → Add new connection → Zabbix (Data Sources)**

- URL: `http://192.168.2.157:8080/api_jsonrpc.php`
- Zabbix connection: user `grafana` + password
- Save & test

---

## Phase 9 — ArgoCD (in progress)

**Where:** `k8s-cp-01`.

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl -n argocd patch svc argocd-server -p '{"spec":{"type":"LoadBalancer"}}'
kubectl -n argocd get svc argocd-server

kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

CLI:

```bash
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd /usr/local/bin/argocd
rm argocd
argocd login 192.168.2.203 --username admin --insecure
argocd account update-password
```

Still needs to point at a Git repository — see
[`manifests/argocd/application.yaml`](../../manifests/argocd/application.yaml).

---

## Checkpoints

Snapshots taken on both hosts at each milestone. Restoring takes seconds;
rebuilding takes hours.

```powershell
Get-VM | Checkpoint-VM -SnapshotName 'cluster-ok-limpo'
Get-VM | Checkpoint-VM -SnapshotName 'cluster-metallb-ingress'
Get-VM | Checkpoint-VM -SnapshotName 'fase7-observabilidade-ok'
Get-VM | Checkpoint-VM -SnapshotName 'fase6-zabbix-ok'
```
