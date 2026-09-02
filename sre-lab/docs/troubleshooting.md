# Troubleshooting

Problemas efetivamente encontrados durante a construção, com a solução aplicada.

---

## `conntrack not found in system path` no `kubeadm init`

```
[ERROR FileExisting-conntrack]: conntrack not found in system path
```

**Causa:** Ubuntu Server minimal não traz o binário. O `kube-proxy` precisa dele
para rastrear conexões nas regras de NAT dos Services — sem ele, ClusterIP não
funciona.

**Solução** — nos três nós:

```bash
sudo apt install -y conntrack socat ethtool
```

`socat` é usado pelo `kubectl port-forward`; `ethtool` aparece no mesmo grupo de
preflight checks.

O preflight falha **antes** de alterar qualquer coisa, então basta rodar o
`kubeadm init` de novo — não precisa de `reset`.

**Como ler esse erro:** o prefixo `FileExisting-` significa "esse binário existe
no PATH?". O kubeadm não diz qual pacote fornece o binário. Quando o nome do
comando não bater com o do pacote:

```bash
conntrack                        # o Ubuntu sugere o pacote
apt-file search bin/conntrack    # ou busca explícita
```

---

## `Invalid callback for stdout specified: yaml`

**Causa:** o callback `yaml` mora na coleção `community.general`, que não vem no
`ansible-core` puro.

**Solução A** — remover do `ansible.cfg`:

```bash
sed -i '/stdout_callback = yaml/d' ansible.cfg
```

**Solução B** — instalar a coleção e usar o nome completo:

```bash
ansible-galaxy collection install community.general
# ansible.cfg: stdout_callback = community.general.yaml
```

---

## `No package matching 'zabbix-agent2' is available`

Falhou nos cinco Ubuntu; funcionou no `zbx-01`, que já tinha o repositório
instalado manualmente.

**Causa:** o `update_cache: true` no módulo genérico `package` não repassa o
refresh para o APT de forma confiável. O repositório foi adicionado, mas o
índice nunca foi lido.

**Solução:** tasks explícitas de refresh entre o repositório e a instalação:

```yaml
- name: Atualizar cache do APT
  apt:
    update_cache: true
  when: ansible_os_family == 'Debian'

- name: Atualizar cache do DNF
  dnf:
    update_cache: true
  when: ansible_os_family == 'RedHat'
```

E remover o `update_cache` da task de instalação, onde não faz nada de útil.

**Diagnóstico útil:**

```bash
ansible k8s-cp-01 -m shell -a 'apt-cache policy zabbix-agent2' --ask-pass
```

---

## Zabbix: `Cannot establish TCP connection to [[127.0.0.1]:10050]`

**Causa:** o host "Zabbix server" vem pré-configurado apontando para
`127.0.0.1:10050`, esperando um agente local. Mas o `zabbix-server` roda em
container — `127.0.0.1` ali é o próprio container, que não tem agente.

**Solução:** instalar o agente nativo no `zbx-01` e corrigir a interface do host
no frontend de `127.0.0.1` para `192.168.2.157`.

No `zabbix_agent2.conf`, o `Server=` precisa incluir a faixa do Docker, porque a
conexão vinda do container chega com IP dessa rede:

```
Server=192.168.2.157,172.16.0.0/12
```

---

## `Incorrect value for field "value": cannot be empty` na action do Zabbix

**Causa:** o diálogo "New condition" foi aberto, e ele exige um valor.

**Solução:** `Cancel`. Para aceitar qualquer host, a seção Conditions deve ficar
**intacta** — não clicar em Add. Ação sem condição aceita todos os hosts que se
anunciarem.

---

## `Field "roleid" is mandatory` ao criar usuário no Zabbix

**Causa:** o Role fica na aba **Permissions**, não na aba User.

**Solução:** aba Permissions → Role → `Admin role`. Os dados já preenchidos nas
outras abas permanecem ao navegar entre elas.

---

## Host duplicado no Zabbix

`Zabbix server` e `zbx-01` apontando ambos para `192.168.2.157:10050` — coleta
duplicada na mesma VM.

**Causa:** o host pré-definido de fábrica mais o criado pelo auto-registro.

**Solução:** desabilitar o `zbx-01` (o do auto-registro) e manter o
`Zabbix server`, que carrega templates extras de monitoramento interno —
160 itens contra 73. Desabilitar em vez de deletar: se o auto-registro recriar,
fica visível.

---

## `kubectl get pods -w` "trava"

Não travou — o `-w` (watch) fica escutando mudanças e nunca retorna sozinho.

`Ctrl+C` para sair. Alternativas:

```bash
kubectl -n monitoring get pods            # retorna na hora
watch -n5 kubectl -n monitoring get pods  # redesenha a tela, mais legível
```

---

## Referência rápida de sintomas

| Sintoma | Causa provável |
|---|---|
| MetalLB `EXTERNAL-IP` em `<pending>` | `MacAddressSpoofing` off, ou `L2Advertisement` não aplicado |
| Pods de nós diferentes não se falam | `MacAddressSpoofing` off no Hyper-V |
| Nó `NotReady` intermitente | divergência de cgroup driver — `SystemdCgroup` deve ser `true` |
| kubelet não sobe | swap ainda ativo |
| PVC em `Pending` | sem StorageClass default |
| ServiceMonitor ignorado sem erro | `serviceMonitorSelectorNilUsesHelmValues` não está `false` |
| `gpg: cannot open` ao add repo k8s | `/etc/apt/keyrings` não existe |
| Conflito de IP | faixa não excluída do DHCP do roteador |
| Erro de TLS aparentemente aleatório | drift de relógio — VM suspensa acorda atrasada, falta chrony |

---

## Teste de rede cross-host

Vale rodar sempre que mexer em rede. Força pods em nós diferentes a se falarem —
é o teste que realmente pega problema de MAC spoofing, que o `get nodes` não
revela:

```bash
kubectl create deployment netcheck --image=nginx --replicas=4
kubectl expose deployment netcheck --port=80
kubectl run tester --image=busybox:1.36 --rm -it --restart=Never -- \
  sh -c 'for i in 1 2 3 4 5; do wget -qO- --timeout=3 netcheck | head -1; done'
kubectl delete deployment netcheck && kubectl delete svc netcheck
```

Timeout intermitente = spoofing off em alguma VM.
