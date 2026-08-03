# Cluster Talos Local (Docker/Colima, Marco A)

## Escopo

`scripts/talos/local-cluster.sh` e um wrapper dedicado em torno de `talosctl
cluster create docker` para um unico cluster local isolado de
desenvolvimento. Ele usa o subcomando explicito do backend Docker, e nao a
forma generica descontinuada `talosctl cluster create --provisioner docker`
— nas versoes atuais do `talosctl` essa forma descontinuada e redirecionada
para `cluster create dev`, que seleciona QEMU em vez de Docker. E um
entrypoint separado do `cluster.sh`, voltado ao vSphere:

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
- `--cni=cilium` exige adicionalmente `helm`, `kubectl` e `git` no `PATH`
  (veja [Modo local Cilium](#modo-local-cilium) abaixo).

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

## Modo local Cilium

`create --cni=cilium --gitops-repo-root=<path>` substitui o Flannel
gerenciado pelo Talos por padrao por um bootstrap local deliberado do
Cilium no dia-1, usando exatamente a identidade e os values do release
`lab` do `talos-vsphere-gitops` ja cobertos por
`validate-cilium-handoff.sh`. Isso resolve uma falha real no runtime Linux
do Colima: os pods do Flannel gerenciado quebram la porque
`/proc/sys/net/bridge/bridge-nf-call-iptables` esta ausente, o que deixa o
CoreDNS incapaz de criar seu sandbox.

```bash
./scripts/talos/local-cluster.sh create --name=dev --cni=cilium \
  --gitops-repo-root=../talos-vsphere-gitops --dry-run
./scripts/talos/local-cluster.sh create --name=dev --cni=cilium \
  --gitops-repo-root=../talos-vsphere-gitops
```

O que este modo faz, em ordem:

1. **Preflight do GitOps** (somente leitura, sem interacao com Colima/Docker):
   verifica que `--gitops-repo-root` e um checkout Git no branch `lab` com
   arvore de trabalho limpa, e que `environments/lab/helm/cilium/release.yaml`
   e `environments/lab/argocd/apps/cilium.yaml` existem. Nunca modifica esse
   checkout.
2. **CNI do Talos desabilitado, create roda em segundo plano**: `talosctl
   cluster create docker` e invocado com um `--config-patch` que define
   `cluster.network.cni.name` como `none`. O backend Docker nao expoe um
   equivalente a `--wait=false`, e sua espera interna de prontidao bloqueia
   ate o Kubernetes/CoreDNS ficar saudavel — o que nunca aconteceria sozinho
   com CNI `none`. Por isso, somente no modo `--cni=cilium`, esse comando e
   iniciado em segundo plano (sua saida capturada em
   `<diretorio-do-cluster>/create.log`) enquanto o wrapper executa as etapas
   3–6 abaixo simultaneamente, terminando com um `wait` sobre ele na etapa
   7. O modo padrao (`--cni=flannel`, ou sem `--cni`) continua executando
   `talosctl cluster create docker` de forma sincrona, totalmente
   inalterado.
3. **Busca do kubeconfig, com novas tentativas**: `talosctl kubeconfig` e
   tentado repetidamente (a cada 3s, por ate 120s) contra o cluster ainda em
   inicializacao ate que a API do Talos responda, ja que ela pode nao estar
   acessivel no instante logo apos o comando de create em segundo plano
   iniciar.
4. **Publicacao da API em loopback**: a porta da API Kubernetes do container
   de control plane e publicada em uma porta de host `127.0.0.1` atribuida
   dinamicamente (`--host-ip 127.0.0.1 --exposed-ports 0:6443/tcp`), depois
   descoberta via `docker port` (verificado por ate 60s) assim que o
   container esta em execucao.
5. **Reescrita do kubeconfig isolado**: o `kubeconfig` isolado do proprio
   wrapper (nunca o `~/.kube/config` padrao do operador) tem seu campo
   `server:` reescrito do endereco interno da rede Docker que o `talosctl
   kubeconfig` embutiria (por exemplo `10.5.0.2:6443`) para o endpoint
   descoberto `127.0.0.1:<porta-publicada>`.
6. **Bootstrap do Cilium dia-1**: `validate-cilium-handoff.sh` roda contra o
   mesmo checkout GitOps antes de qualquer instalacao (como o Cilium do
   dia-1 aqui le `environments/lab/helm/cilium/{release,values}.yaml`
   diretamente desse checkout, nao uma copia sincronizada, essa
   correspondencia de identidade e estrutural, nao apenas provavel);
   depois `phase-network-bringup.sh --helm-root=<checkout
   gitops>/environments/lab/helm --addon=cilium` (a mesma fase Helm usada
   para clusters vSphere, em seu novo modo sem arquivo de vars de projeto)
   renderiza, valida com dry-run server-side, e executa `helm upgrade
   --install` do Cilium; entao o wrapper aguarda o `deployment/coredns` em
   `kube-system` concluir o rollout. E isso que permite que a espera de
   saude do comando de create em segundo plano (etapa 2) consiga ter
   sucesso.
7. **Espera e propagacao do resultado do create em segundo plano**: somente
   depois que Cilium/CoreDNS forem confirmados saudaveis o wrapper executa
   `wait` sobre o processo `talosctl cluster create docker` em segundo
   plano e propaga seu status de saida real — sucesso apenas se esse
   processo tambem terminar com `0`. Em `SIGINT`/`SIGTERM` a qualquer
   momento durante as etapas 3–7, o wrapper encerra e faz o reap (espera
   pela finalizacao) desse processo em segundo plano antes de sair com
   status diferente de zero, em vez de deixa-lo orfao.

A adocao GitOps de dia-2 (Argo CD assumindo a reconciliacao do Cilium via
`talos-gitops.sh`) permanece inalterada e fora do escopo deste wrapper; este
modo executa apenas o bootstrap imperativo de dia-1.

Em caso de falha em qualquer etapa (incluindo uma interrupcao), nada e
destruido automaticamente: o estado de Talos/Cilium que existir e mantido,
junto com `<diretorio-do-cluster>/create.log` capturando a propria saida do
create em segundo plano (veja "Recuperando um cluster criado parcialmente"
abaixo), e a marca do wrapper so e escrita depois que todas as etapas acima
tiverem sucesso e o processo de create em segundo plano tiver sido
finalizado (reaped) — assim, um `create --cni=cilium` parcialmente falho
nunca e confundido com um completo, e nenhum processo `talosctl` fica
rodando sem supervisao.

## Limitacoes conhecidas

- Apenas Marco A: `--workers` e configuravel, mas o backend Docker do Talos
  (`talosctl cluster create docker`) nao expoe nenhuma flag de contagem de
  control plane e sempre cria exatamente um control plane. `--controlplanes`
  continua aceito por simetria com o `cluster.sh`, mas o wrapper rejeita
  qualquer valor diferente de `1` antes de acionar o talosctl, em vez de
  ignora-lo silenciosamente. Nao ha upgrade, escalonamento ou orquestracao
  multi-cluster alem de `--name`s independentes.
- Fora do modo `--cni=cilium`, este wrapper nao gerencia Cilium, Argo CD ou
  qualquer bootstrap GitOps; isso continua sendo territorio de
  `talos-vsphere-gitops` / `talos-gitops.sh` para clusters nao locais.
  `--cni=cilium` executa apenas o bootstrap local de dia-1 descrito acima —
  nunca toca no Argo CD nem no estado desejado do checkout GitOps.
- Se o Colima for o backend Docker pretendido e nao estiver rodando, o
  preflight `docker info` do `create` falhara com uma mensagem acionavel;
  inicie o Colima voce mesmo e execute novamente.

## Recuperando um cluster criado parcialmente

Se o `create` falhar no meio do caminho (por exemplo, o `talosctl` tem
sucesso mas a busca do kubeconfig falha, ou o processo e interrompido), o
wrapper deixa em vigor o estado que conseguiu escrever e **nao** tenta
nenhuma limpeza ou nova tentativa automatica. A recuperacao e manual:

1. Execute `status --name=<name>` para ver que estado existe (marca do
   wrapper, diretorio de estado do Talos, saida de `talosctl cluster show`).
   Para `--cni=cilium`, verifique tambem
   `.../local-clusters/<name>/create.log`, a saida capturada do processo
   `talosctl cluster create docker` em segundo plano.
2. Se a marca do wrapper em
   `.../local-clusters/<name>/.talos-toolchain-local-cluster` estiver
   presente, `destroy --name=<name> --confirm-destroy` ira destruir o
   cluster e remover o diretorio de estado isolado.
3. Se a marca estiver ausente (por exemplo, o proprio `talosctl cluster
   create docker` falhou antes de o wrapper conseguir escreve-la), o
   `destroy` se recusa a tocar no diretorio, por design. Inspecione
   `.../local-clusters/<name>/talos-state` voce mesmo e, se tiver certeza de
   que e seguro, remova-o manualmente antes de tentar `create` novamente com
   o mesmo `--name`.

O wrapper nunca apaga ou inspeciona esse estado automaticamente fora de uma
execucao explicita e confirmada de `destroy`.
