# Decisões técnicas

Registro do *porquê* de cada escolha. Útil para retomar o lab depois de semanas
e para explicar o desenho em entrevista.

---

## Distribuição das VMs entre os dois hosts

**Decisão:** workers e observabilidade no `pc-01` (32 GB); control plane,
automação e Zabbix no `pc-02` (16 GB).

**Motivo:** o host maior carrega o que é pesado. Mas o ponto central é outro —
**os dois stacks de monitoramento ficam em hosts físicos diferentes**. Quando o
`pc-01` for derrubado num experimento de caos, o Zabbix no `pc-02` continua vivo
e reporta a queda. É o problema de "quem monitora o monitor" resolvido na
topologia, não na teoria.

---

## vSwitch External em vez de Internal

**Decisão:** bridge na LAN de casa.

**Motivo:** as VMs dos dois hosts se enxergam nativamente e têm internet, sem
precisar de uma VM roteadora no meio. O custo é ocupar IPs da LAN doméstica —
daí a necessidade de excluir as faixas `.151–.157` e `.200–.220` do DHCP do
roteador.

---

## Calico em vez de Flannel

**Decisão:** Calico v3.28.0.

**Motivo:** suporta NetworkPolicy, que é conteúdo de CKA e rende exercícios de
SRE (isolar namespaces, medir blast radius). Flannel é mais leve e sobe mais
rápido, mas não faz NetworkPolicy. Trocar de CNI depois exige `kubeadm reset` e
refazer o cluster, então a escolha precisava ser feita no início.

---

## MetalLB + Ingress em vez de NodePort

**Decisão:** MetalLB em modo L2 + ingress-nginx.

**Motivo:** NodePort funcionaria num lab, mas não exercita o que se encontra em
produção. Com MetalLB + Ingress pratica-se roteamento por hostname, terminação
TLS, e o modelo de um IP servindo muitos serviços. Bônus de caos: dá para
derrubar o nó que está anunciando o IP e medir quanto tempo outro leva para
assumir o anúncio.

**Divisão de responsabilidade:** MetalLB atua em L2/L3 — entrega o IP e o anuncia
via ARP gratuito. Ingress-nginx atua em L7 — lê o header `Host:` e decide o
destino. O ingress-nginx é ele próprio um `Service type: LoadBalancer`, ou seja,
cliente do MetalLB. Por isso a ordem de instalação importa.

---

## Pool MetalLB em `.200–.220`

**Decisão:** pool longe da faixa das VMs.

**Motivo:** a intenção original era usar `192.168.2.15X`, mas essa faixa tem
apenas 10 endereços e as 7 VMs consomem quase todos. O MetalLB precisa de uma
faixa contígua livre.

---

## local-path-provisioner como StorageClass

**Decisão:** local-path-provisioner v0.0.30 como default StorageClass.

**Motivo:** kubeadm não instala nenhum provisionador. Sem StorageClass, o PVC de
30Gi do Prometheus ficaria `Pending` para sempre. A alternativa seria remover o
`storageSpec` e usar `emptyDir`, mas aí as métricas se perdem a cada restart do
pod — justamente o que atrapalha os experimentos de caos.

---

## CentOS Stream 9 no `ansible-ctl`

**Decisão:** CentOS Stream 9, em vez de RHEL 9 ou Rocky/Alma.

**Motivo:** é a única VM fora do Ubuntu, de propósito — é onde se pratica `dnf`,
`firewalld`, SELinux, `nmcli` e system roles, o ecossistema Red Hat que cai no
EX294, sem misturar com os nós do cluster.

**Trade-off consciente:** o Stream é *upstream* do RHEL, recebe mudanças antes.
Rocky e Alma são downstream e portanto 1:1 com o RHEL, tecnicamente mais fiéis
para estudo de certificação. A escolha pelo Stream foi por interesse na
comunidade CentOS e no processo de construção do RHEL. Na prática a diferença é
mínima: eventualmente algum pacote estará à frente da versão do RHEL 9.

---

## Zabbix **e** Prometheus, não um ou outro

**Decisão:** manter os dois, em camadas distintas.

**Motivo:** eles resolvem problemas diferentes e o mercado pede os dois.

| | Zabbix | Prometheus |
|---|---|---|
| Camada | Infra clássica: hosts, SO, rede, SNMP, appliances, bancos | Cloud-native: k8s, pods, aplicação |
| Modelo | Push/pull com agente, banco relacional | Pull, série temporal, service discovery |
| Onde domina | LATAM, telecom, MSP, on-prem/híbrido | Kubernetes, ambientes cloud |

Grafana consome ambos como datasources, num painel único. Saber os dois é uma
combinação relativamente rara.

---

## Auto-registro em vez de cadastro manual no Zabbix

**Decisão:** action de autoregistration sem condições.

**Motivo:** cadastrar 6 hosts à mão é repetitivo e não ensina nada além do
formulário. Auto-registro é o que se usa quando a frota cresce. As condições
ficaram vazias porque o lab é homogêneo — numa frota real, seria algo como
"Host name contains `k8s-`" para vincular templates diferentes por tipo de
máquina.

O nome com que cada host se cadastra vem de `Hostname={{ inventory_hostname }}`
no template Jinja do agente — por isso valeu usar a variável do Ansible ali.

---

## Autenticação Ansible por senha (temporário)

**Decisão:** `--ask-pass --ask-become-pass` + `sshpass`, com migração para chave
adiada.

**Motivo:** desbloqueou o trabalho sem parar para configurar chaves. Mas é
dívida técnica consciente: o EX294 assume autenticação por chave, e digitar
senha a cada playbook cansa. Migração pendente:

```bash
ssh-keygen -t ed25519
for ip in 151 152 153 154 155 157; do ssh-copy-id rafael@192.168.2.$ip; done
```

---

## `obs-01` e `svc-01` fora do cluster

**Situação atual:** ambas provisionadas e com agente Zabbix, mas sem carga.

O plano original as previa como host da stack de observabilidade e da aplicação
de demonstração, respectivamente. Como o `kube-prometheus-stack` roda dentro do
Kubernetes, os pods foram para os workers e a `obs-01` ficou ociosa.

**Duas saídas possíveis:**

- **A** — deixar como está; `obs-01` vira host de Loki standalone ou outra coisa.
- **B** — fazer `obs-01` entrar no cluster como worker dedicado, com taint e
  nodeSelector forçando o stack de monitoramento a rodar só nela. Isola a
  observabilidade da carga das apps, que é como se faz em produção, e usa os
  8 GB que foram dimensionados justamente para isso.

A opção B é mais fiel ao mundo real. Pendente de decisão.

---

## Uso de `--check --diff` antes de aplicar playbooks

**Decisão:** dry run como hábito.

**Motivo:** valida a mudança antes de aplicar e mostra exatamente o que seria
escrito. É prática de produção e cai no EX294. Foi assim que ficou visível, por
exemplo, que o playbook corrigiria o `Server=127.0.0.1` que havia sido
configurado à mão no `zbx-01` — o Ansible convergindo para o estado declarado
independentemente de como o host estava antes.
