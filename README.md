# SRE Labs

A seven-VM lab built from scratch on two Dell mini PCs to practice cluster
bootstrapping, layered monitoring, and chaos engineering.

Covers Kubernetes, two-layer observability (Prometheus + Zabbix), Ansible
automation, and — in progress — SLOs with error budgets, GitOps, and chaos
experiments.

Living documentation: what's here reflects what's actually running.

## Current state

| # | Phase | Status |
|---|---|---|
| 0 | Prepare Hyper-V hosts | ✅ |
| 1 | Create the 7 VMs | ✅ |
| 2 | Static networking | ✅ |
| 3 | Ansible (control node + inventory) | ✅ |
| 4 | Kubernetes cluster (kubeadm + Calico) | ✅ |
| 5 | MetalLB + ingress-nginx | ✅ |
| 6 | Zabbix 7.0 + agents + Grafana datasource | ✅ |
| 7 | kube-prometheus-stack | ✅ |
| 8 | Instrumented app + SLO | ⬜ |
| 9 | ArgoCD (GitOps) + chaos experiments | 🚧 |

## Quick access

| Service | Address | Credential |
|---|---|---|
| Grafana | http://192.168.2.201 | `admin` / secret `kps-grafana` |
| Alertmanager | http://192.168.2.202:9093 | — |
| Zabbix | http://192.168.2.157:8080 | `Admin` / set during setup |
| ArgoCD | https://192.168.2.203 | `admin` / secret `argocd-initial-admin-secret` |
| Kubernetes API | https://192.168.2.151:6443 | kubeconfig on `k8s-cp-01` |

```bash
# Grafana password
kubectl -n monitoring get secret kps-grafana -o jsonpath="{.data.admin-password}" | base64 -d; echo

# ArgoCD initial password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

## Architecture

```
                        Home LAN — 192.168.2.0/24 (gw .1)
                                      │
        ┌─────────────────────────────┴─────────────────────────────┐
┌───────┴────────────────────────┐              ┌───────────────────┴────────────┐
│  pc-01 — Dell mini PC, 32 GB   │              │  pc-02 — Dell mini PC, 16 GB   │
├────────────────────────────────┤              ├────────────────────────────────┤
│  k8s-worker-01     .152        │              │  k8s-cp-01         .151        │
│  k8s-worker-02     .153        │              │  ansible-ctl       .156        │
│  obs-01            .154        │              │  zbx-01            .157        │
│  svc-01            .155        │              │                                │
└────────────────────────────────┘              └────────────────────────────────┘

MetalLB pool: 192.168.2.200–.220  →  ingress-nginx  →  cluster Services
```

The two monitoring stacks live on **separate physical hosts** by design: when
`pc-01` goes down during a chaos experiment, Zabbix on `pc-02` stays alive and
reports the outage.

## Repository layout

```
sre-lab/
├── docs/                    Architecture and operations documentation
│   ├── en/                  English version
│   ├── infraestrutura.md    Environment map, VMs, networking, sizing
│   ├── instalacao.md        Step-by-step of what was executed
│   ├── decisoes.md          Technical decisions and their rationale
│   └── troubleshooting.md   Problems hit and how they were solved
├── hyperv/                  PowerShell provisioning scripts
├── ansible/                 Control node: inventory, config, playbooks
├── manifests/               Kubernetes manifests
│   ├── metallb/             IPAddressPool and L2Advertisement
│   ├── monitoring/          kube-prometheus-stack values, SLO rules
│   ├── apps/                Demo applications
│   └── argocd/              Application definitions (GitOps)
└── zabbix/                  Zabbix stack docker-compose
```

## Where to start

- Understand the environment → [`sre-lab/docs/en/infrastructure.md`](sre-lab/docs/en/infrastructure.md)
- Rebuild from scratch → [`sre-lab/docs/en/installation.md`](sre-lab/docs/en/installation.md)
- Understand the *why* → [`sre-lab/docs/en/decisions.md`](sre-lab/docs/en/decisions.md)
- Something broke → [`sre-lab/docs/en/troubleshooting.md`](sre-lab/docs/en/troubleshooting.md)

## Stack

| Layer | Components |
|---|---|
| Hypervisor | Hyper-V on Windows, external vSwitch |
| OS | Ubuntu Server 24.04, CentOS Stream 9 |
| Kubernetes | kubeadm v1.31, Calico, MetalLB, ingress-nginx, local-path-provisioner |
| Observability | kube-prometheus-stack, Grafana, Zabbix 7.0 + PostgreSQL 16 |
| Automation | Ansible (ansible-core), ArgoCD |
