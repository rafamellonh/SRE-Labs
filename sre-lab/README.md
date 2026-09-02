# SRE Lab

Laboratório de estudo de SRE sobre dois mini PCs Dell com Hyper-V, cobrindo
Kubernetes, observabilidade em duas camadas (Prometheus + Zabbix), automação com
Ansible e — em construção — SLO com error budget, GitOps e engenharia de caos.

Documentação viva: o que está aqui reflete o que está de pé no ambiente.

🇬🇧 [English documentation](README.en.md)

## Estado atual

| # | Fase | Status |
|---|---|---|
| 0 | Preparar hosts Hyper-V | ✅ |
| 1 | Criar as 7 VMs | ✅ |
| 2 | Rede estática | ✅ |
| 3 | Ansible (nó de controle + inventory) | ✅ |
| 4 | Cluster Kubernetes (kubeadm + Calico) | ✅ |
| 5 | MetalLB + ingress-nginx | ✅ |
| 6 | Zabbix 7.0 + agentes + datasource Grafana | ✅ |
| 7 | kube-prometheus-stack | ✅ |
| 8 | App instrumentada + SLO | ⬜ |
| 9 | ArgoCD (GitOps) + experimentos de caos | 🚧 |

## Acesso rápido

| Serviço | Endereço | Credencial |
|---|---|---|
| Grafana | http://192.168.2.201 | `admin` / secret `kps-grafana` |
| Alertmanager | http://192.168.2.202:9093 | — |
| Zabbix | http://192.168.2.157:8080 | `Admin` / definida no setup |
| ArgoCD | https://192.168.2.203 | `admin` / secret `argocd-initial-admin-secret` |
| Kubernetes API | https://192.168.2.151:6443 | kubeconfig em `k8s-cp-01` |

```bash
# senha do Grafana
kubectl -n monitoring get secret kps-grafana -o jsonpath="{.data.admin-password}" | base64 -d; echo

# senha inicial do ArgoCD
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

## Estrutura do repositório

```
.
├── docs/                    Documentação de arquitetura e operação
│   ├── en/                  Versão em inglês
│   ├── infraestrutura.md    Mapa do ambiente, VMs, rede, dimensionamento
│   ├── instalacao.md        Passo a passo do que foi executado
│   ├── decisoes.md          Decisões técnicas e suas justificativas
│   └── troubleshooting.md   Problemas encontrados e como foram resolvidos
├── hyperv/                  Scripts PowerShell de provisionamento das VMs
├── ansible/                 Nó de controle: inventory, config e playbooks
├── manifests/               Manifests Kubernetes
│   ├── metallb/             IPAddressPool e L2Advertisement
│   ├── monitoring/          values.yaml do kube-prometheus-stack, regras de SLO
│   ├── apps/                Aplicações de demonstração
│   └── argocd/              Definições de Application (GitOps)
└── zabbix/                  docker-compose do stack Zabbix
```

## Por onde começar

- Entender o ambiente → [`docs/infraestrutura.md`](docs/infraestrutura.md)
- Reproduzir do zero → [`docs/instalacao.md`](docs/instalacao.md)
- Entender o *porquê* das escolhas → [`docs/decisoes.md`](docs/decisoes.md)
- Algo quebrou → [`docs/troubleshooting.md`](docs/troubleshooting.md)
