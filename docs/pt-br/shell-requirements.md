# Requisitos de Shell

## Contrato suportado

`scripts/talos/cluster.sh` e `scripts/talos/talos-gitops.sh` sao os dois
entrypoints mantidos e voltados ao operador. Ambos exigem **Bash 5+**. Os
scripts internos despachados por eles (`cluster-bootstrap.sh`,
`apply-post-bootstrap.sh`, `sync-kubectl.sh`, `sync-talosctl.sh`,
`govc/provision-cluster.sh`, entre outros) usam sintaxe exclusiva do Bash 5
(`mapfile`, `declare -A`) e nao devem ser executados diretamente; so sao
suportados quando iniciados via `cluster.sh` ou `talos-gitops.sh`.

O macOS traz Bash 3.2 por padrao (`/bin/bash`), que nao executa essa
sintaxe. O shell suportado no macOS e o Bash 5 do Homebrew.

## Comportamento do preflight

Os dois entrypoints carregam `scripts/talos/lib/bash-preflight.sh` antes de
qualquer trecho exclusivo do Bash 5 ser executado:

- Se o interpretador em execucao ja for Bash 5+, a execucao continua sem
  alteracoes.
- Se for Bash 3.2 (ou qualquer Bash abaixo de 5), o preflight procura um
  binario Bash 5 apenas em caminhos fixos e explicitos:
  - `/opt/homebrew/bin/bash`
  - `/usr/local/bin/bash`
  - `/usr/local/opt/bash/bin/bash`

  Nao ha busca no PATH nem consulta a gerenciador de pacotes. Se algum
  candidato for compativel, o entrypoint reexecuta a si mesmo sob esse Bash e
  adiciona o diretorio dele ao inicio do `PATH`, para que qualquer script
  despachado em seguida via `#!/usr/bin/env bash` resolva o mesmo
  interpretador Bash 5.
- Se nenhum candidato for compativel, o entrypoint para antes de executar
  qualquer sintaxe incompativel e imprime um erro acionavel, incluindo o
  comando `brew install bash` e um exemplo explicito de invocacao. Ele nunca
  instala ou reconfigura nada no host.

Uma segunda falha nao resolvida (por exemplo, uma instalacao quebrada do
Bash do Homebrew) e detectada e recusada, em vez de causar um loop de
reexecucao.

## Preflight de CLIs

Cada entrypoint tambem verifica, conforme a acao selecionada, se os comandos
externos necessarios para aquela acao (por exemplo `talosctl`, `govc`,
`kubectl`, `helm`, `curl`) estao presentes no `PATH` antes de executar
qualquer trabalho. Essa verificacao e apenas diagnostica: reporta todos os
comandos ausentes em uma unica mensagem e encerra; nunca instala ou
configura nada.

## Contrato de versao/compatibilidade de CLIs

O preflight so verifica se cada CLI exigido esta presente no `PATH`; ele
nunca verifica versao. Esta secao define a regra de compatibilidade que o
operador deve seguir para cada CLI, para que a deteccao apenas por presenca
nao permita silenciosamente uma incompatibilidade de versao. Este
repositorio nao possui um pin de versao global para nenhuma dessas
ferramentas — a fonte da verdade e sempre a selecao feita por projeto em
`vars.sh`/`--talos-version`, nunca um valor fixo neste toolchain.

- **`talosctl`**: use a versao correspondente ao release do Talos
  selecionado para o projeto via `cluster.sh refresh-schematics
  --talos-version=vX.Y.Z` (ou a versao embutida em `TALOS_OVA_PATH`/nas tags
  das imagens de instalador em `vars.sh`). O `talosctl` aplica sua propria
  politica de compatibilidade de versao entre cliente e servidor contra a
  API do Talos; portanto, use o cliente que corresponde a versao do Talos
  daquele projeto, e nao uma versao fixa definida por este repositorio.
- **`kubectl`**: mantenha-se dentro da politica padrao de compatibilidade de
  versao entre cliente e servidor do Kubernetes (kubectl ate uma versao
  minor de diferenca, para mais ou para menos, em relacao a versao do
  cluster) em relacao a versao do Kubernetes que o release do Talos
  selecionado para o projeto instala. Quem fixa a versao do Kubernetes por
  release e o Talos, nao este toolchain; por isso tambem nao ha uma versao
  fixa de `kubectl` aqui.
- **`helm`**: use um release do Helm compativel com a versao do Kubernetes do
  cluster-alvo, conforme a propria matriz de suporte do Helm (sem fixar uma
  major version especifica do Helm). Este repositorio nao seleciona versoes
  de charts Helm nem fixa o Helm em si; a propriedade de charts/versoes de
  addons do cluster fica em `talos-vsphere-gitops`.
- **`govc`**: qualquer build do `govc` compativel com a versao da API do
  vCenter/ESXi do ambiente consumidor. A selecao de endpoint/versao do
  vSphere esta fora do escopo deste repositorio, que e agnostico de
  ambiente; ela pertence ao repositorio de ambiente/laboratorio consumidor
  (por exemplo, `provision-talos-vsphere`).
- **`curl`**: qualquer `curl` atual com suporte a HTTPS/TLS. Ele so e usado
  para chamar a API de schematic da Talos Factory (`create-project`,
  `refresh-schematics`); nenhuma versao especifica e exigida.

## Docker/Colima

Um backend de execucao local com Docker/Colima esta fora do escopo deste
contrato e esta planejado para uma iteracao futura. Nao esta implementado
aqui.

## Limitacoes conhecidas

- O preflight cobre os locais padrao de instalacao do Homebrew. Um Bash 5
  instalado em um caminho nao padrao nao e detectado automaticamente; nesse
  caso, invoque o entrypoint explicitamente com esse interpretador
  (`/caminho/para/bash5 scripts/talos/cluster.sh ...`).
- Scripts diferentes de `cluster.sh` e `talos-gitops.sh` nao sao cobertos
  diretamente pela guarda de preflight; execute-os apenas atraves dos dois
  entrypoints suportados.
