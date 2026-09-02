# Instalação

Sequência efetivamente executada, na ordem. Cada seção indica onde os comandos
rodam.

---

## Fase 0 — Hosts Hyper-V

**Onde:** PowerShell como administrador, nos dois mini PCs.

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart

$nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
New-VMSwitch -Name 'vSwitch-ext' -NetAdapterName $nic.Name -AllowManagementOS $true

New-Item -ItemType Directory -Path 'D:\VMs','D:\ISO' -Force
```

Reiniciar depois de habilitar o Hyper-V. ISOs baixadas para `D:\ISO`:

- `ubuntu-24.04-live-server-amd64.iso`
- `CentOS-Stream-9-latest-x86_64-dvd1.iso`

---

## Fase 1 — Criar as VMs

**Onde:** PowerShell nos dois hosts. Scripts em [`hyperv/`](../hyperv/).

```powershell
.\hyperv\create-vms-pc01.ps1   # no pc-01
.\hyperv\create-vms-pc02.ps1   # no pc-02
```

---

## Fase 2 — Rede estática

**Onde:** em cada VM, via console do Hyper-V.

Ubuntu — `/etc/netplan/00-lab.yaml`:

```yaml
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      addresses: [192.168.2.152/24]   # ajustar por VM
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

CentOS Stream 9 (`ansible-ctl`) — não usa netplan:

```bash
sudo nmcli con mod 'System eth0' \
  ipv4.addresses 192.168.2.156/24 \
  ipv4.gateway 192.168.2.1 \
  ipv4.dns "192.168.2.1,1.1.1.1" \
  ipv4.method manual
sudo nmcli con up 'System eth0'
```

Validação:

```bash
for ip in 151 152 153 154 155 156 157; do
  ping -c1 -W1 192.168.2.$ip >/dev/null 2>&1 \
    && echo "192.168.2.$ip  OK" || echo "192.168.2.$ip  FALHOU"
done
```

---

## Fase 4 — Cluster Kubernetes

**Onde:** `k8s-cp-01`, `k8s-worker-01`, `k8s-worker-02`.

Os prereqs foram executados manualmente em cada nó (swap, módulos, sysctl,
containerd, kubeadm/kubelet/kubectl). O equivalente automatizado está em
[`ansible/playbooks/k8s-prereq.yml`](../ansible/playbooks/k8s-prereq.yml), que
serve para reconstruir o lab ou como material de estudo de EX294.

Pacotes que faltavam no Ubuntu Server minimal e travaram o preflight:

```bash
sudo apt install -y conntrack socat ethtool
```

Init — **apenas no `k8s-cp-01`**:

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=192.168.2.151

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
```

Join nos workers com o comando impresso pelo `init`. Se o token expirou (24h):

```bash
kubeadm token create --print-join-command   # no cp
```

Resultado:

```
NAME            STATUS   ROLES           VERSION
k8s-cp-01       Ready    control-plane   v1.31.14
k8s-worker-01   Ready    <none>          v1.31.14
k8s-worker-02   Ready    <none>          v1.31.14
```

---

## Fase 5 — MetalLB + ingress-nginx

**Onde:** `k8s-cp-01`.

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

Validação — 404 do nginx é a resposta correta:

```bash
kubectl -n ingress-nginx get svc
curl -I http://192.168.2.200
```

---

## Fase 7 — kube-prometheus-stack

**Onde:** `k8s-cp-01`.

StorageClass primeiro — kubeadm não traz nenhuma, e o PVC do Prometheus ficaria
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

Senha do Grafana:

```bash
kubectl -n monitoring get secret kps-grafana -o jsonpath="{.data.admin-password}" | base64 -d; echo
```

---

## Fase 6 — Zabbix

### Server

**Onde:** `zbx-01`.

Docker + Compose plugin instalados pelo repositório oficial da Docker. Depois:

```bash
mkdir -p ~/zabbix && cd ~/zabbix
# copiar zabbix/docker-compose.yml deste repo
echo "DB_PASSWORD=$(openssl rand -base64 24)" > .env
chmod 600 .env
docker compose up -d
```

Primeira subida demora — o server cria todo o schema no PostgreSQL.

Frontend em `http://192.168.2.157:8080`, login inicial `Admin` / `zabbix`
(trocado imediatamente).

### Agentes

**Onde:** `ansible-ctl`.

```bash
sudo dnf install -y ansible-core sshpass
cd ~/lab
ansible all -m ping --ask-pass --ask-become-pass
ansible-playbook playbooks/zabbix-agent.yml --check --diff --ask-pass --ask-become-pass
ansible-playbook playbooks/zabbix-agent.yml --ask-pass --ask-become-pass
```

### Auto-registro

No frontend: **Alerts → Actions → Autoregistration actions → Create action**

- Name: `Auto-registro Linux`
- Conditions: **nenhuma** (aceita qualquer host)
- Operations: `Add host` · `Add to host group: Linux servers` ·
  `Link template: Linux by Zabbix agent`
- Enabled: sim

Os agentes se anunciam no restart:

```bash
ansible all -m systemd -a 'name=zabbix-agent2 state=restarted' --ask-pass --ask-become-pass
```

### Datasource no Grafana

Usuário de API no Zabbix: **Users → Users → Create user**, alias `grafana`,
grupo `Zabbix administrators`, aba **Permissions** → Role `Admin role`.

No Grafana: **Connections → Add new connection → Zabbix (Data Sources)**

- URL: `http://192.168.2.157:8080/api_jsonrpc.php`
- Zabbix connection: usuário `grafana` + senha
- Save & test

---

## Fase 9 — ArgoCD (em andamento)

**Onde:** `k8s-cp-01`.

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

Falta apontar para um repositório Git — ver
[`manifests/argocd/application.yaml`](../manifests/argocd/application.yaml).

---

## Checkpoints

Snapshots tirados nos dois hosts em cada marco. Restaurar leva segundos;
refazer leva horas.

```powershell
Get-VM | Checkpoint-VM -SnapshotName 'cluster-ok-limpo'
Get-VM | Checkpoint-VM -SnapshotName 'cluster-metallb-ingress'
Get-VM | Checkpoint-VM -SnapshotName 'fase7-observabilidade-ok'
Get-VM | Checkpoint-VM -SnapshotName 'fase6-zabbix-ok'
```
