# Note operative del repo

Lezioni verificate eseguendo la demo end to end. Qui vanno solo cose generali e riusabili,
non lo stato di un task.

## GKE Autopilot

- **cert-manager**: serve `--set global.leaderElection.namespace=cert-manager`. Di default
  prende il lease in `kube-system`, che e' un managed namespace: GKE Warden nega la
  scrittura, il controller resta senza leadership e i Certificate non vengono mai emessi.
  Il sintomo e' indiretto: pod Kargo in ContainerCreating sul secret `kargo-api-cert`
  assente, e il job `startupapicheck` che fallisce il post-install hook di Helm.
- **Pod con request alta**: su Autopilot la request dimensiona il nodo, e un pod Burstable
  che sfora la request viene evicted per memoria del nodo. Per GitLab servono
  `requests == limits` a 8Gi: Omnibus dimensiona puma sulle CPU del nodo, non sul limit del
  container, quindi va anche fissato `puma['worker_processes']`.
- **PVC**: i dischi persistenti sopravvivono alla cancellazione del cluster. Dopo un
  teardown controllare `gcloud compute disks list` e cancellarli a mano.
- Le porte host della demo (8080/8443/8081) si spostano con `GITLAB_LOCAL_PORT`,
  `ARGOCD_LOCAL_PORT`, `KARGO_LOCAL_PORT`: utile quando una e' occupata da altro in locale.

## Guardie di idempotenza

Non usare la presenza delle CRD per decidere se un chart e' installato: le CRD
sopravvivono a `helm uninstall`. Guardare il deployment.

## GitLab CE in cluster

- `gitlab-ctl reconfigure` fallisce su chiavi Omnibus rimosse dalle versioni recenti
  (vista `grafana['enable']`). Il log utile e' `FATAL: Mixlib::Config::UnknownConfigOptionError`.
- Le funzioni di `lib/gitlab.sh` prendono il pod come argomento: `gitlab_wait_for_rails "$(gitlab_get_pod)"`.
  Chiamarle senza argomento porta a un'attesa che non termina mai.
- Al primo login di root la UI apre un modal di benvenuto sopra ogni pagina: va chiuso
  prima di automatizzare o fotografare l'interfaccia.

## Kargo

- Le Promotion create con `kubectl` vengono rifiutate se l'utente kube non e' membro del
  progetto Kargo, e il messaggio del webhook e' fuorviante ("defines no promotion steps").
  Si promuove con la CLI dopo `kargo login <url> --admin`.
- Uno Stage accetta un Freight solo dopo che lo stage precedente e' Healthy: promuovere
  staging subito dopo dev restituisce `PromoteToStage (status 400)`.
- Le credenziali git del progetto vanno create prima che il Warehouse produca il primo
  Freight, altrimenti la promozione automatica di dev fallisce sul clone e non si ritenta
  da sola.
- Da Kargo 1.9 le `promotionPolicies` stanno nel `ProjectConfig`; nello spec del Project
  vengono ignorate.

## Drift e self-heal

Con `selfHeal` attivo il rientro e' sotto il secondo: `OutOfSync` non e' osservabile nella
UI ne con un polling da kubectl. L'evidenza da mostrare sono gli eventi del Deployment
(`Scaled up ... 1 to 4` seguito da `Scaled down ... 4 to 1`).

## deploy-k8s-bootstrap.sh

I passi `gitlab` e `kargo` chiedono conferma interattiva se la risorsa esiste gia': in
esecuzione non interattiva escono con 1. Per rieseguire un singolo pezzo conviene chiamare
la funzione della lib:
`SCRIPT_DIR=$PWD bash -c 'source lib/common.sh; source lib/config.sh; source lib/gitlab.sh; <funzione>'`
