# Infrastructure

## Environment map

```
                        Home LAN — 192.168.2.0/24 (gw .1)
                                      │
        ┌─────────────────────────────┴─────────────────────────────┐
        │                                                           │
┌───────┴────────────────────────┐              ┌───────────────────┴────────────┐
│  pc-01 — Dell mini PC, 32 GB   │              │  pc-02 — Dell mini PC, 16 GB   │
│  Windows + Hyper-V             │              │  Windows + Hyper-V             │
│  vSwitch-ext (bridged to LAN)  │              │  vSwitch-ext (bridged to LAN)  │
├────────────────────────────────┤              ├────────────────────────────────┤
│                                │              │                                │
│  k8s-worker-01     .152        │              │  k8s-cp-01         .151        │
│    Ubuntu 24.04 · 2 vCPU · 6GB │              │    Ubuntu 24.04 · 2 vCPU · 4GB │
│    cluster worker              │              │    control plane, etcd         │
│                                │              │                                │
│  k8s-worker-02     .153        │              │  ansible-ctl       .156        │
│    Ubuntu 24.04 · 2 vCPU · 6GB │              │    CentOS Stream 9 · 2 vCPU·3GB│
│    cluster worker              │              │    Ansible control node        │
│                                │              │                                │
│  obs-01            .154        │              │  zbx-01            .157        │
│    Ubuntu 24.04 · 4 vCPU · 8GB │              │    Ubuntu 24.04 · 2 vCPU · 4GB │
│    (spare, outside cluster)    │              │    Zabbix 7.0 + PostgreSQL 16  │
│                                │              │    via Docker Compose          │
│  svc-01            .155        │              │                                │
│    Ubuntu 24.04 · 2 vCPU · 4GB │              │                                │
│    (spare, outside cluster)    │              │                                │
│                                │              │                                │
├────────────────────────────────┤              ├────────────────────────────────┤
│  24 GB allocated / ~8 GB free  │              │  11 GB allocated / ~5 GB free  │
└────────────────────────────────┘              └────────────────────────────────┘

MetalLB pool: 192.168.2.200–.220  →  ingress-nginx  →  cluster Services

Observability layers
  Zabbix     (pc-02)   ──► hosts, OS, network, PostgreSQL — 6 agents
  Prometheus (cluster) ──► Kubernetes, pods, golden signals
  Grafana    (cluster) ──► both datasources in a single pane
```

## VM inventory

| VM | OS | IP | Host | vCPU | RAM | Disk | Role |
|---|---|---|---|---|---|---|---|
| k8s-cp-01 | Ubuntu Server 24.04 | 192.168.2.151 | pc-02 | 2 | 4 GB | 60 GB | Control plane |
| k8s-worker-01 | Ubuntu Server 24.04 | 192.168.2.152 | pc-01 | 2 | 6 GB | 60 GB | Worker |
| k8s-worker-02 | Ubuntu Server 24.04 | 192.168.2.153 | pc-01 | 2 | 6 GB | 60 GB | Worker |
| obs-01 | Ubuntu Server 24.04 | 192.168.2.154 | pc-01 | 4 | 8 GB | 120 GB | Spare |
| svc-01 | Ubuntu Server 24.04 | 192.168.2.155 | pc-01 | 2 | 4 GB | 40 GB | Spare |
| ansible-ctl | CentOS Stream 9 | 192.168.2.156 | pc-02 | 2 | 3 GB | 40 GB | Ansible control node |
| zbx-01 | Ubuntu Server 24.04 | 192.168.2.157 | pc-02 | 2 | 4 GB | 80 GB | Zabbix server |

> **`obs-01` and `svc-01`** were provisioned in the original plan to host the
> observability stack and the demo application respectively. Since
> `kube-prometheus-stack` ended up running inside the cluster, they're currently
> up with a Zabbix agent installed but carrying no workload. See
> [`decisions.md`](decisions.md#obs-01-and-svc-01-outside-the-cluster).

## Networks

| Network | CIDR | Note |
|---|---|---|
| LAN | 192.168.2.0/24 | gateway `.1` |
| VMs | 192.168.2.151–.157 | static, exclude from DHCP |
| MetalLB | 192.168.2.200–.220 | L2 pool, exclude from DHCP |
| Pods (Calico) | 10.244.0.0/16 | cluster-internal |
| Services | 10.96.0.0/12 | kubeadm default |
| Docker (zbx-01) | 172.16.0.0/12 | allowed in the agent's `Server=` |

## IPs allocated by MetalLB

| Service | IP | Namespace |
|---|---|---|
| ingress-nginx-controller | 192.168.2.200 | `ingress-nginx` |
| kps-grafana | 192.168.2.201 | `monitoring` |
| kps-…-alertmanager | 192.168.2.202 | `monitoring` |
| argocd-server | 192.168.2.203 | `argocd` |

## Installed software

### Kubernetes cluster

| Component | Version | Installed via |
|---|---|---|
| Kubernetes | v1.31.14 | kubeadm (pkgs.k8s.io repo) |
| containerd | Ubuntu repo | apt |
| Calico | v3.28.0 | official manifest |
| MetalLB | v0.14.8 | native manifest |
| ingress-nginx | official chart | Helm |
| local-path-provisioner | v0.0.30 | Rancher manifest |
| kube-prometheus-stack | official chart | Helm (release `kps`) |
| ArgoCD | stable | official manifest |

### Outside the cluster

| Component | Version | Where | Installed via |
|---|---|---|---|
| Zabbix server + web | 7.0 (ubuntu-latest images) | zbx-01 | Docker Compose |
| PostgreSQL | 16-alpine | zbx-01 | Docker Compose |
| Zabbix Agent 2 | 7.0 | 6 VMs | Ansible |
| ansible-core | CentOS repo | ansible-ctl | dnf |

## Zabbix — monitored hosts

Registered via autoregistration, template `Linux by Zabbix agent`:

| Host | Interface | Note |
|---|---|---|
| k8s-cp-01 | 192.168.2.151:10050 | |
| k8s-worker-01 | 192.168.2.152:10050 | |
| k8s-worker-02 | 192.168.2.153:10050 | |
| obs-01 | 192.168.2.154:10050 | |
| svc-01 | 192.168.2.155:10050 | |
| Zabbix server | 192.168.2.157:10050 | built-in host, extra templates |
| ~~zbx-01~~ | 192.168.2.157:10050 | **disabled** — autoregistration duplicate |

`ansible-ctl` (192.168.2.156) isn't monitored yet: it's the control node and
isn't in the inventory. See [`decisions.md`](decisions.md).

## Hyper-V settings that matter

Every VM on both hosts was created with:

- **Generation 2** + `SecureBootTemplate MicrosoftUEFICertificateAuthority` —
  without this template, Linux won't boot with Secure Boot enabled.
- **`-StaticMemory`** — Dynamic Memory interferes with how the kubelet computes
  `allocatable` and makes eviction decisions.
- **`MacAddressSpoofing On`** — mandatory. Without it, Hyper-V silently drops
  frames whose source MAC differs from the vNIC's, breaking pod traffic (Calico)
  and MetalLB's gratuitous ARP.

```powershell
Get-VMNetworkAdapter -VMName * | Select-Object VMName, MacAddressSpoofing
```
