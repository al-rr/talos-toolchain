# Configuracao do Host macOS

## Proposito

O `scripts/host/setup-macos.sh` instala as ferramentas que a estacao de
trabalho macOS de um operador precisa para rodar a suite de lint e de testes
offline deste repositorio. Ele existe porque essas ferramentas antes so eram
descritas em prosa, espalhadas por varios documentos, entao um Mac novo
falhava nas verificacoes sem um comando unico para corrigir.

Ele cuida apenas de ferramentas de host. Nao instala nenhum cliente de cluster
nem runtime de containers.

## O que ele gerencia

| Ferramenta | Formula | Por que e necessaria |
| --- | --- | --- |
| Bash 5+ | `bash` | Todo entrypoint do toolchain exige; o macOS entrega Bash 3.2 |
| `yamllint` | `yamllint` | `scripts/talos/tests/test-yaml-style.sh` |
| `shellcheck` | `shellcheck` | Analise estatica dos scripts em `scripts/` |

## Uso

```bash
# Relata o que esta instalado e o que falta; nao altera nada
./scripts/host/setup-macos.sh check

# Instala o que falta (primeiro em modo de previsao)
./scripts/host/setup-macos.sh install --dry-run
./scripts/host/setup-macos.sh install
```

O `check` sai com codigo `2` quando algo esta faltando, entao pode ser usado
como porta de entrada em um script wrapper.

## O que ele deliberadamente nao faz

- **Nao esta acoplado a nenhum entrypoint de ciclo de vida.** Rodar o setup
  continua sendo uma decisao explicita do operador. O `cluster.sh`, o
  `local-cluster.sh` e o `talos-gitops.sh` nunca o chamam.
- **Nao instala clientes de cluster** — `talosctl`, `kubectl`, `helm`,
  `cilium` — nem runtime de containers como Colima ou Docker. Esses carregam
  decisoes de fixacao de versao e de recursos que devem acompanhar um cluster
  especifico, nao uma estacao de trabalho. No controlador Vagrant do lab, os
  instaladores versionados em
  `provision-talos-vsphere/overlays/lab/controller/scripts/` sao os donos
  dessa tarefa.
- **Nunca executa `sudo`**, nunca edita arquivos rc de shell, nunca troca seu
  shell de login e nunca contata um cluster.

## Relacao com o preflight de Bash 5

O `scripts/talos/lib/bash-preflight.sh` **diagnostica** a ausencia do Bash 5 e
para com uma mensagem acionavel. Ele nunca instala nada, e o
`scripts/talos/tests/test-bash-preflight.sh` verifica que a mensagem dele nem
sequer sugere instalacao.

Essa separacao e intencional e este script nao a altera: o preflight continua
apenas relatando, e a instalacao segue sendo uma acao separada e explicita. O
Bash 5 do Homebrew e instalado *ao lado* do Bash 3.2 do sistema — ele nao o
substitui, e seu shell de login fica intacto. Os entrypoints o localizam
sozinhos nos caminhos fixos que o preflight aceita.

## Rodando em um host com Bash 3.2

O script precisa rodar sob o Bash 3.2 padrao do macOS, porque e ele quem
instala o Bash 5. Por isso evita `mapfile`, arrays associativos e outras
sintaxes de Bash 4+. Mantenha assim ao editar: uma dependencia de Bash 5 aqui
tornaria impossivel rodar justamente no host que mais precisa dele.
