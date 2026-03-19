# Kubernetes Bootstrap Script

Script Bash completo per creare un ambiente Kubernetes con GitOps.

## Descrizione

Questo script automatizza la creazione di un ambiente Kubernetes completo con:

- **Kind** (Kubernetes in Docker) cluster locale **oppure** **GKE** (Google Kubernetes Engine)
- **GitLab CE** (versione 18.6.0) come singolo pod
- **ArgoCD** per GitOps continuous delivery
- **App of Apps** pattern per gestire le applicazioni

## Requisiti di Sistema

- Linux (Ubuntu/Debian o RHEL/CentOS)
- Minimo 8GB RAM (consigliati 16GB per GitLab)
- 20GB spazio disco libero
- Accesso internet per download

## Struttura

```
k8s-bootstrap/
├── deploy-k8s-bootstrap.sh      # Script principale
├── lib/
│   └── common.sh                # Funzioni utility condivise
├── manifests/
│   ├── kind-config.yaml         # Configurazione cluster kind
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

## Utilizzo

### Bootstrap Completo (Kind - Default)

```bash
# Esegui tutto
./deploy-k8s-bootstrap.sh all
```

### Bootstrap Completo (GKE)

```bash
# Imposta variabili ambiente per GKE
export CLUSTER_TYPE=gke
export GKE_PROJECT_ID=formazione-gerardo-cipriano
export GKE_CLUSTER_NAME=poc-redis-1

./deploy-k8s-bootstrap.sh all
```

### Comandi Individuali

```bash
# Installa solo i prerequisiti
./deploy-k8s-bootstrap.sh prereq

# Crea solo il cluster
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

# Pulisci tutto
./deploy-k8s-bootstrap.sh clean
```

## Variabili di Configurazione

| Variabile | Default | Descrizione |
|-----------|---------|-------------|
| `CLUSTER_TYPE` | `kind` | Tipo di cluster (`kind` o `gke`) |
| `KIND_CLUSTER_NAME` | `gitops-cluster` | Nome cluster Kind |
| `GITLAB_ROOT_PASSWORD` | `GitLabAdmin123!` | Password root GitLab |
| `GITLAB_NODEPORT_HTTP` | `30080` | NodePort HTTP GitLab |
| `GITLAB_NODEPORT_SSH` | `30222` | NodePort SSH GitLab |
| `ARGOCD_NODEPORT` | `30081` | NodePort ArgoCD UI |
| `GKE_PROJECT_ID` | - | Project ID GCP |
| `GKE_CLUSTER_NAME` | `poc-redis-1` | Nome cluster GKE |
| `GKE_ZONE` | `us-central1-c` | Zona GKE |

## Accesso ai Servizi

Dopo il bootstrap:

### GitLab
- URL: http://localhost (kind) o LoadBalancer IP (GKE)
- Username: `root`
- Password: `GitLabAdmin123!` (o valore di `GITLAB_ROOT_PASSWORD`)
- SSH: `ssh -p 30222 git@localhost`

### ArgoCD
- URL: http://localhost:30081 (kind)
- Username: `admin`
- Password: ottenibile con:
  ```bash
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
  ```

## GitOps Workflow

Dopo il bootstrap, un commit nel repository `gitops` può:

### A. Deployare un nuovo applicativo

1. Copia il template:
   ```bash
   cp inventory/_template-application.yaml inventory/myapp-application.yaml
   ```

2. Modifica i placeholder:
   ```yaml
   # Sostituisci <APP_NAME> e <APP_NAMESPACE>
   name: myapp
   path: manifests/myapp
   namespace: myapp
   ```

3. Crea i manifest:
   ```bash
   mkdir -p manifests/myapp
   # Aggiungi i tuoi manifest Kubernetes
   ```

4. Commit e push:
   ```bash
   git add . && git commit -m "Add myapp" && git push
   ```

### B. Modificare GitLab

1. Modifica `manifests/gitlab/gitlab-deployment.yaml`
2. Commit e push
3. ArgoCD sincronizza automaticamente

### C. Modificare ArgoCD

1. Modifica `manifests/argocd/argocd-core.yaml`
2. Commit e push
3. ArgoCD sincronizza automaticamente

## Note Tecniche

### Immagini Verificate

I seguenti URL sono stati verificati come validi:

- **Kind**: https://kind.sigs.k8s.io
- **ArgoCD**: https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
- **GitLab CE**: gitlab/gitlab-ce:18.6.0-ce.0
- **cloud-provider-kind**: https://github.com/kubernetes-sigs/cloud-provider-kind

### Requisiti GitLab

GitLab CE richiede minimo 4GB RAM. Con kind:
- Il pod GitLab ha limits di 6GB
- È consigliabile avere 12-16GB totali sulla macchina

### Troubleshooting

```bash
# Controlla lo stato dei pod
kubectl get pods -A

# Log GitLab
kubectl logs -n gitlab -l app=gitlab -f

# Log ArgoCD
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server -f

# Ricrea il cluster
./deploy-k8s-bootstrap.sh clean
./deploy-k8s-bootstrap.sh all
```

## Licenza

Script per esercizio pratico - Colloquio candidato.
