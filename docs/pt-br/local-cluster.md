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
- `--cni=cilium` exige adicionalmente `helm`, `kubectl`, `git` e `curl` no
  `PATH` (veja [Modo local Cilium](#modo-local-cilium) abaixo).

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

### O modelo padrao de patches e o projeto por cluster

Os patches de machine-config do `--cni=cilium` nunca sao uma string inline
escrita a mao. Eles vem de um modelo padrao mantido, focado em Cilium, dentro
do checkout do toolchain:

```text
scripts/talos/local-cluster-patches/defaults/
├── cni.patch.yaml      # todos os tipos de no (--config-patch)
├── cp.patch.yaml       # somente control-plane (--config-patch-controlplanes)
└── worker.patch.yaml   # somente workers (--config-patch-workers)
```

Esse modelo nunca e aplicado no lugar. O `create --name=<nome> --cni=cilium`
materializa uma copia no diretorio de destino do cluster e entrega ao
`talosctl` os caminhos do destino — assim cada nome de cluster ganha seu
proprio projeto de patches editavel:

```text
~/.local/state/talos-toolchain/local-clusters/<nome>/
├── patches/            # entradas de machine-config deste cluster
│   ├── cni.patch.yaml
│   ├── cp.patch.yaml
│   └── worker.patch.yaml
├── talos-state/
├── talosconfig
├── kubeconfig
└── create.log
```

Um arquivo ja existente no destino **nunca e sobrescrito**. Uma vez que os
patches de um cluster existem, eles sao o registro do que foi aplicado naquele
cluster; entao reexecutar o `create` informa `Keeping existing patch ...` e
preserva as edicoes do operador — o mesmo contrato de "criar se ausente" que o
`cluster.sh create-project` usa. O `destroy` os remove junto com o resto do
diretorio do cluster. As copias sao literais, apenas com um cabecalho de
procedencia adicionado: sem linguagem de template e sem substituicao de
variaveis, entao o que chega ao destino e YAML de machine-config que voce pode
comparar com o modelo e editar a mao.

Os nomes de arquivo espelham o vocabulario do projeto de referencia
`talos-dev` (`cni`/`cp`/`worker`), para que um mesmo nome signifique a mesma
coisa nos dois fluxos. Eles sao o subconjunto dos patches do `talos-dev` que
faz sentido no backend Docker: os patches de rede estatica por no e o patch de
disco do Longhorn nao tem equivalente no Docker, ja que o Docker atribui
enderecos na propria subrede e nao existe um segundo dispositivo de bloco para
particionar.

Os nomes de flag por papel estao no plural porque e isso que o backend
Docker aceita. O `talosctl cluster create docker` recebe
`--config-patch-controlplanes` / `--config-patch-workers`, enquanto o
`talosctl gen config` recebe as formas singulares
`--config-patch-control-plane` / `--config-patch-worker`. Os dois subcomandos
nao compartilham a grafia, e passar aqui a forma do `gen config` faz o binario
real sair com `unknown flag` antes de criar um unico container.

`cni.patch.yaml` define `cluster.network.cni.name` como `none` e desabilita o
kube-proxy gerenciado (`cluster.proxy.disabled: true`), para que o Cilium
assuma tanto a rede de pods quanto o balanceamento de servicos desde o dia 1,
em vez de competir ou conflitar com os padroes gerenciados. `cp.patch.yaml` e
`worker.patch.yaml` trazem os overrides de DNS de host por papel usados
enquanto o Cilium/CoreDNS ainda estao subindo. Tudo isso e local ao
`talos-toolchain` e ao seu diretorio de estado isolado: nunca e lido de, nem
escrito em, `talos-dev` ou qualquer caminho `provision-talos-vsphere`/VMware,
e so se aplica no modo `--cni=cilium` — o modo padrao `--cni=flannel` nunca
materializa um projeto de patches e nunca emite nenhuma dessas flags.

### Ciclo de vida em duas etapas, em ordem

Esta e uma sequencia deliberada de duas etapas: a Etapa 1 desabilita o CNI e
o kube-proxy gerenciados antes do bootstrap do Talos para que o Cilium possa
assumir o cluster sem disputa; a Etapa 2 condiciona a instalacao do
Cilium/Helm a uma prontidao genuina da API do Kubernetes, nao apenas a um
mapeamento de porta do Docker, e so entao valida Cilium/CoreDNS.

1. **Preflight do GitOps** (somente leitura, sem interacao com Colima/Docker):
   verifica que `--gitops-repo-root` e um checkout Git no branch `lab` com
   arvore de trabalho limpa, e que `environments/lab/helm/cilium/release.yaml`
   e `environments/lab/argocd/apps/cilium.yaml` existem. Nunca modifica esse
   checkout.
2. **Etapa 1 — projeto de patches materializado, CNI e kube-proxy do Talos
   desabilitados antes do bootstrap, create roda em segundo plano**: o modelo
   padrao e materializado em `<diretorio-do-cluster>/patches/` (arquivos
   existentes sao preservados) e entao o `talosctl cluster create docker` e
   invocado com o `cni.patch.yaml` do proprio cluster (via
   `--config-patch @<diretorio-do-cluster>/patches/cni.patch.yaml`),
   `cp.patch.yaml` (via `--config-patch-controlplanes`) e `worker.patch.yaml`
   (via `--config-patch-workers`). O backend Docker nao expoe um equivalente a
   `--wait=false`, e sua espera interna de prontidao bloqueia ate o
   Kubernetes/CoreDNS ficar saudavel — o que nunca aconteceria sozinho com
   CNI `none`. Por isso, somente no modo `--cni=cilium`, esse comando e
   iniciado em segundo plano (sua saida capturada em
   `<diretorio-do-cluster>/create.log`) enquanto o wrapper executa as etapas
   3–7 abaixo simultaneamente, terminando com um `wait` sobre ele na etapa
   8. O modo padrao (`--cni=flannel`, ou sem `--cni`) continua executando
   `talosctl cluster create docker` de forma sincrona, totalmente
   inalterado, e nunca referencia o projeto de patches `talos-lab`.
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
6. **Etapa 2, gate — `/readyz` da API do Kubernetes**: um mapeamento de porta
   publicado do Docker prova apenas que a porta do container esta
   encaminhada, nao que o `kube-apiserver` dentro dele realmente terminou de
   iniciar. Antes de qualquer acao relacionada ao Cilium, o wrapper consulta
   `/readyz` (a cada 2s, por ate 600s) usando o kubeconfig isolado que acabou
   de obter — `KUBECONFIG=<diretorio-do-cluster>/kubeconfig kubectl get
   --raw=/readyz` — ate obter `ok`. Isso funciona mesmo com o CNI ainda `none`
   e sem rede de pods, porque o servidor da API em si nao depende do CNI. Em
   caso de timeout, o `create` falha e nenhuma acao Helm chega a ser
   tentada.

   A sonda precisa ser autenticada. O Talos roda o `kube-apiserver` com
   autenticacao anonima desabilitada, entao uma requisicao nao autenticada a
   `/readyz` e respondida com `401` por mais pronto que o cluster esteja. Uma
   versao anterior desse gate usava `curl -k` e esperava HTTP `200`: ficou o
   orcamento inteiro observando `401`s em um control plane ja completamente
   pronto e entao reportou timeout. Sondar via `kubectl` com as credenciais do
   proprio cluster corrige isso e le prontidao de verdade, em vez de inferi-la
   de "alguem respondeu".

   O orcamento e de minutos, nao de segundos, de proposito. O mapeamento de
   porta do Docker e publicado quando o container e criado, entao essa
   contagem comeca bem antes de o cluster estar bootstrapado: o gate na
   verdade espera a cadeia inteira — API do Talos no ar, `talosctl cluster
   create docker` executando seu passo de bootstrap, etcd convergindo para
   `Running` e so entao o `kube-apiserver` atendendo. Um control plane local
   costuma levar cinco minutos ou mais ate esse ponto. O progresso e logado a
   cada 30s para que um bootstrap saudavel porem silencioso nao seja
   confundido com travamento, e `TALOS_LOCAL_CLUSTER_API_READYZ_WAIT_SECONDS`
   aumenta o orcamento em hosts mais lentos. Se esse gate estourar, leia
   `<diretorio-do-cluster>/create.log` antes de supor uma falha real — uma
   linha como `waiting for etcd to be healthy: ... current state [Preparing]`
   seguida de `context canceled` significa que o cluster ainda estava subindo
   normalmente e apenas ficou sem orcamento.
7. **Bootstrap do Cilium dia-1**: somente apos o gate `/readyz` passar,
   `validate-cilium-handoff.sh` roda contra o mesmo checkout GitOps antes de
   qualquer instalacao (como o Cilium do dia-1 aqui le
   `environments/lab/helm/cilium/{release,values}.yaml` diretamente desse
   checkout, nao uma copia sincronizada, essa correspondencia de identidade
   e estrutural, nao apenas provavel); depois `phase-network-bringup.sh
   --helm-root=<checkout gitops>/environments/lab/helm --addon=cilium` (a
   mesma fase Helm usada para clusters vSphere, em seu modo sem arquivo de
   vars de projeto) renderiza, valida com dry-run server-side, e executa
   `helm upgrade --install` do Cilium; entao o wrapper aguarda o
   `deployment/coredns` em `kube-system` concluir o rollout. E isso que
   permite que a espera de saude do comando de create em segundo plano
   (etapa 2) consiga ter sucesso.
8. **Espera e propagacao do resultado do create em segundo plano**: somente
   depois que Cilium/CoreDNS forem confirmados saudaveis o wrapper executa
   `wait` sobre o processo `talosctl cluster create docker` em segundo
   plano e propaga seu status de saida real — sucesso apenas se esse
   processo tambem terminar com `0`. Em `SIGINT`/`SIGTERM` a qualquer
   momento durante as etapas 3–8, o wrapper encerra e faz o reap (espera
   pela finalizacao) desse processo em segundo plano antes de sair com
   status diferente de zero, em vez de deixa-lo orfao.

A adocao GitOps de dia-2 (Argo CD assumindo a reconciliacao do Cilium via
`talos-gitops.sh`) permanece inalterada e fora do escopo deste wrapper; este
modo executa apenas o bootstrap imperativo de dia-1.

Em caso de falha em qualquer etapa (incluindo uma interrupcao), nada e
destruido automaticamente: o estado de Talos/Cilium que existir e mantido,
junto com `<diretorio-do-cluster>/create.log` capturando a propria saida do
create em segundo plano (veja "Recuperando um cluster criado parcialmente"
abaixo), e nenhum processo `talosctl` fica rodando sem supervisao.

A marca do wrapper e escrita **antes** de o backend iniciar, registrando
`state=creating`, e so e promovida a `state=ready` depois que todas as
etapas acima tiverem sucesso e o processo de create em segundo plano tiver
sido finalizado (reaped). Assim, um create parcialmente falho nunca e
confundido com um completo e — diferente das versoes anteriores, que
escreviam a marca apenas em caso de sucesso — o cluster deixado para tras
continua destruivel por este wrapper, sem exigir `docker rm` e `rm -rf`
manuais.

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
   cluster e remover o diretorio de estado isolado. Isso vale tanto para
   `state=creating` quanto para `state=ready`: um create interrompido
   continua sendo responsabilidade deste wrapper, e o `status` informa em
   qual dos dois estados a marca esta.
3. Se a marca estiver ausente, o `destroy` se recusa a tocar no diretorio,
   por design — o wrapper so destroi clusters que ele mesmo criou. Como a
   marca agora e escrita antes de o backend rodar, isso so deve acontecer
   com clusters criados fora do wrapper ou por uma versao anterior a esta.
   Inspecione `.../local-clusters/<name>/talos-state` voce mesmo e, se tiver
   certeza de que e seguro, remova-o manualmente antes de tentar `create`
   novamente com o mesmo `--name`.

O wrapper nunca apaga ou inspeciona esse estado automaticamente fora de uma
execucao explicita e confirmada de `destroy`.
