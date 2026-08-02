# Estilo YAML

## Objetivo

Todo arquivo `*.yaml`/`*.yml` versionado neste repositorio (atualmente os
formularios em `.github/ISSUE_TEMPLATE/` e `.github/workflows/`) e checado
contra uma unica politica versionada de
[`yamllint`](https://yamllint.readthedocs.io/), para manter o estilo
consistente conforme a superficie YAML do repositorio cresce.

## Politica

A politica fica na raiz do repositorio, em `.yamllint.yaml`. Ela estende o
conjunto de regras `default` do yamllint e relaxa apenas o que os arquivos
reais deste repositorio exigem:

- `line-length`: elevado para 160 para acomodar as listas de opcoes em uma
  unica linha usadas pelos dropdowns dos formularios de issue do GitHub.
- `document-start`: exige que os arquivos **nao** usem o marcador `---` no
  inicio, seguindo o padrao ja usado pelos formularios de issue e workflows.
- `truthy`: nao sinaliza chaves de mapa, para que a chave `on:` (sem aspas)
  dos GitHub Actions nao seja tratada como valor booleano.

Nenhuma regra e desabilitada por completo.

## Uso local

Instale o `yamllint` (qualquer uma das opcoes):

```bash
pipx install yamllint
pip install --user yamllint
brew install yamllint
```

Execute a checagem:

```bash
bash scripts/talos/tests/test-yaml-style.sh
```

O script faz lint apenas dos arquivos `*.yaml`/`*.yml` versionados no Git,
usando a politica acima. Ele termina com falha e mensagem de instalacao
acionavel se o `yamllint` nao estiver no `PATH`, e termina com sucesso e uma
mensagem `[SKIP]` se o repositorio nao tiver nenhum arquivo YAML versionado.
Nao executa nenhuma operacao de rede, Talos, Kubernetes, Helm ou VMware.

## CI

O workflow `.github/workflows/yaml-style.yml` executa o mesmo comando
`scripts/talos/tests/test-yaml-style.sh` em `push` e `pull_request`, para que
o resultado local e o do CI nunca divirjam. O workflow solicita apenas a
permissao `contents: read` e fixa `actions/checkout` e
`actions/setup-python` em um commit SHA especifico.
