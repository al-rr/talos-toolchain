# Configuracao YAML de Ambiente via XDG (`config.sh`)

Este documento descreve o contrato de configuracao somente-dados em YAML
gerenciado por
[`scripts/talos/config.sh`](/home/vagrant/talos-toolchain/scripts/talos/config.sh)
e implementado em
[`scripts/talos/lib/yaml-config.sh`](/home/vagrant/talos-toolchain/scripts/talos/lib/yaml-config.sh).

## Escopo

A configuracao e dado YAML, nunca carregada como shell. Ela vive sob
`XDG_CONFIG_HOME` (padrao `~/.config/talos-toolchain`), fora de qualquer
checkout Git:

```
${XDG_CONFIG_HOME:-~/.config}/talos-toolchain/
  base/config.yaml                       # defaults nao-secretos compartilhados
  environments/<name>/config.yaml        # overrides nao-secretos do ambiente
  environments/<name>/credentials.yaml   # segredos protegidos (modo 0600)
```

`vars.sh`/`vars.local.sh` seguem como caminho de compatibilidade temporario
para layouts de projeto existentes (veja
[`day1-project-vars.md`](day1-project-vars.md)). Sao lidos somente apos as
mesmas verificacoes seguras de leitura descritas abaixo.

## Bootstrap

```bash
scripts/talos/config.sh bootstrap --environment=lab
scripts/talos/config.sh bootstrap --environment=lab --force   # sobrescreve arquivos existentes
scripts/talos/config.sh show --environment=lab                # dump de diagnostico com redacao
```

O bootstrap e idempotente: arquivos ja existentes e validos permanecem
intactos, a menos que `--force` seja informado. Diretorios sao criados com
modo `0700`; arquivos `config.yaml` sao gravados com modo `0600`;
`credentials.yaml` sempre tem modo `0600`. O bootstrap recusa — antes de
qualquer `mkdir -p`, `chmod` ou escrita — qualquer diretorio ou arquivo
pre-existente que seja um symlink, tenha tipo incorreto, ou falhe de
qualquer outra forma nas verificacoes seguras abaixo. Isso vale para todo
nivel ancestral gerenciado pelo toolchain, nao somente os diretorios-folha:
a propria raiz `talos-toolchain`, seu pai `environments`, `base/` e
`environments/<name>/` sao verificados/criados nessa ordem, da raiz para as
folhas, de forma que um `mkdir -p` num caminho mais profundo nunca seja a
primeira coisa a tocar um ancestral mais raso e ainda nao verificado.
`--force` so pode sobrescrever um arquivo que ja passou por essas
verificacoes, nunca escreve atraves de um symlink nem substitui um arquivo
inseguro.

## Verificacoes seguras de arquivo

Antes de ler qualquer arquivo YAML (ou `vars.sh`/`vars.local.sh` legado), o
carregador verifica:

- o caminho e um arquivo real, nao um symlink;
- e de propriedade do usuario atual;
- `base/config.yaml` e `environments/<name>/config.yaml` nao sao graváveis
  por grupo/outros;
- `environments/<name>/credentials.yaml` tem exatamente modo `0600`;
- os diretorios `base/` e `environments/<name>/` tem exatamente modo `0700`;
- a raiz `talos-toolchain` e seu pai `environments`, se ja existirem, sao
  diretorios reais (nao symlink) que passam pela mesma verificacao de
  modo/propriedade — um arquivo nao pode ser confiavel apenas por passar
  isoladamente em sua propria verificacao, se for alcancado somente atraves
  de um symlink ancestral trocado.

Qualquer violacao recusa a leitura com um erro acionavel, em vez de carregar
o arquivo. Um arquivo YAML que falha ao ser interpretado (sintaxe malformada)
tambem e rejeitado diretamente, antes que qualquer valor pudesse ser
exportado — a validacao de schema nunca trata um erro de parse como "nenhuma
violacao encontrada".

## Schema com lista de permissao

Somente os caminhos com ponto declarados em `TALOS_CONFIG_SCHEMA_TABLE`
(nao-secreto) e `TALOS_CONFIG_SECRET_SCHEMA_TABLE` (somente credenciais) em
`lib/yaml-config.sh` sao aceitos. Todo no do documento e verificado, nao
somente os valores escalares nas folhas: chaves desconhecidas,
incompatibilidades de tipo (por exemplo, uma string onde um inteiro e
esperado, ou um float onde um inteiro e esperado) e formatos nao suportados
em um campo conhecido — `null`, um mapa vazio ou nao-vazio, ou uma lista
vazia ou nao-vazia onde um escalar e esperado — sao todos rejeitados antes
de qualquer valor ser exportado. Um prefixo de namespace conhecido (por
exemplo `talos` ou `haproxy`) ainda pode ser um mapa vazio. Adicionar um novo
campo significa adicionar uma linha na tabela correspondente.

Os campos nao-secretos atuais mapeiam para variaveis de ambiente existentes,
por exemplo:

| Caminho YAML | Variavel de ambiente |
| --- | --- |
| `cluster.name` | `TALOS_CLUSTER_NAME` |
| `cluster.endpoint` | `TALOS_CLUSTER_ENDPOINT` |
| `vsphere.endpoint` | `VSPHERE_ENDPOINT` |
| `ssh.user` | `SSH_USER` |
| `haproxy.vip` | `HAPROXY_VIP` |
| `talos.controlPlane.count` | `TALOS_CONTROL_PLANE_COUNT` |
| `talos.network.gateway` | `TALOS_GATEWAY` |

Campos somente-credenciais:

| Caminho YAML | Variavel de ambiente |
| --- | --- |
| `vsphere.password` | `VSPHERE_PASSWORD` |
| `ssh.privateKeyFile` | `SSH_PRIVATE_KEY_FILE` |
| `ansible.privateKeyFile` | `ANSIBLE_PRIVATE_KEY_FILE` |
| `build.password` | `BUILD_PASSWORD` |

## Precedencia

Os valores sao aplicados nesta ordem, com camadas posteriores sobrescrevendo
as anteriores:

1. Defaults (valores vazios/neutros embutidos nos arquivos gerados pelo
   schema).
2. `base/config.yaml` (compartilhado, nao-secreto).
3. `config.yaml` versionado do projeto (nao-secreto, commitado junto ao
   projeto do cluster, sem segredos de site).
4. `environments/<name>/config.yaml` (nao-secreto, especifico do ambiente).
5. `environments/<name>/credentials.yaml` (somente segredos).
6. Flags explicitas de CLI no entrypoint que chama o carregador (aplicadas
   pelo chamador apos o retorno de `talos_config_load`).

O `cluster.sh` faz source do `vars.sh`/`vars.local.sh` legado primeiro
(camada de compatibilidade apenas) e depois chama esse carregador, entao as
camadas de ambiente/credenciais em YAML sempre vencem sobre o que o legado
define — valores legados nunca sobrescrevem a configuracao YAML resolvida.
`--environment=<name>` (padrao: o nome do projeto/cluster) seleciona o
ambiente, e o `config.yaml` proprio do projeto (se presente) e passado como
intencao versionada. O `cluster.sh` exige `yq` para toda acao exceto
`create-project` (que permanece totalmente offline); ele falha com um erro
acionavel em vez de pular silenciosamente a camada YAML quando `yq` esta
ausente.

Nomes de ambiente sao restritos a um unico componente de caminho seguro
(`[A-Za-z0-9][A-Za-z0-9._-]*`): nomes vazios, barras, nomes somente-ponto
(`.`, `..`) e qualquer outra entrada no formato de travessia de caminho sao
rejeitados antes que qualquer caminho seja construido a partir deles.

## Diagnostico com redacao

`config.sh show --environment=<name>` imprime cada variavel resolvida com
todo valor do schema de credenciais substituido por `[REDACTED]`. Nunca
imprime o conteudo bruto de `credentials.yaml`.

## Scaffold de projeto

O `cluster.sh create-project` nao embute mais IPs, usuarios ou senhas
concretos de site no `vars.sh`/`vars.local.example.sh` gerados — esses
valores ficam vazios, com orientacao inline para usar `vars.local.sh` ou o
arquivo de credenciais do ambiente XDG. Tambem gera um `config.yaml`
versionado e nao-secreto no diretorio do projeto, para uso como a camada de
intencao de projeto descrita acima.
