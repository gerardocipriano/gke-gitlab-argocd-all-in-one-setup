# Demo Kargo: GitOps con promozione automatizzata tra ambienti

## 1. Cos'è Kargo e che problema risolve

ArgoCD sincronizza un branch o un path verso un cluster Kubernetes. Funziona bene, ma non sa nulla di "questa versione ha superato l'ambiente dev e ora va in staging". Questa logica vive fuori da ArgoCD: in una pipeline CI, in uno script, nella testa di qualcuno.

Kargo aggiunge quel livello. Osserva le sorgenti di artefatti (immagini Docker, repository Helm, chart OCI), le impacchetta in unità chiamate Freight e le fa avanzare lungo una catena di ambienti definiti nello stesso cluster. La promozione avviene scrivendo su git: Kargo committa i manifest renderizzati su un branch dedicato e poi chiede ad ArgoCD di sincronizzarsi.

Kargo non applica nulla al cluster direttamente. Committa e lascia sincronizzare ArgoCD. Questo è il punto: resta GitOps. Il repository git rimane l'unica sorgente di verità, e Kargo è solo chi decide quando e come aggiornarla.

## 2. I concetti

### Project

Un Project raggruppa tutte le risorse Kargo relative a una applicazione o a una pipeline di promozione. È cluster-scoped e crea automaticamente il namespace in cui lavorano le sue risorse. Nella demo, il Project si chiama `kargo-demo` e vive in `manifests/kargo-project/project.yaml`. Il namespace omonimo nasce dalla definizione del Project: le altre risorse del progetto devono attendere che sia sincronizzato (sync-wave `-1`).

### Warehouse

Il Warehouse osserva una o più sorgenti di artefatti e produce Freight quando scopre nuove versioni. Nella demo, `manifests/kargo-project/warehouse.yaml` ha due sottoscrizioni: l'immagine `ghcr.io/stefanprodan/podinfo` con il vincolo semver `~6.9.0`, e il repo gitops limitato alla cartella `manifests/kargo-demo`. Ogni combinazione nuova, un tag o un commit, diventa un Freight che porta entrambi i riferimenti.

### Freight

Il Freight è l'unità di promozione. Contiene uno o più riferimenti ad artefatti (immagini, chart) e porta con sé tutta la catena di provenienza. Non è un artefatto fisico: è un record in Kargo che dice "questa combinazione di versioni è pronta per essere promossa". Il Warehouse crea i Freight, gli Stage li consumano.

### Stage

Gli Stage rappresentano gli ambienti della pipeline di promozione. Nella demo ci sono tre Stage: `dev`, `staging` e `prod`, definiti in `manifests/kargo-project/stages.yaml`. Ogni Stage dichiara da dove ricevere i Freight tramite il campo `requestedFreight`. Lo Stage `dev` li riceve direttamente dal Warehouse (`sources.direct: true`). Lo Stage `staging` li riceve dallo Stage `dev`. Lo Stage `prod` li riceve dallo Stage `staging`. Questo crea una catena obbligata: non si può saltare un ambiente.

### Promotion

La Promotion è l'atto di avanzare un Freight da uno Stage al successivo. Avviene dalla UI di Kargo, dalla CLI `kargo promote` o dall'API che sta dietro a entrambe, sempre con un utente Kargo autorizzato sul progetto. In dev parte da sola, per la promotionPolicy nel `ProjectConfig`. Quando si promuove, Kargo esegue i passi definiti nella PromotionTask associata allo Stage.

### PromotionTask

La PromotionTask definisce la sequenza di operazioni da eseguire durante una promozione. Nella demo, `manifests/kargo-project/promotion-task.yaml` definisce `demo-promo-process`, un processo di 7 step che clona il commit contenuto nel Freight, renderizza i manifest e li committa su un branch dedicato. Ogni Stage referenzia questa PromotionTask nel suo `promotionTemplate`.

### Freight lineage

La catena di provenienza dei Freight è definita dal campo `requestedFreight[].sources` in ogni Stage. `sources.direct: true` significa che lo Stage consuma direttamente dal Warehouse. `sources.stages: [dev]` significa che lo Stage consuma solo dopo che il Freight è stato promosso nello Stage elencato. Questo meccanismo garantisce che la pipeline venga percorsa in ordine: dev, poi staging, poi prod.

## 3. Come è fatta questa demo

### Layout dei manifest

La demo usa il pattern render-to-branch. I manifest dell'applicazione sono organizzati in un overlay base e tre overlay per stage:

```
manifests/kargo-demo/
  base/
    deployment.yaml        # Deployment podinfo, 1 replica, tag gestito da kustomize
    service.yaml           # Service ClusterIP sulla porta 80
    kustomization.yaml     # Definisce risorse e immagine di base
  stages/
    dev/
      kustomization.yaml   # Overlay: 1 replica, label kargo.akuity.io/stage: dev
    staging/
      kustomization.yaml   # Overlay: 2 repliche, label kargo.akuity.io/stage: staging
    prod/
      kustomization.yaml   # Overlay: 3 repliche, label kargo.akuity.io/stage: prod
```

La base kustomize è condivisa. Gli overlay cambiano solo il numero di repliche e aggiungono una label per identificare lo stage.

### Il pattern render-to-branch

Kargo non applica i manifest al cluster. Il processo è:

1. Clona il repo gitops al commit contenuto nel Freight, non la punta di `main`
2. Aggiorna l'immagine nella base kustomize con il tag del Freight
3. Esegue `kustomize build` sull'overlay dello stage target
4. Scrive il risultato (`manifests.yaml`) su un branch dedicato: `stage/dev`, `stage/staging`, o `stage/prod`
5. Committa e pusha
6. Chiede ad ArgoCD di sincronizzarsi dal nuovo commit

ArgoCD applica YAML già renderizzati. Non deve eseguire kustomize, non deve risolvere dipendenze. Il diff tra ambienti è leggibile direttamente in git: il branch `stage/dev` contiene i manifest pronti per dev, il branch `stage/prod` quelli per prod.

### Diagramma del flusso

```
                  +---------------------+
                  |  ghcr.io             |
                  |  podinfo 6.9.x + git |
                  +----------+----------+
                             |
                     [1] osserva nuovi tag
                             |
                  +----------v----------+
                  |     Warehouse       |
                  |   kargo-demo        |
                  +----------+----------+
                             |
                     [2] produce Freight
                             |
                  +----------v----------+
                  |      Freight        |
                  +----------+----------+
                             |
                     [3] promuovi a dev
                             |
                  +----------v----------+
                  |     Stage dev       |
                  +----------+----------+
                             |
                     [4] PromotionTask
                   (render-to-branch)
                             |
                  +----------v----------+
                  |  branch stage/dev   |
                  |  (manifests.yaml)   |
                  +----------+----------+
                             |
                     [5] ArgoCD sync
                             |
                  +----------v----------+
                  | namespace            |
                  | kargo-demo-dev       |
                  | 1 replica podinfo    |
                  +----------------------+

         +---------------------+       +---------------------+
         |     Stage staging   |       |     Stage prod      |
         |  (riceve da dev)    |       |  (riceve da staging)|
         +----------+----------+       +----------+----------+
                    |                             |
            branch stage/staging           branch stage/prod
            2 repliche podinfo            3 repliche podinfo
```

## 4. I 7 step della PromotionTask

La PromotionTask `demo-promo-process` (`manifests/kargo-project/promotion-task.yaml`) esegue questi passi:

| # | Step | Cosa fa |
|---|------|---------|
| 1 | `git-clone` | Clona il repo GitOps, fa checkout del commit contenuto nel Freight in `./src` e del branch `stage/{stage}` in `./out` |
| 2 | `git-clear` | Svuota la directory `./out` per partire da uno stato pulito |
| 3 | `kustomize-set-image` | Aggiorna il tag dell'immagine nella base kustomize con quello del Freight |
| 4 | `kustomize-build` | Esegue `kustomize build` sull'overlay dello stage e scrive il risultato in `./out/manifests.yaml` |
| 5 | `git-commit` | Committa i manifest renderizzati in `./out`, con messaggio "promote podinfo X + config Y to stage" |
| 6 | `git-push` | Pusha il commit sul branch `stage/{stage}` |
| 7 | `argocd-update` | Aggiorna l'Application ArgoCD per sincronizzarsi con il nuovo commit |

## 5. Eseguire la demo

Il percorso consigliato è `./demo.sh prepare` prima della sessione e `./demo.sh` davanti al
pubblico: i capitoli sono descritti nel README. Questa sezione descrive gli stessi passi a mano,
per chi vuole capire cosa fa lo script.

Kargo richiede cert-manager: il suo chart crea `Certificate` e `Issuer` per l'API e per i
webhook server, che con Kubernetes parlano solo in TLS. Lo installa il comando `kargo` prima
di Kargo stesso, e il teardown lo rimuove.

### 1. Bootstrap completo

```bash
./bootstrap.sh all
```

Lo script crea il cluster kind, installa GitLab CE e ArgoCD, inizializza il repo GitOps e installa Kargo. Il provider di default è `kind`.

### 2. Accedere alla UI

Dopo il bootstrap, avvia il port-forwarding:

```bash
./bootstrap.sh portforward
```

Le credenziali vengono mostrate a schermo. I riferimenti sono:

| Servizio | URL | Utente | Password |
|----------|-----|--------|----------|
| GitLab | http://localhost:8080 | root | `Gk3B00tstr4p2025xZ` |
| ArgoCD | https://localhost:8443 | admin | (generata, da `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" \| base64 -d`) |
| Kargo | https://localhost:8081 | admin | `Karg0D3m02025xZ` |

### 3. Primo avvio: Warehouse e Freight

Accedi alla UI di Kargo all'indirizzo `https://localhost:8081`. Dopo il login, verifica che il Warehouse `kargo-demo` abbia scoperto i tag di `ghcr.io/stefanprodan/podinfo` che soddisfano `~6.9.0` e l'ultimo commit di `manifests/kargo-demo`.

### 4. Promozione su dev

dev ha `autoPromotionEnabled` nelle promotionPolicies del `ProjectConfig`: appena il Warehouse produce un Freight, la promozione parte da sola. Cosa succede:

- Kargo esegue la PromotionTask `demo-promo-process`
- Il branch `stage/dev` viene creato o aggiornato nel repo gitops
- ArgoCD sincronizza l'Application `kargo-demo-dev` dal branch `stage/dev`
- Viene creato il namespace `kargo-demo-dev` con 1 replica di podinfo

Verifica su GitLab: il branch `stage/dev` nel repo `root/gitops` contiene il file `manifests.yaml` con i manifest renderizzati.

Verifica sul cluster:

```bash
kubectl get pods -n kargo-demo-dev
```

Dovresti vedere un pod podinfo con stato `Running`.

### 5. Promuovere su staging e prod

Ripeti la promozione dalla UI di Kargo per lo Stage `staging`, poi per `prod`. A ogni promozione cambia il numero di repliche:

- `staging`: 2 repliche
- `prod`: 3 repliche

Verifica:

```bash
kubectl get pods -n kargo-demo-staging
kubectl get pods -n kargo-demo-prod
```

### 6. Promozione da riga di comando (opzionale)

`kubectl create` di una `Promotion` viene rifiutato dal webhook di Kargo anche per un
cluster-admin, se l'utente Kubernetes non è mappato su un account Kargo del progetto. Si passa
dalla CLI, dopo il login admin (la password viene chiesta in modo interattivo):

```bash
kargo login https://localhost:8081 --admin --insecure-skip-tls-verify
kargo promote --project kargo-demo --stage staging --freight <nome-freight>
```

`demo.sh` usa la stessa API della CLI e della UI (`PromoteToStage`), con un token ottenuto da
`AdminLogin`: vedi `kargo_promote` in `lib/presenter.sh`.

## 6. Troubleshooting

| Sintomo | Causa | Comando di verifica |
|---------|-------|---------------------|
| Stage in errore per credenziali git mancanti | Il secret `gitops-repo` non esiste nel namespace del progetto. Lo script `kargo_deploy` lo crea automaticamente, ma potrebbe non aver trovato il PAT di GitLab. | `kubectl get secret gitops-repo -n kargo-demo` |
| Application ArgoCD `kargo-demo-dev` in stato Unknown | Il branch `stage/dev` non esiste ancora nel repo gitops. Lo Stage non ha mai promosso un Freight. | `kubectl get applications -n argocd kargo-demo-dev -o yaml \| grep -A5 status` |
| Promozione bloccata sullo step `argocd-update` | L'annotazione `kargo.akuity.io/authorized-stage` manca o non corrisponde allo Stage che sta promuovendo. | `kubectl get applications -n argocd kargo-demo-dev -o jsonpath='{.metadata.annotations}'` |
| Warehouse senza Freight | Il cluster non riesce a raggiungere il registry pubblico `ghcr.io`. Possibile restrizione di rete o DNS. | `kubectl logs -n kargo deployment/kargo-api \| grep -i error` |
| Namespace del progetto non trovato | Il Project non è stato ancora sincronizzato da ArgoCD o c'è un ritardo nel sync-wave. | `kubectl get namespaces \| grep kargo-demo` |
| Errore di autenticazione nella UI Kargo | La password hash non corrisponde. Verifica che htpasswd o docker siano disponibili per generarla correttamente. | `kubectl get secret -n kargo -l app.kubernetes.io/name=kargo-api -o jsonpath='{.items[0].data}'` |

Tre inciampi visti sul campo, già risolti nel repo ma utili da riconoscere:

- Promotion in `Errored` con `could not read Username for http://...`: il controller rifiuta
  di usare credenziali git su HTTP. Il chart viene installato con
  `controller.allowCredentialsOverHTTP=true` perché GitLab qui gira senza TLS.
- `autoPromotionEnabled` ignorato: da Kargo 1.9 le promotionPolicies stanno nella
  `ProjectConfig`, non nello `spec` del `Project`, che viene scartato in silenzio.
- `kubectl create promotion` rifiutato dall'admission webhook: le promozioni si lanciano
  dalla UI, dalla CLI o dall'API come utente di Kargo. Un utente Kubernetes non mappato a un
  account Kargo non è autorizzato, anche se è cluster-admin.
- Application `OutOfSync` subito dopo una promozione riuscita: ArgoCD confronta il cluster con
  la HEAD del branch che ha in cache. Un refresh
  (`argocd.argoproj.io/refresh=normal`) la riporta a `Synced`.

## 7. Smontare la demo

La pulizia è granulare: ogni componente ha il suo comando, così si può rifare un pezzo
senza ricreare tutto.

```bash
./bootstrap.sh delete-kargo     # Stage, Warehouse, Project, release Helm
./bootstrap.sh delete-argocd    # Application, AppProject, installazione
./bootstrap.sh delete-gitops    # progetto gitops dentro GitLab
./bootstrap.sh delete-gitlab    # namespace GitLab
./bootstrap.sh clean            # il cluster
```

Il comando `teardown` li esegue in ordine inverso al bootstrap, chiedendo conferma prima di
ogni blocco. Il cluster resta in piedi se non lo si chiede esplicitamente:

```bash
./bootstrap.sh teardown
ASSUME_YES=1 ./bootstrap.sh teardown                    # niente domande, cluster escluso
ASSUME_YES=1 DELETE_CLUSTER=1 ./bootstrap.sh teardown   # cluster incluso
```

Una nota che conta: finché ArgoCD è vivo, la root Application `apps` ricrea le Application
cancellate a mano. Per una rimozione definitiva si toglie il manifest dal repo gitops, oppure
si cancella prima ArgoCD.
