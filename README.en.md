# SRE Lab

A seven-VM lab built from scratch on two Dell mini PCs to practice cluster
bootstrapping, layered monitoring, and chaos engineering.

Covers Kubernetes, two-layer observability (Prometheus + Zabbix), Ansible
automation, and — in progress — SLOs with error budgets, GitOps, and chaos
experiments.

Living documentation: what's here reflects what's actually running.

🇧🇷 [Documentação em português](README.md)

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

## Repository layout

```
.
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

- Understand the environment → [`docs/en/infrastructure.md`](docs/en/infrastructure.md)
- Rebuild from scratch → [`docs/en/installation.md`](docs/en/installation.md)
- Understand the *why* → [`docs/en/decisions.md`](docs/en/decisions.md)
- Something broke → [`docs/en/troubleshooting.md`](docs/en/troubleshooting.md)
