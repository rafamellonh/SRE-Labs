# Zabbix

Stack rodando no `zbx-01` (192.168.2.157) via Docker Compose.

## Subir

```bash
echo "DB_PASSWORD=$(openssl rand -base64 24)" > .env
chmod 600 .env
docker compose up -d
docker compose logs -f zabbix-server   # primeira subida cria o schema, ~3 min
```

Frontend: http://192.168.2.157:8080 — login inicial `Admin` / `zabbix`.

## Auto-registro

Configurado em **Alerts → Actions → Autoregistration actions**:

- Name: `Auto-registro Linux`
- Conditions: **nenhuma**
- Operations: `Add host` · `Add to host group: Linux servers` ·
  `Link template: Linux by Zabbix agent`

Os agentes se anunciam no restart. O nome de cadastro vem de
`Hostname={{ inventory_hostname }}` no template Jinja do Ansible.

## Agente local

O host pré-definido "Zabbix server" aponta para `127.0.0.1:10050`, que dentro do
container não tem agente. Foi corrigido para `192.168.2.157` e o agente nativo
instalado na VM. O `zbx-01` criado pelo auto-registro ficou como duplicata e
está **desabilitado**.

## Usuário de API

`grafana`, grupo `Zabbix administrators`, Role `Admin role` (aba Permissions).
Usado pelo datasource do Grafana em `http://192.168.2.157:8080/api_jsonrpc.php`.
