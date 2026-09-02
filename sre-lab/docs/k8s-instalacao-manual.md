# Instalação Manual do Cluster Kubernetes — Lab SRE

Tutorial adaptado para a infraestrutura do lab: rede `192.168.2.0/24`,
Kubernetes v1.31, CNI Calico, sobre Hyper-V.

## Máquinas envolvidas

| Papel | Hostname | IP | Host físico |
|---|---|---|---|
| 👑 Control plane | `k8s-cp-01` | 192.168.2.151 | pc-02 |
| ⚙️ Worker | `k8s-worker-01` | 192.168.2.152 | pc-01 |
| ⚙️ Worker | `k8s-worker-02` | 192.168.2.153 | pc-01 |

> **Antes de começar — checagem no Hyper-V.** Confirme nos dois hosts que o MAC
> spoofing está ligado nas VMs do cluster. Sem isso o tráfego entre pods de
> hosts diferentes não passa, e o sintoma parece problema de CNI.
>
> ```powershell
> Get-VMNetworkAdapter -VMName * | Select-Object VMName, MacAddressSpoofing
> # Se algum estiver Off:
> Set-VMNetworkAdapter -VMName k8s-worker-01 -MacAddressSpoofing On
> ```

---

# PARTE 1 — Configuração Inicial (TODAS as máquinas)

🖥️ **[CP + WORKERS]** — Execute os passos abaixo nas três VMs.

## 1.1 — Atualizar o sistema

```bash
sudo apt update && sudo apt upgrade -y
```

## 1.2 — Configurar o /etc/hosts

Permite comunicação por hostname, não só por IP.

```bash
sudo nano /etc/hosts
```

Adicione as linhas abaixo (inclui as VMs de observabilidade, úteis mais tarde):

```
192.168.2.151  k8s-cp-01
192.168.2.152  k8s-worker-01
192.168.2.153  k8s-worker-02
192.168.2.154  obs-01
192.168.2.155  svc-01
192.168.2.156  ansible-ctl
192.168.2.157  zbx-01
```

## 1.3 — Desativar o Swap

O kubelet se recusa a iniciar com swap ativo.

**Passo 1 — desativar agora:**

```bash
sudo swapoff -a
```

**Passo 2 — desativar permanentemente:**

```bash
sudo nano /etc/fstab
```

Localize a linha que contém `swap` — costuma ser uma destas:

```
/swap.img   none   swap   sw   0   0
UUID=xxxx   none   swap   sw   0   0
```

Comente com `#` no início:

```
# /swap.img   none   swap   sw   0   0
```

Salve (`Ctrl+O`, `Enter`, `Ctrl+X`).

**Passo 3 — verificar:**

```bash
free -h
# A linha "Swap" deve mostrar: 0B  0B  0B
```

> No Ubuntu 24.04 o swap costuma ser `/swap.img`. Se você desmarcou o swap
> durante a instalação, pode não haver linha nenhuma no fstab — está certo.

## 1.4 — Carregar módulos do kernel

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

Validação:

```bash
lsmod | grep -E 'overlay|br_netfilter'
```

## 1.5 — Parâmetros de rede do kernel (sysctl)

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

Validação:

```bash
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables
# ambos devem retornar = 1
```

## 1.6 — Instalar o containerd

```bash
sudo apt install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
```

Ative o `SystemdCgroup` — kubelet e containerd precisam usar o **mesmo** cgroup
driver, e divergência aqui é a causa raiz mais comum de nó `NotReady`
intermitente:

```bash
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
```

Confirme que a substituição pegou:

```bash
grep SystemdCgroup /etc/containerd/config.toml
# deve mostrar: SystemdCgroup = true
```

Reinicie e habilite:

```bash
sudo systemctl restart containerd
sudo systemctl enable containerd
sudo systemctl status containerd
```

## 1.7 — Instalar kubeadm, kubelet e kubectl

Os três componentes:

- **kubeadm** → inicializa e gerencia o cluster
- **kubelet** → agente que roda em cada node e gerencia os pods
- **kubectl** → CLI para interagir com o cluster

```bash
# Dependências
sudo apt install -y apt-transport-https ca-certificates curl gpg

# O diretório pode não existir no Ubuntu 24.04 — sem ele o gpg falha em silêncio
sudo mkdir -p /etc/apt/keyrings

# Chave GPG do repositório (v1.31)
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Repositório oficial
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

# Instalar
sudo apt update
sudo apt install -y kubelet kubeadm kubectl

# Fixar versões — evita que um apt upgrade quebre a compatibilidade com o CP
sudo apt-mark hold kubelet kubeadm kubectl

# Habilitar o kubelet
sudo systemctl enable --now kubelet
```

> O kubelet vai ficar reiniciando em loop até o `kubeadm init` / `join`. Isso é
> esperado — ele ainda não tem configuração.

Validação:

```bash
kubeadm version
kubectl version --client
```

---

# PARTE 2 — Inicializar o Cluster (SOMENTE no k8s-cp-01)

👑 **[CONTROL PLANE]** — Execute apenas em `k8s-cp-01` (192.168.2.151).

## 2.1 — Inicializar o Control Plane

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=192.168.2.151
```

Parâmetros:

- `--pod-network-cidr=10.244.0.0/16` → range interno de IPs dos pods. Não colide
  com a sua LAN `192.168.2.0/24`, por isso pode ficar como está.
- `--apiserver-advertise-address=192.168.2.151` → IP que os workers usarão para
  se conectar ao control plane.

⏳ Aguarde alguns minutos. Ao final aparece o comando `kubeadm join`. **Guarde
esse comando** — você vai usá-lo na Parte 3:

```
kubeadm join 192.168.2.151:6443 --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:xxxxxxxx...
```

## 2.2 — Configurar o kubectl

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Teste:

```bash
kubectl get nodes
# k8s-cp-01 deve aparecer como "NotReady" — normal, ainda sem CNI
```

## 2.3 — Instalar o CNI (Calico)

Sem plugin de rede os pods não se comunicam e o nó fica `NotReady`.

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
```

Aguarde 1–2 minutos e verifique:

```bash
kubectl get nodes
# k8s-cp-01 agora deve mostrar "Ready"

kubectl get pods -n kube-system | grep calico
# calico-node e calico-kube-controllers devem estar Running
```

> **Por que Calico e não Flannel:** o Calico suporta NetworkPolicy, que é
> conteúdo de CKA e rende bons exercícios de SRE (isolar namespaces, medir blast
> radius). Flannel é mais leve e simples, mas não faz NetworkPolicy. Trocar de
> CNI depois exige `kubeadm reset` e refazer o cluster, então vale decidir agora.

---

# PARTE 3 — Adicionar os Workers

⚙️ **[WORKERS]** — Execute em `k8s-worker-01` e `k8s-worker-02`.

## 3.1 — Executar o kubeadm join

Cole o comando gerado no passo 2.1:

```bash
sudo kubeadm join 192.168.2.151:6443 --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:xxxxxxxx...
```

⚠️ Se o token expirou (validade de 24h), gere um novo no control plane:

```bash
# 👑 [k8s-cp-01]
kubeadm token create --print-join-command
```

---

# PARTE 4 — Verificação Final

👑 **[CONTROL PLANE]** — Execute em `k8s-cp-01`.

## 4.1 — Verificar os nodes

```bash
kubectl get nodes -o wide
```

Saída esperada:

```
NAME            STATUS   ROLES           AGE   VERSION   INTERNAL-IP
k8s-cp-01       Ready    control-plane   10m   v1.31.x   192.168.2.151
k8s-worker-01   Ready    <none>          5m    v1.31.x   192.168.2.152
k8s-worker-02   Ready    <none>          5m    v1.31.x   192.168.2.153
```

Confira a coluna `INTERNAL-IP`: se algum nó registrou um IP diferente do
esperado, a VM tem mais de uma interface ativa e o kubelet escolheu a errada.

## 4.2 — Verificar os pods do sistema

```bash
kubectl get pods -n kube-system
```

Todos devem estar `Running` ou `Completed`.

## 4.3 — Teste rápido com nginx

```bash
kubectl create deployment nginx-test --image=nginx --replicas=2
kubectl get pods -o wide
kubectl delete deployment nginx-test
```

Os pods devem ter sido agendados nos **workers**, não no control plane — o
kubeadm aplica um taint `NoSchedule` no control plane por padrão.

## 4.4 — Teste de rede entre pods (específico do Hyper-V)

Este teste não estava no tutorial original, mas é o que valida o MAC spoofing.
Ele força pods em nós diferentes a se comunicarem:

```bash
kubectl create deployment netcheck --image=nginx --replicas=4
kubectl expose deployment netcheck --port=80
kubectl run tester --image=busybox:1.36 --rm -it --restart=Never -- \
  sh -c 'for i in 1 2 3 4 5; do wget -qO- --timeout=3 netcheck | head -1; done'
kubectl delete deployment netcheck && kubectl delete svc netcheck
```

Se algumas requisições respondem e outras dão timeout, o problema é quase certo
o `MacAddressSpoofing` desligado em uma das VMs.

---

# Referência Rápida

```bash
# 👑 Ver todos os nodes
kubectl get nodes

# 👑 Ver pods em todos os namespaces
kubectl get pods -A

# 👑 Detalhes de um node
kubectl describe node k8s-worker-01

# 🖥️ Logs do kubelet (troubleshooting)
sudo journalctl -u kubelet -f

# 👑 Remover um worker do cluster
kubectl drain k8s-worker-01 --ignore-daemonsets --delete-emptydir-data
kubectl delete node k8s-worker-01

# ⚙️ Resetar um node
sudo kubeadm reset
sudo rm -rf /etc/cni/net.d
```

## Checkpoint no Hyper-V

Assim que o cluster estiver com os 3 nós `Ready`, tire um snapshot nos dois
hosts. Quando você quebrar o cluster nos experimentos de caos — e vai —,
restaurar leva 30 segundos em vez de refazer tudo:

```powershell
Get-VM | Checkpoint-VM -SnapshotName 'cluster-ok-pos-join'
```

---

# Troubleshooting

| Problema | Causa | Solução |
|---|---|---|
| Node em `NotReady` | CNI não instalado | `kubectl get pods -n kube-system \| grep calico` |
| kubelet não inicia | Swap ativo | `sudo swapoff -a` + comentar linha no `/etc/fstab` |
| Node `NotReady` intermitente | Divergência de cgroup driver | `grep SystemdCgroup /etc/containerd/config.toml` → deve ser `true` |
| Token expirado | Validade de 24h | `kubeadm token create --print-join-command` no CP |
| Pods em `Pending` | Sem workers disponíveis | Verificar se os workers estão `Ready` |
| Erro de CRI | containerd mal configurado | Verificar `SystemdCgroup = true` |
| Pods de nós diferentes não se falam | MAC spoofing off no Hyper-V | `Set-VMNetworkAdapter -VMName <vm> -MacAddressSpoofing On` |
| `gpg: cannot open` no passo 1.7 | `/etc/apt/keyrings` não existe | `sudo mkdir -p /etc/apt/keyrings` |
| `INTERNAL-IP` errado | Múltiplas interfaces na VM | Definir `--node-ip` no `/etc/default/kubelet` |

---

## Próximo passo

Com os 3 nós `Ready`, a Fase 4 do guia principal está concluída. Segue a
**Fase 5 — MetalLB + Ingress**, que é onde o MAC spoofing volta a ser decisivo:
o modo L2 do MetalLB depende de ARP gratuito com MAC próprio.
