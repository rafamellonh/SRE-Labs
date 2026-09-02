# Infraestrutura

## Mapa do ambiente

```
                        Home LAN — 192.168.2.0/24 (gw .1)
                                      │
        ┌─────────────────────────────┴─────────────────────────────┐
        │                                                           │
┌───────┴────────────────────────┐              ┌───────────────────┴────────────┐
│  pc-01 — Dell mini PC, 32 GB   │              │  pc-02 — Dell mini PC, 16 GB   │
│  Windows + Hyper-V             │              │  Windows + Hyper-V             │
│  vSwitch-ext (bridge na LAN)   │              │  vSwitch-ext (bridge na LAN)   │
├────────────────────────────────┤              ├────────────────────────────────┤
│                                │              │                                │
│  k8s-worker-01     .152        │              │  k8s-cp-01         .151        │
│    Ubuntu 24.04 · 2 vCPU · 6GB │              │    Ubuntu 24.04 · 2 vCPU · 4GB │
│    worker do cluster           │              │    control plane, etcd         │
│                                │              │                                │
│  k8s-worker-02     .153        │              │  ansible-ctl       .156        │
│    Ubuntu 24.04 · 2 vCPU · 6GB │              │    CentOS Stream 9 · 2 vCPU·3GB│
│    worker do cluster           │              │    nó de controle Ansible      │
│                                │              │                                │
│  obs-01            .154        │              │  zbx-01            .157        │
│    Ubuntu 24.04 · 4 vCPU · 8GB │              │    Ubuntu 24.04 · 2 vCPU · 4GB │
│    (reservada, fora do cluster)│              │    Zabbix 7.0 + PostgreSQL 16  │
│                                │              │    via Docker Compose          │
│  svc-01            .155        │              │                                │
│    Ubuntu 24.04 · 2 vCPU · 4GB │              │                                │
│    (reservada, fora do cluster)│              │                                │
│                                │              │                                │
├────────────────────────────────┤              ├────────────────────────────────┤
│  24 GB alocados / ~8 GB livres │              │  11 GB alocados / ~5 GB livres │
└────────────────────────────────┘              └────────────────────────────────┘

MetalLB pool: 192.168.2.200–.220  →  ingress-nginx  →  Services do cluster

Camadas de observabilidade
  Zabbix   (pc-02) ──► hosts, SO, rede, PostgreSQL — 6 agentes
  Prometheus (cluster) ──► Kubernetes, pods, golden signals
  Grafana  (cluster) ──► ambos os datasources num painel só
```

## Inventário de VMs

| VM | SO | IP | Host | vCPU | RAM | Disco | Papel |
|---|---|---|---|---|---|---|---|
| k8s-cp-01 | Ubuntu Server 24.04 | 192.168.2.151 | pc-02 | 2 | 4 GB | 60 GB | Control plane |
| k8s-worker-01 | Ubuntu Server 24.04 | 192.168.2.152 | pc-01 | 2 | 6 GB | 60 GB | Worker |
| k8s-worker-02 | Ubuntu Server 24.04 | 192.168.2.153 | pc-01 | 2 | 6 GB | 60 GB | Worker |
| obs-01 | Ubuntu Server 24.04 | 192.168.2.154 | pc-01 | 4 | 8 GB | 120 GB | Reservada |
| svc-01 | Ubuntu Server 24.04 | 192.168.2.155 | pc-01 | 2 | 4 GB | 40 GB | Reservada |
| ansible-ctl | CentOS Stream 9 | 192.168.2.156 | pc-02 | 2 | 3 GB | 40 GB | Nó de controle Ansible |
| zbx-01 | Ubuntu Server 24.04 | 192.168.2.157 | pc-02 | 2 | 4 GB | 80 GB | Zabbix server |

> **`obs-01` e `svc-01`** foram provisionadas no plano original para hospedar,
> respectivamente, a stack de observabilidade e a aplicação de demonstração.
> Como o `kube-prometheus-stack` acabou rodando dentro do cluster, hoje elas
> estão de pé com agente Zabbix instalado, mas sem carga. Ver
> [`decisoes.md`](decisoes.md#obs-01-e-svc-01-fora-do-cluster).

## Redes

| Rede | CIDR | Observação |
|---|---|---|
| LAN | 192.168.2.0/24 | gateway `.1` |
| VMs | 192.168.2.151–.157 | estáticos, excluir do DHCP |
| MetalLB | 192.168.2.200–.220 | pool L2, excluir do DHCP |
| Pods (Calico) | 10.244.0.0/16 | interna do cluster |
| Services | 10.96.0.0/12 | padrão do kubeadm |
| Docker (zbx-01) | 172.16.0.0/12 | liberada no `Server=` do agente |

## IPs alocados pelo MetalLB

| Serviço | IP | Namespace |
|---|---|---|
| ingress-nginx-controller | 192.168.2.200 | `ingress-nginx` |
| kps-grafana | 192.168.2.201 | `monitoring` |
| kps-…-alertmanager | 192.168.2.202 | `monitoring` |
| argocd-server | 192.168.2.203 | `argocd` |

## Software instalado

### Cluster Kubernetes

| Componente | Versão | Instalado via |
|---|---|---|
| Kubernetes | v1.31.14 | kubeadm (repo pkgs.k8s.io) |
| containerd | do repo Ubuntu | apt |
| Calico | v3.28.0 | manifest oficial |
| MetalLB | v0.14.8 | manifest nativo |
| ingress-nginx | chart oficial | Helm |
| local-path-provisioner | v0.0.30 | manifest Rancher |
| kube-prometheus-stack | chart oficial | Helm (release `kps`) |
| ArgoCD | stable | manifest oficial |

### Fora do cluster

| Componente | Versão | Onde | Instalado via |
|---|---|---|---|
| Zabbix server + web | 7.0 (imagens ubuntu-latest) | zbx-01 | Docker Compose |
| PostgreSQL | 16-alpine | zbx-01 | Docker Compose |
| Zabbix Agent 2 | 7.0 | 6 VMs | Ansible |
| ansible-core | do repo CentOS | ansible-ctl | dnf |

## Zabbix — hosts monitorados

Cadastrados por auto-registro, template `Linux by Zabbix agent`:

| Host | Interface | Observação |
|---|---|---|
| k8s-cp-01 | 192.168.2.151:10050 | |
| k8s-worker-01 | 192.168.2.152:10050 | |
| k8s-worker-02 | 192.168.2.153:10050 | |
| obs-01 | 192.168.2.154:10050 | |
| svc-01 | 192.168.2.155:10050 | |
| Zabbix server | 192.168.2.157:10050 | host pré-definido, templates extras |
| ~~zbx-01~~ | 192.168.2.157:10050 | **desabilitado** — duplicata do auto-registro |

O `ansible-ctl` (192.168.2.156) ainda não é monitorado: ele é o nó de controle e
não está no inventory. Ver [`decisoes.md`](decisoes.md).

## Configurações de Hyper-V que importam

Ambas as VMs de cada host foram criadas com:

- **Generation 2** + `SecureBootTemplate MicrosoftUEFICertificateAuthority` —
  sem esse template, Linux não dá boot com Secure Boot ligado.
- **`-StaticMemory`** — Dynamic Memory interfere no cálculo de `allocatable` do
  kubelet e nas decisões de eviction.
- **`MacAddressSpoofing On`** — obrigatório. Sem isso o Hyper-V descarta frames
  cujo MAC de origem difere do da vNIC, quebrando o tráfego de pods (Calico) e o
  ARP gratuito do MetalLB.

```powershell
Get-VMNetworkAdapter -VMName * | Select-Object VMName, MacAddressSpoofing
```
