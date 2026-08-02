# Variaveis de Projeto Day-1 (`cluster.sh`)

Este documento descreve as variaveis de projeto consumidas por
[`scripts/talos/cluster.sh`](/home/vagrant/talos-toolchain/scripts/talos/cluster.sh).

## Escopo

`vars.sh`/`vars.local.sh` sao um caminho de compatibilidade temporario. O
contrato de configuracao primario, somente-dados, e a camada YAML via XDG
descrita em [`environment-config.md`](environment-config.md) — prefira-a
para novos valores, sejam nao-secretos ou secretos.

Cada projeto de cluster gerado e a fonte de verdade das operacoes de day-1.

Estrutura tipica:

- `vars.sh`: baseline versionado do projeto
- `vars.local.sh`: overrides locais ou sensiveis, sem commit
- `patches/`: patches de machine config renderizados/aplicados no day-1
- `generated/`: artefatos gerados do Talos

O `cluster.sh` carrega primeiro `vars.sh` e depois `vars.local.sh`, se existir.

## Contrato Atual

O `cluster.sh` atual nao usa mais mapeamentos `TALOS_DAY1_*`.
Essas variaveis foram removidas.

O contrato agora e:

- orientado a projeto
- orientado a actions
- baseado nas variaveis geradas por `create-project`

Isso significa que o proprio `cluster.sh` controla diretamente o fluxo de day-1:

1. `generate`
2. `provision`
3. `prepare-bootstrap`
4. `apply-config`
5. `bootstrap`
6. `apply-post-bootstrap`
7. `sync-access`

## Variaveis Principais

Os defaults gerados incluem estes grupos.

### Identidade do cluster

- `TALOS_CLUSTER_NAME`
- `TALOS_CLUSTER_ENDPOINT`

### Destino vSphere (compatibilidade/referencia)

As variaveis abaixo descrevem a interface de provisionamento baseada em
vSphere consumida pelo `provision-talos-vsphere`. Elas sao documentadas aqui
apenas para compatibilidade e referencia — um cluster Talos local no macOS
nao depende do vSphere e nao precisa dessas variaveis definidas.

- `VSPHERE_ENDPOINT`
- `VSPHERE_USERNAME`
- `VSPHERE_PASSWORD`
- `VSPHERE_INSECURE_CONNECTION`
- `VSPHERE_DATASTORE`
- `VSPHERE_NETWORK`
- `VSPHERE_FOLDER`
- `VSPHERE_RESOURCE_POOL`

### Identidade de acesso

- `BUILD_USERNAME`
- `SSH_USER`
- `SSH_PORT`
- `HAPROXY_SSH_USER`
- `ANSIBLE_USER`
- `ANSIBLE_USERNAME`

### Topologia do load balancer

- `HAPROXY_VIP`
- `HAPROXY_NODE_1_NAME`
- `HAPROXY_NODE_1_IP`
- `HAPROXY_NODE_2_NAME`
- `HAPROXY_NODE_2_IP`

### Imagens do Talos

- `TALOS_OVA_PATH`
- `TALOS_ISO_DATASTORE_PATH`
- `TALOS_ISO_LOCAL_PATH`
- `TALOS_CONTROL_PLANE_INSTALLER_IMAGE`
- `TALOS_WORKER_INSTALLER_IMAGE`

O `refresh-schematics` atualiza as variaveis de installer image e tambem pode
reescrever `TALOS_OVA_PATH`.

### Topologia

- `TALOS_CONTROL_PLANE_COUNT`
- `TALOS_WORKER_COUNT`
- `TALOS_CONTROL_PLANE_IPS`
- `TALOS_WORKER_IPS`
- `TALOS_CONTROL_PLANE_NAME_PREFIX`
- `TALOS_WORKER_NAME_PREFIX`

### Recursos dos nos

- `TALOS_CONTROL_PLANE_CPU`
- `TALOS_CONTROL_PLANE_MEMORY_MB`
- `TALOS_CONTROL_PLANE_DISK_GB`
- `TALOS_CONTROL_PLANE_EXTRA_DISK_GB`
- `TALOS_WORKER_CPU`
- `TALOS_WORKER_MEMORY_MB`
- `TALOS_WORKER_DISK_GB`
- `TALOS_WORKER_EXTRA_DISK_GB`

### Rede

- `TALOS_GATEWAY`
- `TALOS_NETMASK_PREFIX`
- `TALOS_NODE_INTERFACE`
- `TALOS_NAMESERVERS`
- `TALOS_CONTROL_PLANE_VIP_ENABLED`
- `TALOS_CONTROL_PLANE_VIP`

### Caminhos de artefatos gerados

- `TALOS_CONTROL_PLANE_CONFIG_PATH`
- `TALOS_WORKER_CONFIG_PATH`

Esses valores sao importantes porque o toolchain deriva os caminhos de
`generated/` e `patches/` a partir do layout do projeto.

## Variaveis de Post-Bootstrap Day-1

Essas variaveis controlam a fase de baseline de addons executada por
`apply-post-bootstrap`.

- `TALOS_CLUSTER_BASELINE_ADDONS`
- `TALOS_BASELINE_ADDONS`
- `TALOS_DISABLE_DEFAULT_CNI`
- `TALOS_POST_BOOTSTRAP_HELM_AUTO_PREPARE`
- `TALOS_POST_BOOTSTRAP_HELM_SOURCE_MODE`
- `TALOS_POST_BOOTSTRAP_HELM_SOURCE_PATH`
- `TALOS_POST_BOOTSTRAP_HELM_SOURCE_URL`
- `TALOS_POST_BOOTSTRAP_HELM_OVERWRITE`

Comportamento esperado hoje:

- o baseline de day-1 e orientado ao cluster
- `cilium` normalmente faz parte do day-1
- a fonte dos manifests pode vir de um caminho local ou de um arquivo baixado

## Hooks de Integracao Externa

Esses hooks existem para que o toolchain continue reutilizavel e nao embuta
modulos de infraestrutura especificos do lab.

### Hook de load balancer

- `TALOS_LOAD_BALANCER_RECONCILE_SCRIPT`

Se estiver definido, o `prepare-bootstrap` pode reconciliar frontend/backend da
API do Talos por meio de um script externo.

Se estiver vazio, a reconciliacao do load balancer e ignorada.

### Hooks de DNS

- `TALOS_DNS_SYNC_REQUIRED`
- `TALOS_DNS_REGISTER_SCRIPT`
- `TALOS_DNS_UNREGISTER_SCRIPT`

Esses pontos de integracao sao opcionais para ambientes que desejam gerenciar
registros DNS dos nos Talos durante provision/destroy.

O comportamento padrao do toolchain reutilizavel deve continuar sendo:

- `TALOS_DNS_SYNC_REQUIRED="false"`

## Exemplo Pratico de Override

Exemplo de `vars.local.sh`:

```bash
export VSPHERE_PASSWORD="CHANGE_ME"
export TALOS_NAMESERVERS='["192.168.0.53"]'
export TALOS_LOAD_BALANCER_RECONCILE_SCRIPT="/path/do/lab/load-balancer-hook.sh"
export TALOS_DNS_SYNC_REQUIRED="true"
export TALOS_DNS_REGISTER_SCRIPT="/path/do/lab/register-hosts.sh"
export TALOS_DNS_UNREGISTER_SCRIPT="/path/do/lab/unregister-hosts.sh"
```

## Ordem de Execucao (Referencia)

1. `cluster.sh create-project --project-dir=...`
2. Preencher `vars.sh`
3. Opcionalmente criar e preencher `vars.local.sh`
4. `cluster.sh refresh-schematics --project-dir=... --talos-version=vX.Y.Z`
5. `cluster.sh generate --project-dir=...`
6. `cluster.sh provision --project-dir=...`
7. `cluster.sh prepare-bootstrap --project-dir=...`
8. `cluster.sh apply-config --project-dir=...`
9. `cluster.sh bootstrap --project-dir=...`
10. `cluster.sh apply-post-bootstrap --project-dir=...`
11. `cluster.sh sync-access --project-dir=...`
