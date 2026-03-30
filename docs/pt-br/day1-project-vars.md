# Variaveis de Projeto Day-1 (`cluster.sh`)

Este documento explica as variaveis de projeto usadas pelo
`scripts/talos/cluster.sh`.

## Escopo

Essas variaveis ficam dentro de cada projeto gerado (por exemplo
`clusters/talos-dev/vars.sh` e `vars.local.sh`).

O `cluster.sh` nao usa `--env`. O projeto e a fonte de verdade.

## Modelo de Arquivos

- `vars.sh`: baseline versionado do projeto.
- `vars.local.sh`: overrides locais (sensivel ou especifico da maquina), sem commit.

O `cluster.sh` carrega primeiro `vars.sh` e depois `vars.local.sh` (se existir).

## Variaveis Obrigatorias de Mapeamento de Comandos

Essas variaveis sao obrigatorias para executar as actions de day-1:

- `TALOS_DAY1_GENERATE_CMD`
- `TALOS_DAY1_PROVISION_CMD`
- `TALOS_DAY1_PREPARE_BOOTSTRAP_CMD`
- `TALOS_DAY1_APPLY_CONFIG_CMD`
- `TALOS_DAY1_BOOTSTRAP_CMD`
- `TALOS_DAY1_SYNC_ACCESS_CMD`

Se alguma estiver vazia, o `cluster.sh` falha com erro explicito naquela action.

## Variaveis de Baseline de Addons (`apply-post-bootstrap`)

- `TALOS_CLUSTER_BASELINE_ADDONS`
  - Lista JSON de addons para instalar no post-bootstrap baseline.
  - Valor padrao gerado: `["cilium"]`.
- `TALOS_DAY1_REQUIRE_CILIUM`
  - `true`/`false`.
  - Se `true`, `cilium` precisa existir na lista de baseline.
- `TALOS_DAY1_MANIFEST_ROOT_DIR`
  - Diretorio raiz que contem manifests/charts dos addons.
- `TALOS_DAY1_KUBE_CONTEXT`
  - Contexto Kubernetes usado para instalar addons no post-bootstrap.

Voce pode sobrescrever em runtime com:

- `--addons=...`
- `--manifest-root-dir=...`
- `--kube-context=...`

## Variaveis de Imagem (`refresh-schematics`)

- `TALOS_CONTROL_PLANE_INSTALLER_IMAGE`
- `TALOS_WORKER_INSTALLER_IMAGE`
- `TALOS_OVA_PATH`

O `refresh-schematics` atualiza esses valores usando IDs de schematic do Talos Factory.

## Variaveis Comuns de Topologia / Rede

Defaults gerados:

- `TALOS_CLUSTER_NAME`
- `TALOS_CLUSTER_ENDPOINT`
- `TALOS_GATEWAY`
- `TALOS_NETMASK_PREFIX`
- `TALOS_NODE_INTERFACE`
- `TALOS_NAMESERVERS`
- `TALOS_CONTROL_PLANE_COUNT`
- `TALOS_WORKER_COUNT`
- `TALOS_CONTROL_PLANE_IPS`
- `TALOS_WORKER_IPS`
- `TALOS_CONTROL_PLANE_NAME_PREFIX`
- `TALOS_WORKER_NAME_PREFIX`

Essas variaveis sao insumo do projeto para os comandos adaptadores.

## Exemplo Pratico

Baseline em `vars.sh`:

```bash
export TALOS_DAY1_GENERATE_CMD="talosctl gen config ..."
export TALOS_DAY1_PROVISION_CMD="./scripts/provision.sh"
export TALOS_DAY1_PREPARE_BOOTSTRAP_CMD="./scripts/prepare-bootstrap.sh"
export TALOS_DAY1_APPLY_CONFIG_CMD="./scripts/apply-config.sh"
export TALOS_DAY1_BOOTSTRAP_CMD="talosctl bootstrap -n 192.168.0.61"
export TALOS_DAY1_SYNC_ACCESS_CMD="./scripts/sync-access.sh"

export TALOS_DAY1_MANIFEST_ROOT_DIR="/home/user/talos-vsphere-gitops"
export TALOS_DAY1_KUBE_CONTEXT="talos-dev"
export TALOS_CLUSTER_BASELINE_ADDONS='["cilium","longhorn"]'
```

Override local em `vars.local.sh`:

```bash
export TALOS_DAY1_KUBE_CONTEXT="talos-dev-admin"
```

## Variaveis De Conexao vSphere (quando usar mapeamentos baseados em govc)

Se os comandos mapeados usarem scripts de provisionamento em vSphere, defina em
`vars.local.sh`:

```bash
export VSPHERE_ENDPOINT="192.168.0.233"
export VSPHERE_USERNAME="root"
export VSPHERE_PASSWORD="CHANGE_ME"
export VSPHERE_INSECURE_CONNECTION="true"
export VSPHERE_DATASTORE="DATASTORE_02"
export VSPHERE_NETWORK="VM Network"
export VSPHERE_FOLDER=""
export VSPHERE_RESOURCE_POOL=""
export SSH_USER="vagrant"
export HAPROXY_SSH_USER="vagrant"
```

Essas variaveis nao sao consumidas diretamente pelo `cluster.sh`. Elas sao
consumidas pelos comandos referenciados em `TALOS_DAY1_*_CMD`.

## Ordem de Execucao (Referencia)

1. `cluster.sh create-project --project-dir=...`
2. Preencher `vars.sh` e opcionalmente `vars.local.sh`
3. `cluster.sh refresh-schematics --project-dir=... --talos-version=vX.Y.Z`
4. `cluster.sh generate --project-dir=...`
5. `cluster.sh provision --project-dir=...`
6. `cluster.sh prepare-bootstrap --project-dir=...`
7. `cluster.sh bootstrap --project-dir=...`
8. `cluster.sh apply-post-bootstrap --project-dir=...`
9. `cluster.sh sync-access --project-dir=...`
