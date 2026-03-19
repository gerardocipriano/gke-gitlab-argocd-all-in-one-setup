# Kubernetes Bootstrap Script

Script Bash completo per creare un ambiente Kubernetes con GitOps su GKE.

## Descrizione

Questo script automatizza la creazione di un ambiente Kubernetes su **Google Kubernetes Engine (GKE)** con:

- **GKE Cluster** con configurazione production-ready
- **GitLab CE** (versione 18.6.0) come singolo pod
- **ArgoCD** per GitOps continuous delivery
- **App of Apps** pattern per gestire le applicazioni

## Requisiti

- Accesso a Google Cloud Platform con progetto configurato
- VPC e subnet già esistenti
- Service account GKE con permessi appropriati
- `gcloud` CLI installato e autenticato
- Minimo 8GB RAM locale per i tool

## Struttura

```
k8s-bootstrap/
├── deploy-k8s-bootstrap.sh      # Script principale
├── lib/
│   └── common.sh                # Funzioni utility condivise
├── manifests/
│   ├── gitlab/
│   │   └── gitlab-deployment.yaml
│   ├── argocd/
│   │   └── argocd-core.yaml
│   └── gitops-inventory/
│       ├── app-of-apps.yaml
│       └── inventory/
│           ├── gitlab-application.yaml
│           ├── argocd-application.yaml
│           └── _template-application.yaml
└── README.md
```

## Configurazione GKE

Lo script crea un cluster GKE con le seguenti caratteristiche:

| Parametro | Valore |
|-----------|--------|
| Project ID | `formazione-gerardo-cipriano` |
| Cluster Name | `poc-redis-1` |
| Zone | `us-central1-c` |
| Machine Type | `n2-standard-4` |
| Node Count | `2` (Spot instances) |
| Disk Size | `50GB` |
| Network | `injenia-test` |
| Subnetwork | `injenia-gke-usc1` |
| Service Account | `gke-sa@formazione-gerardo-cipriano.iam.gserviceaccount.com` |

### Features Abilitate

- ✅ Spot instances (cost optimization)
- ✅ Autoupgrade & Autorepair
- ✅ Managed Prometheus
- ✅ Shielded nodes con integrity monitoring
- ✅ CloudDNS
- ✅ Master authorized networks
- ✅ Logging & Monitoring completi
- ✅ HorizontalPodAutoscaling
- ✅ HttpLoadBalancing
- ✅ GcePersistentDiskCsiDriver

## Utilizzo

### Bootstrap Completo

```bash
# Assicurati di essere autenticato
gcloud auth login

# Esegui il bootstrap completo
./deploy-k8s-bootstrap.sh all
```

### Comandi Individuali

```bash
# Verifica/installa prerequisiti
./deploy-k8s-bootstrap.sh prereq

# Crea solo il cluster GKE
./deploy-k8s-bootstrap.sh cluster

# Deploy solo GitLab
./deploy-k8s-bootstrap.sh gitlab

# Deploy solo ArgoCD
./deploy-k8s-bootstrap.sh argocd

# Inizializza repository gitops
./deploy-k8s-bootstrap.sh gitops

# Deploy App of Apps
./deploy-k8s-bootstrap.sh appofapps

# Mostra stato
./deploy-k8s-bootstrap.sh status

# Elimina tutto (cluster incluso)
./deploy-k8s-bootstrap.sh clean
```

## Variabili di Configurazione

| Variabile | Default | Descrizione |
|-----------|---------|-------------|
| `GITLAB_ROOT_PASSWORD` | `GitLabAdmin123!` | Password root GitLab |
| `ARGOCD_NAMESPACE` | `argocd` | Namespace ArgoCD |
| `ARGOCD_VERSION` | `stable` | Versione ArgoCD |
| `ARGOCD_CLI_VERSION` | `v2.13.0` | Versione argocd CLI |

## Accesso ai Servizi

Dopo il bootstrap:

### GitLab
- URL: LoadBalancer IP (visibile con `./deploy-k8s-bootstrap.sh status`)
- Username: `root`
- Password: `GitLabAdmin123!`

### ArgoCD
- URL: LoadBalancer IP (visibile con `./deploy-k8s-bootstrap.sh status`)
- Username: `admin`
- Password: ottenibile con:
  ```bash
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
  ```

## GitOps Workflow

Dopo il bootstrap, il repository `gitops` su GitLab contiene:
- `inventory/` - ArgoCD Applications
- `manifests/gitlab/` - GitLab deployment
- `manifests/argocd/` - ArgoCD config

Un commit permette di:

### A. Deployare un nuovo applicativo

1. Copia il template:
   ```bash
   cp inventory/_template-application.yaml inventory/myapp-application.yaml
   ```

2. Modifica i placeholder nel file

3. Crea i manifest in `manifests/myapp/`

4. Commit e push

### B. Modificare GitLab

1. Modifica `manifests/gitlab/gitlab-deployment.yaml`
2. Commit e push
3. ArgoCD sincronizza automaticamente

### C. Modificare ArgoCD

1. Modifica `manifests/argocd/argocd-core.yaml`
2. Commit e push
3. ArgoCD sincronizza automaticamente

## Comando GKE Completo

Lo script utilizza il seguente comando `gcloud beta container clusters create`:

```bash
gcloud beta container clusters create "poc-redis-1" \
    --project "formazione-gerardo-cipriano" \
    --zone "us-central1-c" \
    --tier "standard" \
    --no-enable-basic-auth \
    --release-channel "regular" \
    --machine-type "n2-standard-4" \
    --image-type "COS_CONTAINERD" \
    --disk-type "pd-balanced" \
    --disk-size "50" \
    --metadata disable-legacy-endpoints=true \
    --service-account "gke-sa@formazione-gerardo-cipriano.iam.gserviceaccount.com" \
    --max-pods-per-node "32" \
    --spot \
    --num-nodes "2" \
    --logging=SYSTEM,WORKLOAD \
    --monitoring=SYSTEM,STORAGE,POD,DEPLOYMENT,STATEFULSET,DAEMONSET,HPA,CADVISOR,KUBELET \
    --enable-ip-alias \
    --network "projects/formazione-gerardo-cipriano/global/networks/injenia-test" \
    --subnetwork "projects/formazione-gerardo-cipriano/regions/us-central1/subnetworks/injenia-gke-usc1" \
    --cluster-secondary-range-name "pods" \
    --services-secondary-range-name "svc" \
    --no-enable-intra-node-visibility \
    --cluster-dns=clouddns \
    --cluster-dns-scope=cluster \
    --default-max-pods-per-node "110" \
    --enable-ip-access \
    --security-posture=standard \
    --workload-vulnerability-scanning=disabled \
    --enable-master-authorized-networks \
    --master-authorized-networks 87.18.50.199/32,77.89.24.226/32 \
    --no-enable-google-cloud-access \
    --addons HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver \
    --enable-autoupgrade \
    --enable-autorepair \
    --max-surge-upgrade 1 \
    --max-unavailable-upgrade 0 \
    --binauthz-evaluation-mode=DISABLED \
    --enable-managed-prometheus \
    --enable-shielded-nodes \
    --shielded-integrity-monitoring \
    --no-shielded-secure-boot \
    --node-locations "us-central1-c"
```

## Troubleshooting

```bash
# Controlla lo stato del cluster
./deploy-k8s-bootstrap.sh status

# Log GitLab
kubectl logs -n gitlab -l app=gitlab -f

# Log ArgoCD
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server -f

# Verifica connettività
kubectl cluster-info

# Descrivi il cluster GKE
gcloud container clusters describe poc-redis-1 --zone us-central1-c
```

## Licenza

Script per esercizio pratico - Colloquio candidato.
