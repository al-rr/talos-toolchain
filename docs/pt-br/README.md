# Indice de Documentacao (PT-BR)

## Objetivo do Repositorio

`talos-toolchain` fornece automacao reutilizavel de Talos sem acoplamento com
um repositorio de laboratorio especifico.

## Limite Local-First

A direcao aceita para o Marco A e que o `talos-toolchain` seja o CTL Talos
canonico e portavel para trabalho local de cluster no macOS, executando as
acoes de lifecycle day-1 e day-2 do Talos (`cluster.sh`, `talos-gitops.sh`)
sem depender do provisionamento VMware/vSphere. Um backend Talos local de
primeira classe baseado em Docker/Colima agora existe como um entrypoint
separado do Marco A, `scripts/talos/local-cluster.sh` (veja
`docs/pt-br/local-cluster.md`); o proprio `cluster.sh` continua voltado ao
vSphere e nao cria nem opera um cluster local no macOS. O provisionamento de
infraestrutura VMware/vSphere e responsabilidade do `provision-talos-vsphere`
e nao e pre-requisito do fluxo local via Docker. Uma direcao futura de
configuracao Talos por usuario se apoia neste mesmo limite local-first.

## Secoes Planejadas

- Arquitetura e limites de responsabilidade
- Fluxo day-1 (`cluster.sh`)
- Fluxo day-2 (`talos-gitops.sh`)
- Guia de migracao e atualizacao

## Guias Disponiveis

- Variaveis de projeto day-1: `docs/pt-br/day1-project-vars.md`
- Configuracao YAML de ambiente via XDG (`config.sh`): `docs/pt-br/environment-config.md`
- Requisitos de shell (contrato de preflight Bash 5 / macOS): `docs/pt-br/shell-requirements.md`
- Cluster Talos local (Docker/Colima, `local-cluster.sh`): `docs/pt-br/local-cluster.md`
- Politica de estilo YAML e checagem local/CI: `docs/pt-br/yaml-style.md`
- Contrato de handoff Cilium day-1/day-2 (Argo CD): `docs/pt-br/cilium-gitops-handoff.md`
- Handoff entre repositorios: `provision-talos-vsphere/docs/pt-br/cross-repo-handoff.md`
