# Contrato de Handoff Cilium Day-1/Day-2 (Argo CD) (PT-BR)

## Contrato

O Cilium e instalado duas vezes, por design, em dois modos diferentes:

1. **Day-1 (imperativo)**: `apply-post-bootstrap.sh` sincroniza os manifests
   Helm do addon a partir do repositorio GitOps (`environments/<env>/helm/`)
   para o projeto do cluster, e `phase-network-bringup.sh` renderiza e
   instala o Cilium via `helm upgrade --install` antes de o Argo CD existir,
   porque o Cilium fornece o CNI necessario para a rede do Kubernetes (e,
   depois, para o proprio Argo CD) funcionar.
2. **Day-2 (declarativo)**: apos o bootstrap do Argo CD
   (`talos-gitops.sh deploy-argocd-root-app`), a Application `addon-cilium`
   do repositorio GitOps adota e passa a reconciliar exclusivamente o mesmo
   Helm release dali em diante.

A adocao so e segura se o day-2 reconciliar o **mesmo** chart, versao do
chart, valores renderizados, identidade do Helm release e revisao Git que o
day-1 fez o bootstrap. Uma divergencia aqui (uma sincronizacao desatualizada,
uma edicao de valores aplicada em apenas um lado, ou uma mistura de revisao
`lab`/`main`) pode fazer o Argo tentar alterar ou substituir um CNI em
execucao logo apos o bootstrap.

## Validando o handoff offline

`scripts/talos/validate-cilium-handoff.sh` verifica esse acordo sem contatar
Talos, Kubernetes, Helm, Argo CD ou qualquer endpoint VMware/ao vivo. Ele
compara:

- um `helm/cilium/release.yaml` sincronizado do day-1 (chart, versao, nome do
  release, namespace, arquivo de valores resolvido), com
- a `Application` do Argo CD em
  `environments/<env>/argocd/apps/cilium.yaml` no repositorio GitOps (fonte
  do chart Helm OCI, fonte de referencia de valores, namespace de destino,
  politica de sincronizacao).

Ele falha em:

- **Divergencia de revisao de ambiente**: o `targetRevision` da fonte de
  referencia de valores nao e igual a `--environment` (o mesmo contrato
  `lab`/`main` documentado em `docs/en/branch-revision-promotion.md` do
  `talos-vsphere-gitops`).
- **Divergencia de identidade renderizada**: chart, versao do chart, nome do
  release ou namespace diferem entre o day-1 e a `Application` do GitOps.
- **Divergencia de conteudo de valores**: o arquivo de valores resolvido do
  day-1 e o arquivo de valores referenciado pelo GitOps nao produzem o mesmo
  hash.
- **Adocao nao automatizada**: `syncPolicy.automated.prune`/`selfHeal` nao
  sao ambos `true`, entao o Argo nao assumiria a reconciliacao sozinho.

```bash
./scripts/talos/validate-cilium-handoff.sh \
  --day1-release=<project-dir>/helm/cilium/release.yaml \
  --gitops-repo-root=<caminho-do-checkout-talos-vsphere-gitops> \
  --environment=lab
```

Execute antes de `talos-gitops.sh deploy-argocd-root-app` (ou qualquer etapa
de bootstrap do Argo) como um gate pre-adocao. Uma saida diferente de zero
significa corrigir a divergencia em um dos dois repositorios antes de deixar
o Argo adotar o Cilium, e nao apagar/pausar os recursos gerados.

## Pre-requisito de prontidao antes da adocao

O Argo CD adota um Helm release existente no lugar (em vez de instalar um
segundo release conflitante) somente quando o nome do release e o namespace
que ele vai gerenciar ja correspondem ao que o day-1 criou. As checagens de
identidade acima sao exatamente esse pre-requisito de prontidao, verificado
offline antes de o operador executar a etapa de bootstrap do Argo.

## Rollback / recuperacao em caso de falha de reconciliacao do CNI

Se a sincronizacao do `addon-cilium` no Argo CD falhar ou degradar a rede do
cluster apos a adocao:

1. **Nao** execute novamente `apply-post-bootstrap.sh` /
   `phase-network-bringup.sh` para `cilium`, e nao chame
   `talos-gitops.sh install-addon --addon=cilium` ou `install-platform-helm`
   sem exclusao. `cilium` e uma entrada fixa em
   `SYSTEM_EXCLUDE_ADDONS_RAW` no `talos-gitops.sh`, e
   `install-addon --addon=cilium` recusa a execucao
   (`Addon 'cilium' is system-excluded in day-2 flow.`) uma vez que o Argo
   possui o release, justamente para evitar uma segunda escrita Helm
   imperativa concorrendo com a reconciliacao do Argo CD.
2. Corrija a divergencia de forma declarativa: ajuste os valores/versao do
   chart no `talos-vsphere-gitops` e deixe o `selfHeal` do Argo CD
   reconciliar, ou reverta o commit/`targetRevision` responsavel nesse
   repositorio e deixe o Argo convergir de volta ao ultimo estado bom
   conhecido.
3. Execute novamente `validate-cilium-handoff.sh` apos a correcao para
   confirmar o acordo day-1/day-2 antes de considerar o cluster saudavel
   novamente.

## Testes

`scripts/talos/tests/test-cilium-handoff.sh` executa o validador contra
fixtures consistentes e divergentes em
`scripts/talos/tests/fixtures/cilium-handoff/`, e confirma que
`talos-gitops.sh install-addon --addon=cilium` e recusado. Nenhuma chamada
real a Kubernetes/Helm/VMware e feita; uma fixture `kubectl` stub apenas
responde a checagem de contexto do preflight.

```bash
bash scripts/talos/tests/test-cilium-handoff.sh
```
