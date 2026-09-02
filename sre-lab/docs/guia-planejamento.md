# Lab SRE em Hyper-V — Guia Completo

Ambiente de estudo de SRE sobre 2 mini PCs Dell com Hyper-V, cobrindo Kubernetes,
observabilidade dupla (Prometheus + Zabbix), automação com Ansible/Terraform,
GitOps com ArgoCD e engenharia de caos.

- **Rede:** `192.168.2.0/24` — gateway `192.168.2.1`
- **Hosts:** `pc-01` (32 GB) e `pc-02` (16 GB)
- **Total de VMs:** 7

---

## 1. Mapa do ambiente

```
                  Home LAN — 192.168.2.0/24  (gw .1)
                              │
        ┌─────────────────────┴─────────────────────┐
        │                                           │
┌───────┴────────────────┐              ┌───────────┴────────────┐
│  pc-01  (32 GB)        │              │  pc-02  (16 GB)        │
│  Hyper-V + vSwitch-ext │              │  Hyper-V + vSwitch-ext │
├────────────────────────┤              ├────────────────────────┤
│ k8s-worker-01  .152    │              │ k8s-cp-01      .151    │
│   2 vCPU / 6 GB        │              │   2 vCPU / 4 GB        │
│ k8s-worker-02  .153    │              │ ansible-ctl    .156    │
│   2 vCPU / 6 GB        │              │   2 vCPU / 3 GB (CS9)  │
│ obs-01         .154    │              │ zbx-01         .157    │
│   4 vCPU / 8 GB        │              │   2 vCPU / 4 GB        │
│   Prom + Loki + Grafana│              │   Zabbix 7.0 + PgSQL   │
│ svc-01         .155    │              │                        │
│   2 vCPU / 4 GB        │              │                        │
├────────────────────────┤              ├────────────────────────┤
│ ~24 GB usados / 8 livre│              │ ~11 GB usados / 5 livre│
└────────────────────────┘              └────────────────────────┘

MetalLB pool: 192.168.2.200-.220  →  ingress-nginx  →  svc-01

Camadas de observabilidade:
  Zabbix  (pc-02) ──► hosts, SO, rede, PostgreSQL, hipervisores
  Prom    (pc-01) ──► Kubernetes, pods, golden signals da app
  Grafana (pc-01) ──► datasource Zabbix + datasource Prometheus
```

### Por que essa distribuição

O host de 32 GB carrega o que é pesado (workers + stack de observabilidade do
k8s). O de 16 GB fica com control plane, automação e Zabbix.

O ponto de design mais importante: **os dois stacks de monitoramento vivem em
hosts físicos diferentes.** Quando você derrubar o `pc-01` num teste de caos, o
Zabbix continua vivo no `pc-02` e te mostra o buraco. É o exercício de "quem
monitora o monitor" resolvido na topologia, não na teoria.

---

## 2. Plano de endereçamento

| VM | IP | Host | Papel | vCPU | RAM | Disco |
|---|---|---|---|---|---|---|
| k8s-cp-01 | 192.168.2.151 | pc-02 | control plane | 2 | 4 GB | 60 GB |
| k8s-worker-01 | 192.168.2.152 | pc-01 | worker | 2 | 6 GB | 60 GB |
| k8s-worker-02 | 192.168.2.153 | pc-01 | worker | 2 | 6 GB | 60 GB |
| obs-01 | 192.168.2.154 | pc-01 | Prometheus/Loki/Grafana | 4 | 8 GB | 120 GB |
| svc-01 | 192.168.2.155 | pc-01 | app + carga/caos | 2 | 4 GB | 40 GB |
| ansible-ctl | 192.168.2.156 | pc-02 | Ansible/Terraform (CentOS Stream 9) | 2 | 3 GB | 40 GB |
| zbx-01 | 192.168.2.157 | pc-02 | Zabbix server | 2 | 4 GB | 80 GB |
| MetalLB pool | 192.168.2.200-.220 | — | pool LoadBalancer | — | — | — |

### Redes internas (não colidem com a LAN)

| Rede | CIDR | Uso |
|---|---|---|
| Pods (Calico) | `10.244.0.0/16` | rede interna de pods |
| Services | `10.96.0.0/12` | ClusterIP padrão do kubeadm |

> **Antes de começar:** reserve ou exclua as faixas `.151`–`.157` e `.200`–`.220`
> no DHCP do roteador. Sem isso, ele pode entregar um desses IPs a outro
> dispositivo e você vai caçar conflito de IP no meio do lab.

---

## 3. Tabela de validação

Marque conforme avança. `Rede OK` = responde ping; `SSH OK` = `ansible -m ping`
passa; `Serviço OK` = o papel da VM está de fato funcionando.

| VM | IP | Host | Papel | Rede OK | SSH OK | Serviço OK |
|---|---|---|---|---|---|---|
| k8s-cp-01 | 192.168.2.151 | pc-02 | control plane | ☐ | ☐ | ☐ |
| k8s-worker-01 | 192.168.2.152 | pc-01 | worker | ☐ | ☐ | ☐ |
| k8s-worker-02 | 192.168.2.153 | pc-01 | worker | ☐ | ☐ | ☐ |
| obs-01 | 192.168.2.154 | pc-01 | Prometheus/Loki/Grafana | ☐ | ☐ | ☐ |
| svc-01 | 192.168.2.155 | pc-01 | app + carga/caos | ☐ | ☐ | ☐ |
| ansible-ctl | 192.168.2.156 | pc-02 | Ansible/Terraform (CentOS Stream 9) | ☐ | ☐ | ☐ |
| zbx-01 | 192.168.2.157 | pc-02 | Zabbix server | ☐ | ☐ | ☐ |
| MetalLB pool | 192.168.2.200-.220 | — | pool LoadBalancer | ☐ | — | ☐ |

### Comandos de validação

**Rede OK** — de qualquer VM:

```bash
for ip in 151 152 153 154 155 156 157; do
  ping -c1 -W1 192.168.2.$ip >/dev/null 2>&1 \
    && echo "192.168.2.$ip  OK" \
    || echo "192.168.2.$ip  FALHOU"
done
```

**SSH OK** — do `ansible-ctl`, após distribuir a chave:

```bash
ansible all -i inventory.yml -m ping
```

**Serviço OK** — por papel:

```bash
kubectl get nodes -o wide                       # cp + workers Ready
kubectl get svc -A | grep LoadBalancer          # MetalLB entregou IP do pool?
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.2.157:8080   # Zabbix → 200
kubectl -n monitoring get pods                  # Prometheus / Grafana
kubectl -n argocd get pods                      # ArgoCD
```

### Checklist de fases

| # | Fase | Entregável | OK |
|---|---|---|---|
| 0 | Preparar hosts Hyper-V | vSwitch-ext nos 2 hosts | ☐ |
| 1 | Criar VMs | 7 VMs criadas e bootando | ☐ |
| 2 | Rede estática | Todas as VMs pingáveis | ☐ |
| 3 | Baseline Ansible | `k8s-prereq.yml` sem falhas | ☐ |
| 4 | Subir o cluster | 3 nós `Ready` | ☐ |
| 5 | MetalLB + Ingress | Ingress com IP externo | ☐ |
| 6 | Zabbix | Frontend + agentes reportando | ☐ |
| 7 | Prometheus + Grafana | 2 datasources no Grafana | ☐ |
| 8 | App + SLO | Alertas de burn rate ativos | ☐ |
| 9 | GitOps + caos | ArgoCD sincronizando | ☐ |

---

## 4. Fase 0 — Preparar os hosts Hyper-V

Nos **dois** mini PCs, em PowerShell como administrador:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart

$nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
New-VMSwitch -Name 'vSwitch-ext' -NetAdapterName $nic.Name -AllowManagementOS $true

New-Item -ItemType Directory -Path 'D:\VMs','D:\ISO' -Force
```

Reinicie após habilitar o Hyper-V. Baixe para `D:\ISO`:

- `ubuntu-24.04-live-server-amd64.iso` (5 VMs)
- `CentOS-Stream-9-latest-x86_64-dvd1.iso` (para o `ansible-ctl` — download livre,
  sem cadastro, em https://www.centos.org/download/)

**Por que CentOS Stream 9 no `ansible-ctl`:** é o único nó fora do Ubuntu, de
propósito — é onde você pratica `dnf`, `firewalld`, SELinux, `nmcli` e system
roles, o ecossistema Red Hat que cai no EX294, sem misturar com os nós do
cluster. O Stream é upstream do RHEL (recebe mudanças antes), então
eventualmente algum pacote estará à frente da versão do RHEL 9 — na prática isso
raramente afeta os tópicos da certificação, mas é bom saber. Em troca você fica
perto da comunidade CentOS e do processo de construção do RHEL.

**Por que vSwitch External** e não interno: as VMs dos dois hosts se enxergam
nativamente na LAN e têm internet para baixar pacotes, sem precisar de uma VM
roteadora no meio.

---

## 5. Fase 1 — Criar as VMs

### pc-01

```powershell
$iso = 'D:\ISO\ubuntu-24.04-live-server-amd64.iso'
$vms = @(
    @{ Name='k8s-worker-01'; CPU=2; RAM=6GB;  Disk=60GB }
    @{ Name='k8s-worker-02'; CPU=2; RAM=6GB;  Disk=60GB }
    @{ Name='obs-01';        CPU=4; RAM=8GB;  Disk=120GB }
    @{ Name='svc-01';        CPU=2; RAM=4GB;  Disk=40GB }
)

foreach ($v in $vms) {
    $vhd = "D:\VMs\$($v.Name)\$($v.Name).vhdx"
    New-VM -Name $v.Name -Generation 2 -MemoryStartupBytes $v.RAM `
           -NewVHDPath $vhd -NewVHDSizeBytes $v.Disk -SwitchName 'vSwitch-ext'
    Set-VM -Name $v.Name -ProcessorCount $v.CPU -StaticMemory `
           -AutomaticStartAction Start -AutomaticStopAction Save
    Set-VMFirmware -VMName $v.Name -SecureBootTemplate MicrosoftUEFICertificateAuthority
    Add-VMDvdDrive -VMName $v.Name -Path $iso
    Set-VMFirmware -VMName $v.Name -FirstBootDevice (Get-VMDvdDrive -VMName $v.Name)
    Set-VMNetworkAdapter -VMName $v.Name -MacAddressSpoofing On
    Start-VM -Name $v.Name
}
```

### pc-02

Mesmo bloco, trocando apenas a lista:

```powershell
$vms = @(
    @{ Name='k8s-cp-01';   CPU=2; RAM=4GB; Disk=60GB }
    @{ Name='ansible-ctl'; CPU=2; RAM=3GB; Disk=40GB }
    @{ Name='zbx-01';      CPU=2; RAM=4GB; Disk=80GB }
)
```

> **Gotcha crítico:** `MacAddressSpoofing On` não é opcional. Sem ele o Hyper-V
> descarta silenciosamente frames cujo MAC de origem difere do da vNIC — e aí o
> tráfego de pods (Calico) e o ARP gratuito do MetalLB simplesmente não
> funcionam. É o erro que mais trava lab de Kubernetes em Hyper-V.

Outros detalhes que importam:

- **Generation 2 + SecureBootTemplate MicrosoftUEFICertificateAuthority** —
  sem esse template, Linux não dá boot com Secure Boot ligado.
- **StaticMemory** — Dynamic Memory atrapalha o kubelet, que lê a RAM total
  para calcular `allocatable` e faz decisões de eviction sobre ela.

---

## 6. Fase 2 — Rede estática

Em cada VM Ubuntu, `/etc/netplan/00-lab.yaml` (ajuste `addresses` conforme a
tabela da seção 2):

```yaml
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      addresses: [192.168.2.152/24]   # k8s-worker-01
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

Confirme o nome da interface com `ip a` — em algumas VMs vem como `eth0`, em
outras `enp0s3`.

No `ansible-ctl` (CentOS Stream 9), não há netplan — use `nmcli`:

```bash
sudo nmcli con mod 'System eth0' \
  ipv4.addresses 192.168.2.156/24 \
  ipv4.gateway 192.168.2.1 \
  ipv4.dns "192.168.2.1,1.1.1.1" \
  ipv4.method manual
sudo nmcli con up 'System eth0'
```

### /etc/hosts

Em todas as VMs, para resolução consistente:

```
192.168.2.151  k8s-cp-01
192.168.2.152  k8s-worker-01
192.168.2.153  k8s-worker-02
192.168.2.154  obs-01
192.168.2.155  svc-01
192.168.2.156  ansible-ctl
192.168.2.157  zbx-01
```

---

## 7. Fase 3 — Baseline com Ansible

No `ansible-ctl`: instale o Ansible, gere uma chave SSH e distribua com
`ssh-copy-id` para as 6 outras VMs.

### inventory.yml

```yaml
all:
  vars:
    ansible_user: rafael
    ansible_python_interpreter: /usr/bin/python3
  children:
    k8s_control_plane:
      hosts:
        k8s-cp-01: { ansible_host: 192.168.2.151 }
    k8s_workers:
      hosts:
        k8s-worker-01: { ansible_host: 192.168.2.152 }
        k8s-worker-02: { ansible_host: 192.168.2.153 }
    k8s_cluster:
      children:
        k8s_control_plane:
        k8s_workers:
    observability:
      hosts:
        obs-01: { ansible_host: 192.168.2.154 }
        zbx-01: { ansible_host: 192.168.2.157 }
    apps:
      hosts:
        svc-01: { ansible_host: 192.168.2.155 }
```

### playbooks/k8s-prereq.yml

```yaml
- name: Preparar nós Kubernetes
  hosts: k8s_cluster
  become: true
  tasks:
    - name: Desabilitar swap em runtime
      command: swapoff -a
      when: ansible_swaptotal_mb > 0

    - name: Remover swap do fstab
      replace:
        path: /etc/fstab
        regexp: '^([^#].*\sswap\s.*)$'
        replace: '# \1'

    - name: Carregar módulos de kernel
      copy:
        dest: /etc/modules-load.d/k8s.conf
        content: |
          overlay
          br_netfilter

    - name: Ativar módulos agora
      modprobe:
        name: "{{ item }}"
      loop: [overlay, br_netfilter]

    - name: Parâmetros sysctl
      copy:
        dest: /etc/sysctl.d/k8s.conf
        content: |
          net.bridge.bridge-nf-call-iptables  = 1
          net.bridge.bridge-nf-call-ip6tables = 1
          net.ipv4.ip_forward                 = 1
      notify: reload sysctl

    - name: Instalar containerd
      apt:
        name: containerd
        state: present
        update_cache: true

    - name: Gerar config do containerd
      shell: containerd config default > /etc/containerd/config.toml
      args:
        creates: /etc/containerd/config.toml

    - name: Ativar SystemdCgroup
      lineinfile:
        path: /etc/containerd/config.toml
        regexp: '^(\s*)SystemdCgroup\s*='
        line: '            SystemdCgroup = true'
      notify: restart containerd

    - name: Criar diretório de keyrings
      file:
        path: /etc/apt/keyrings
        state: directory
        mode: '0755'

    - name: Chave do repositório Kubernetes
      get_url:
        url: https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key
        dest: /etc/apt/keyrings/k8s.asc

    - name: Repositório Kubernetes
      apt_repository:
        repo: "deb [signed-by=/etc/apt/keyrings/k8s.asc] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /"
        filename: kubernetes

    - name: Instalar kubeadm, kubelet, kubectl
      apt:
        name: [kubelet, kubeadm, kubectl]
        state: present
        update_cache: true

    - name: Fixar versões
      dpkg_selections:
        name: "{{ item }}"
        selection: hold
      loop: [kubelet, kubeadm, kubectl]

  handlers:
    - name: reload sysctl
      command: sysctl --system

    - name: restart containerd
      systemd:
        name: containerd
        state: restarted
        enabled: true
```

**O que cada bloco resolve:**

- **swap off** — o kubelet se recusa a subir com swap ativo (a menos que você
  force, o que atrapalha as decisões de eviction).
- **br_netfilter + sysctl** — sem isso o tráfego entre pods na bridge não passa
  pelas regras de iptables, e o Service ClusterIP não funciona.
- **SystemdCgroup = true** — kubelet e containerd precisam usar o *mesmo* cgroup
  driver. Divergência aqui causa nós instáveis que ficam `NotReady` de forma
  intermitente. É a causa raiz mais comum de cluster kubeadm quebrado.
- **dpkg hold** — evita que um `apt upgrade` atualize o kubelet sozinho e quebre
  a compatibilidade de versão com o control plane.

Execução:

```bash
ansible-playbook -i inventory.yml playbooks/k8s-prereq.yml
```

---

## 8. Fase 4 — Subir o cluster

No `k8s-cp-01`:

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=192.168.2.151

mkdir -p ~/.kube
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config

kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
```

Nos dois workers, rode o `kubeadm join ...` que o `init` imprimiu. Se perdeu o
comando:

```bash
kubeadm token create --print-join-command
```

Validação:

```bash
kubectl get nodes -o wide          # 3 nós, todos Ready
kubectl get pods -n kube-system    # calico-node Running em todos
```

Os nós ficam `NotReady` até o Calico subir — isso é esperado, não é erro.

---

## 9. Fase 5 — MetalLB + Ingress

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml
kubectl -n metallb-system wait --for=condition=ready pod --all --timeout=180s
```

### metallb-pool.yaml

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lab-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.2.200-192.168.2.220
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - lab-pool
```

### ingress-nginx

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace
```

Validação:

```bash
kubectl -n ingress-nginx get svc     # EXTERNAL-IP deve vir do pool .200-.220
```

> Se o `EXTERNAL-IP` ficar eternamente em `<pending>`, o suspeito número um é o
> `MacAddressSpoofing` no Hyper-V. O modo L2 do MetalLB depende de ARP gratuito
> com MAC próprio; sem o spoofing habilitado, o host descarta esses frames.

---

## 10. Fase 6 — Zabbix

Instale Docker e Compose no `zbx-01`.

### docker-compose.yml

```yaml
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: zabbix
      POSTGRES_USER: zabbix
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql/data
    restart: unless-stopped

  zabbix-server:
    image: zabbix/zabbix-server-pgsql:7.0-ubuntu-latest
    environment:
      DB_SERVER_HOST: postgres
      POSTGRES_DB: zabbix
      POSTGRES_USER: zabbix
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    ports:
      - "10051:10051"
    depends_on:
      - postgres
    restart: unless-stopped

  zabbix-web:
    image: zabbix/zabbix-web-nginx-pgsql:7.0-ubuntu-latest
    environment:
      ZBX_SERVER_HOST: zabbix-server
      DB_SERVER_HOST: postgres
      POSTGRES_DB: zabbix
      POSTGRES_USER: zabbix
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      PHP_TZ: America/Toronto
    ports:
      - "8080:8080"
    depends_on:
      - zabbix-server
    restart: unless-stopped

volumes:
  pgdata:
```

Crie um `.env` ao lado com `DB_PASSWORD=<senha forte>` e suba com
`docker compose up -d`.

Frontend: `http://192.168.2.157:8080` — login inicial `Admin` / `zabbix`
(**troque imediatamente**).

### playbooks/zabbix-agent.yml

Instala o agente em toda a frota, cobrindo Debian e RedHat family:

```yaml
- name: Instalar Zabbix Agent 2
  hosts: all
  become: true
  vars:
    zabbix_server: 192.168.2.157
  tasks:
    - name: Repositório Zabbix (Debian family)
      apt:
        deb: https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_7.0-2+ubuntu24.04_all.deb
      when: ansible_os_family == 'Debian'

    - name: Repositório Zabbix (RedHat family)
      dnf:
        name: https://repo.zabbix.com/zabbix/7.0/rhel/9/x86_64/zabbix-release-7.0-2.el9.noarch.rpm
        disable_gpg_check: true
      when: ansible_os_family == 'RedHat'
      # O repo el9 atende CentOS Stream 9, Rocky 9 e Alma 9 — todos reportam
      # ansible_os_family == 'RedHat', então a task não muda.

    - name: Instalar agente
      package:
        name: zabbix-agent2
        state: present
        update_cache: true

    - name: Configurar agente
      template:
        src: zabbix_agent2.conf.j2
        dest: /etc/zabbix/zabbix_agent2.conf
        mode: '0644'
      notify: restart agent

    - name: Habilitar serviço
      systemd:
        name: zabbix-agent2
        state: started
        enabled: true

  handlers:
    - name: restart agent
      systemd:
        name: zabbix-agent2
        state: restarted
```

### templates/zabbix_agent2.conf.j2

```
Server={{ zabbix_server }}
ServerActive={{ zabbix_server }}
Hostname={{ inventory_hostname }}
LogFile=/var/log/zabbix/zabbix_agent2.log
```

Depois, no frontend: crie os 7 hosts, vincule o template *Linux by Zabbix agent*
e confirme que o ícone `ZBX` fica verde.

**Valor de mercado:** Zabbix cobre a camada que o Prometheus não cobre bem —
infra clássica, SNMP, rede, appliances, on-prem. Domina vagas de infra/NOC/SRE
em LATAM, telecom e MSPs. Prometheus domina cloud-native. Saber os dois é uma
combinação rara e procurada.

---

## 11. Fase 7 — Prometheus + Grafana

No cluster (a partir do `k8s-cp-01`):

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kps prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace -f values.yaml
```

### values.yaml

```yaml
grafana:
  service:
    type: LoadBalancer
  adminPassword: ${GRAFANA_PASSWORD}
  plugins:
    - alexanderzobnin-zabbix-app
  additionalDataSources:
    - name: Zabbix
      type: alexanderzobnin-zabbix-datasource
      url: http://192.168.2.157:8080/api_jsonrpc.php
      jsonData:
        username: Admin
        trends: true

prometheus:
  prometheusSpec:
    retention: 15d
    serviceMonitorSelectorNilUsesHelmValues: false
    storageSpec:
      volumeClaimTemplate:
        spec:
          resources:
            requests:
              storage: 30Gi

alertmanager:
  service:
    type: LoadBalancer
```

Dois detalhes que importam:

- **`serviceMonitorSelectorNilUsesHelmValues: false`** — sem isso o Prometheus
  só descobre ServiceMonitors com o label do release do Helm, e seus
  ServiceMonitors próprios são ignorados em silêncio.
- **`plugins` + `additionalDataSources`** — é o que junta as duas camadas num
  Grafana só: infra pelo Zabbix, aplicação pelo Prometheus.

---

## 12. Fase 8 — App instrumentada + SLO

### svc-01-deploy.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: svc-demo
  namespace: apps
spec:
  replicas: 3
  selector:
    matchLabels:
      app: svc-demo
  template:
    metadata:
      labels:
        app: svc-demo
    spec:
      containers:
        - name: app
          image: ghcr.io/nginxinc/nginx-prometheus-exporter:1.3.0
          ports:
            - { name: http, containerPort: 8080 }
            - { name: metrics, containerPort: 9113 }
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 256Mi }
          readinessProbe:
            httpGet: { path: /healthz, port: http }
            initialDelaySeconds: 5
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            initialDelaySeconds: 15
---
apiVersion: v1
kind: Service
metadata:
  name: svc-demo
  namespace: apps
  labels:
    app: svc-demo
spec:
  selector:
    app: svc-demo
  ports:
    - { name: http, port: 80, targetPort: http }
    - { name: metrics, port: 9113, targetPort: metrics }
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: svc-demo
  namespace: apps
  labels:
    release: kps
spec:
  selector:
    matchLabels:
      app: svc-demo
  endpoints:
    - port: metrics
      interval: 15s
```

### slo-rules.yaml

SLO de 99% de disponibilidade, com alertas de burn rate multi-janela:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: svc-demo-slo
  namespace: monitoring
  labels:
    release: kps
spec:
  groups:
    - name: svc-demo.slo
      rules:
        - record: svc_demo:error_ratio:rate5m
          expr: |
            sum(rate(http_requests_total{job="svc-demo",code=~"5.."}[5m]))
            / sum(rate(http_requests_total{job="svc-demo"}[5m]))

        - record: svc_demo:error_ratio:rate1h
          expr: |
            sum(rate(http_requests_total{job="svc-demo",code=~"5.."}[1h]))
            / sum(rate(http_requests_total{job="svc-demo"}[1h]))

        - alert: SvcDemoBurnRateFast
          expr: |
            svc_demo:error_ratio:rate5m > (14.4 * 0.01)
            and svc_demo:error_ratio:rate1h > (14.4 * 0.01)
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Error budget queimando rápido — exaustão em ~2 dias"

        - alert: SvcDemoBurnRateSlow
          expr: |
            svc_demo:error_ratio:rate1h > (6 * 0.01)
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Error budget queimando acima do previsto"
```

**O conceito, que é o coração do lab:** os multiplicadores 14.4 e 6 vêm do
capítulo de alerting do *SRE Workbook* do Google. Eles alertam sobre a
*velocidade de consumo do orçamento de erro*, não sobre picos isolados. Com um
SLO de 99% (orçamento de 1%), queimar a 14.4× significa esgotar o orçamento
mensal em ~2 dias — aí sim vale acordar alguém.

A condição de duas janelas (5m **e** 1h) existe para evitar alerta por ruído
momentâneo: o problema precisa ser rápido *e* sustentado. É exatamente o que
separa alerta de SRE de alerta de NOC.

---

## 13. Fase 9 — GitOps e caos

### ArgoCD

```bash
kubectl create ns argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# senha inicial
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

### argocd-app.yaml

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: lab-apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<seu-usuario>/sre-lab-manifests
    targetRevision: main
    path: apps
  destination:
    server: https://kubernetes.default.svc
    namespace: apps
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Com `selfHeal: true`, mudanças manuais via `kubectl` são revertidas
automaticamente — um exercício de disciplina GitOps por si só.

### Experimentos de caos

Em ordem crescente de dificuldade:

| # | Experimento | Comando / ferramenta | O que observar |
|---|---|---|---|
| 1 | Matar pods em loop | `kubectl delete pod -l app=svc-demo` | readiness probe segurando tráfego; zero erro no SLO |
| 2 | Carga até estourar latência | `k6` ou `hey` contra o ingress | burn rate acendendo no Alertmanager |
| 3 | Saturar CPU de um worker | `stress-ng --cpu 4` | saturação no Zabbix e Prometheus lado a lado |
| 4 | Derrubar um worker | `Stop-VM k8s-worker-01` | rescheduling de pods; Zabbix reportando host down |
| 5 | Desligar o `pc-01` inteiro | desligar o host | cp sobrevive no pc-02, Zabbix vivo, cluster sem workers |

O experimento 5 é o mais rico do lab: exercita failover, monitoramento
independente e recuperação — os três pilares práticos de SRE.

Para cada experimento, escreva um **postmortem sem culpados**: o que aconteceu,
como você detectou, quanto tempo levou para detectar (MTTD), quanto para
recuperar (MTTR), e o que mudaria. É o artefato que mais rende em entrevista.

---

## 14. Ordem recomendada de execução

Uma opinião franca sobre ritmo: **não tente rodar as 10 fases de uma vez.**

- **Fim de semana 1** — Fases 0 a 4. Já é bastante coisa, e é o alicerce.
- **Fim de semana 2** — Fases 5 e 6 (MetalLB, Ingress, Zabbix).
- **Fim de semana 3** — Fases 7 e 8 (Prometheus, Grafana, SLO).
- **Depois** — Fase 9, com calma, um experimento de caos por vez.

O valor de aprendizado cai muito se você só copiar e colar. Depois de cada fase,
rode os comandos de validação e só avance com tudo verde.

---

## 15. Referência rápida

| Serviço | Endereço |
|---|---|
| Zabbix frontend | `http://192.168.2.157:8080` |
| Grafana | IP do pool MetalLB, porta 80 |
| Alertmanager | IP do pool MetalLB, porta 9093 |
| ArgoCD | `kubectl -n argocd port-forward svc/argocd-server 8443:443` |
| Kubernetes API | `https://192.168.2.151:6443` |

### Troubleshooting dos erros mais comuns

| Sintoma | Causa provável |
|---|---|
| MetalLB `EXTERNAL-IP` em `<pending>` | `MacAddressSpoofing` desligado no Hyper-V |
| Nó `NotReady` intermitente | divergência de cgroup driver (`SystemdCgroup`) |
| kubelet não sobe | swap ainda ativo |
| Pods não se comunicam | `br_netfilter` não carregado / sysctl faltando |
| ServiceMonitor ignorado | `serviceMonitorSelectorNilUsesHelmValues` não está `false` |
| VM não dá boot | Secure Boot sem o template UEFI da Microsoft |
| Conflito de IP | faixa não excluída do DHCP do roteador |
