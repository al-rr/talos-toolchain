# Cluster Talos Local (Docker/Colima, Marco A)

## Escopo

`scripts/talos/local-cluster.sh` e um wrapper dedicado em torno de `talosctl
cluster create --provisioner docker` para um unico cluster local isolado de
desenvolvimento. E um entrypoint separado do `cluster.sh`, voltado ao vSphere:

- Nunca carrega variaveis de vSphere/VMware e nunca aciona nada em
  `provision-talos-vsphere`.
- Nunca inicia, para ou reconfigura o Colima ou o daemon do Docker. Inicie o
  Colima voce mesmo (`colima start`) antes de usar `create`; o wrapper apenas
  detecta e reporta o estado.
- Cada cluster gerenciado fica isolado em seu proprio diretorio, para que
  talosconfig/kubeconfig/estado do Talos nunca colidam entre si nem com o seu
  `~/.talos` ou `~/.kube/config` padrao.

## Requisitos

- **Bash 5+** (mesmo contrato de preflight do `cluster.sh`; veja
  `docs/pt-br/shell-requirements.md`).
- `talosctl`, o CLI do Docker e o CLI do Colima no `PATH`.
- Um daemon Docker respondendo. `create` e `status` verificam isso com
  `docker info` e nunca tentam iniciar ou configurar o Docker.

## Layout de estado

Cada cluster e identificado por um `--name` seguro (apenas alfanumerico
minusculo e tracos; sem `.`, `/` ou traco no inicio/fim) e enraizado em um
diretorio de estado XDG:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/talos-toolchain/local-clusters/<name>/
├── talos-state/                      # --state passado ao talosctl
├── talosconfig                       # talosconfig isolado deste cluster
├── kubeconfig                        # kubeconfig isolado deste cluster
└── .talos-toolchain-local-cluster    # marca do wrapper (guarda de create/destroy)
```

`--state-root` sobrescreve o diretorio raiz (usado pela suite de testes
offline; nao e necessario no uso normal do operador). Nomes contendo `..` ou
`/` sao rejeitados antes de qualquer caminho ser montado ou diretorio criado.

## Acoes

```bash
# Pre-visualizar, depois criar (padrao: 1 control plane, 1 worker)
./scripts/talos/local-cluster.sh create --name=dev --dry-run
./scripts/talos/local-cluster.sh create --name=dev

# Diagnostico somente leitura: marca do wrapper, estado do Docker/Colima, talosctl cluster show
./scripts/talos/local-cluster.sh status --name=dev

# Pre-visualizar, depois destruir
./scripts/talos/local-cluster.sh destroy --name=dev --dry-run
./scripts/talos/local-cluster.sh destroy --name=dev --confirm-destroy
```

- `create` recusa executar novamente quando ja existe a marca para aquele
  nome; execute `destroy` antes (ou escolha outro `--name`).
- `status` e apenas diagnostico: nunca cria estado e nunca inicia
  Colima/Docker, exista ou nao o cluster ainda.
- `destroy` exige `--confirm-destroy` para executar de fato (`--dry-run`
  pre-visualiza o comando `talosctl cluster destroy` planejado sem
  executa-lo) e recusa tocar em qualquer diretorio que nao tenha a marca
  proprio deste wrapper, para nunca varrer estado alheio de Docker/Talos.
- `--dry-run` nunca altera o host em nenhuma acao: nenhum diretorio e
  criado, nenhuma marca e escrita ou usada para uma decisao destrutiva, e
  nenhum comando externo e executado.

## Limitacoes conhecidas

- Apenas Marco A: as contagens de control-plane/worker sao configuraveis
  (`--controlplanes`, `--workers`), mas nao ha upgrade, escalonamento ou
  orquestracao multi-cluster alem de `--name`s independentes.
- Este wrapper nao gerencia Cilium, Argo CD ou qualquer bootstrap GitOps;
  isso continua sendo territorio de `talos-vsphere-gitops` / `talos-gitops.sh`
  para clusters nao locais, e esta fora do escopo do backend Docker aqui.
- Se o Colima for o backend Docker pretendido e nao estiver rodando, o
  preflight `docker info` do `create` falhara com uma mensagem acionavel;
  inicie o Colima voce mesmo e execute novamente.
