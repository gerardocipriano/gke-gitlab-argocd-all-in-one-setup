# Note operative del repo

Lezioni verificate eseguendo la demo end to end. Qui vanno solo cose generali e riusabili,
non lo stato di un task.

## GKE Autopilot

- **cert-manager**: serve `--set global.leaderElection.namespace=cert-manager`. Di default
  prende il lease in `kube-system`, che è un managed namespace: GKE Warden nega la
  scrittura, il controller resta senza leadership e i Certificate non vengono mai emessi.
  Il sintomo è indiretto: pod Kargo in ContainerCreating sul secret `kargo-api-cert`
  assente, e il job `startupapicheck` che fallisce il post-install hook di Helm.
- **Pod con request alta**: su Autopilot la request dimensiona il nodo, e un pod Burstable
  che sfora la request viene evicted per memoria del nodo. Per GitLab servono
  `requests == limits` a 8Gi: Omnibus dimensiona puma sulle CPU del nodo, non sul limit del
  container, quindi va anche fissato `puma['worker_processes']`.
- **PVC**: i dischi persistenti sopravvivono alla cancellazione del cluster. Dopo un
  teardown controllare `gcloud compute disks list` e cancellarli a mano.
- Le porte host della demo (8080/8443/8081) si spostano con `GITLAB_LOCAL_PORT`,
  `ARGOCD_LOCAL_PORT`, `KARGO_LOCAL_PORT`: utile quando una è occupata da altro in locale.

## Guardie di idempotenza

Non usare la presenza delle CRD per decidere se un chart è installato: le CRD
sopravvivono a `helm uninstall`. Guardare il deployment.

## GitLab CE in cluster

- `gitlab-ctl reconfigure` fallisce su chiavi Omnibus rimosse dalle versioni recenti
  (vista `grafana['enable']`). Il log utile è `FATAL: Mixlib::Config::UnknownConfigOptionError`.
- Le attese su GitLab devono risolvere il pod a ogni tentativo: un riavvio (patch Spot,
  eviction) cambia il nome, e un `kubectl exec` sul pod vecchio fallisce fino al timeout.
- Ogni `gitlab-rails runner` carica Rails da capo e costa circa due minuti: raggruppare le
  operazioni in un solo runner, e per sapere se Rails è su interrogare `/users/sign_in` via HTTP.
- Il primo boot (reconfigure e migrazioni) supera i 7 minuti: serve una `startupProbe`, con la
  sola liveness il container viene ucciso a metà e riparte da capo.
- Su Autopilot una patch al pod template di GitLab (Spot) con strategy `Recreate` lo riavvia:
  va applicata subito dopo `kubectl apply`, non dopo l'attesa del boot.
- Al primo login di root la UI apre un modal di benvenuto sopra ogni pagina: va chiuso
  prima di automatizzare o fotografare l'interfaccia.

## Kargo

- Le Promotion create con `kubectl` vengono rifiutate se l'utente kube non è membro del
  progetto Kargo, e il messaggio del webhook è fuorviante ("defines no promotion steps").
  Si promuove con la CLI dopo `kargo login <url> --admin`.
- Uno Stage accetta un Freight solo dopo che lo stage precedente è Healthy: promuovere
  staging subito dopo dev restituisce `PromoteToStage (status 400)`.
- Le credenziali git del progetto vanno create prima che il Warehouse produca il primo
  Freight, altrimenti la promozione automatica di dev fallisce sul clone e non si ritenta
  da sola.
- Da Kargo 1.9 le `promotionPolicies` stanno nel `ProjectConfig`; nello spec del Project
  vengono ignorate.

## Port-forward su GKE con DNS endpoint

`kubectl port-forward` si blocca dopo 10-15 minuti senza uscire (`error creating error stream
... Timeout occurred`): il processo resta vivo e la porta non risponde più. In una sessione
lunga va sorvegliato e riavviato (`pf_supervise` in `lib/presenter.sh`), e ogni `curl` verso le
porte locali deve avere `-m`.

## Kargo e ArgoCD insieme

- Subito dopo il sync chiesto da `argocd-update`, l'Application può risultare `OutOfSync` pur
  essendo allineata: ArgoCD confronta con la HEAD del branch in cache. Un refresh
  (`argocd.argoproj.io/refresh=normal`) la corregge; senza, rientra al polling di 3 minuti.
- La CLI `kargo login --admin` chiede la password solo in modo interattivo. Da script si usa
  l'API Connect: `AdminLogin` restituisce `idToken`, poi `PromoteToStage` con Bearer.
- Il self-heal di ArgoCD ha un backoff esponenziale (2s, fattore 3, max 300s): ripetendo lo
  stesso drift durante le prove il rientro passa da 1 secondo a quasi un minuto.

## Drift e self-heal

Con `selfHeal` attivo il primo rientro è sotto il secondo: `OutOfSync` non è osservabile né
nella UI né con un polling da kubectl. L'evidenza da mostrare sono gli eventi del Deployment
(`Scaled up ... 1 to 4` seguito da `Scaled down ... 4 to 1`).

## Script con set -e

`docker` può essere installato con il daemon spento: controllare `docker info`, non
`command -v`. Un comando che fallisce dentro `$(...)` in un assegnamento chiude lo script senza
messaggio. `demo.sh present` gira con `set +e` di proposito: sul palco un errore transitorio
deve produrre un avviso, non chiudere la demo.

## bootstrap.sh

I passi `gitlab` e `kargo` chiedono conferma interattiva se la risorsa esiste già: in
esecuzione non interattiva escono con 1. Per rieseguire un singolo pezzo conviene chiamare
la funzione della lib:
`SCRIPT_DIR=$PWD bash -c 'source lib/common.sh; source lib/config.sh; source lib/gitlab.sh; <funzione>'`
