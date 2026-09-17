# 🚀 Kubernetes GitOps Bootstrap

**One-command setup for a complete GitOps environment with GitLab + ArgoCD**

Supports both **kind** (local) and **GKE** (cloud) clusters with automatic manifest discovery and App of Apps pattern.

---

## ✨ Features

- 🎯 **Single command bootstrap** — from zero to GitOps in minutes
- 🔄 **Dual provider support** — kind (local/free) or GKE (cloud)
- 🤖 **Fully automated** — root user creation, PAT generation, repo initialization
- 📦 **Auto-discovery** — automatically detects and deploys all manifests
- 🎨 **App of Apps pattern** — ArgoCD manages everything via Git
- 🔐 **Secure by default** — PAT-based auth, no hardcoded secrets

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                        │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │   GitLab CE  │  │   ArgoCD     │  │  Your Apps   │      │
│  │              │  │              │  │  (nginx...)  │      │
│  │  - Root user │  │  - App of    │  │              │      │
│  │  - PAT auth  │  │    Apps      │  │              │      │
│  │  - gitops    │◄─┤  - Auto-sync │◄─┤              │      │
│  │    repo      │  │              │  │              │      │
│  └──────────────┘  └──────┬───────┘  └──────────────┘      │
│                           │                                 │
│                    ┌──────v───────┐                         │
│                    │    Kargo     │                         │
│                    │  - Warehouse │                         │
│                    │  - Stages    │                         │
│                    │  - Promote   │                         │
│                    └──────────────┘                         │
└─────────────────────────────────────────────────────────────┘
```

**After bootstrap:**
- ✅ Commit to `gitops` repo → ArgoCD auto-deploys
- ✅ Add new app → create `inventory/myapp-application.yaml`
- ✅ Modify GitLab → edit `manifests/gitlab/`
- ✅ Modify ArgoCD → edit `manifests/argocd/`
- ✅ Promote across environments → Kargo + render-to-branch

---

## 🚀 Quick Start

### Percorso guidato (consigliato la prima volta)

```bash
./demo.sh                 # nove passi commentati, dal cluster vuoto alla promozione in prod
./demo.sh --list          # elenco dei passi
./demo.sh --from 6        # riprende dal passo 6
./demo.sh --provider gke  # stesso percorso su GKE
```

Ogni passo spiega cosa sta per accadere, mostra il comando, chiede conferma e verifica il
risultato. L'ultimo passo smonta tutto.

### kind (Local - Recommended for testing)

```bash
# One command bootstrap
./deploy-k8s-bootstrap.sh all

# Access services
# GitLab:  http://localhost:8080  (user: root, pass: Gk3B00tstr4p2025xZ)
# ArgoCD:  https://localhost:8443 (user: admin, pass: from kubectl)
# Kargo:   https://localhost:8081 (user: admin, pass: Karg0D3m02025xZ)
```

### GKE (Cloud)

```bash
# Bootstrap on GKE
./deploy-k8s-bootstrap.sh --provider=gke all

# Or via environment variable
CLUSTER_PROVIDER=gke ./deploy-k8s-bootstrap.sh all
```

---

## 📋 Prerequisites

### kind (Local)
- Docker installed and running
- `kubectl` (auto-installed if missing)
- `kind` (auto-installed if missing)

### GKE (Cloud)
- `gcloud` CLI installed and authenticated
- GCP project with billing enabled
- `kubectl` (auto-installed if missing)
- `helm` >= 3.13 (richiesto da Kargo)
- Il control plane e' esposto solo via DNS endpoint (`--enable-dns-access`): l'accesso
  dipende da IAM, non da liste di IP autorizzati. Serve il ruolo `container.developer`
  o superiore sul progetto.

---

## 🎮 Usage

### Commands

```bash
./deploy-k8s-bootstrap.sh [--provider kind|gke] [COMMAND]

Commands:
  all          Complete bootstrap (default)
  prereq       Install prerequisites
  cluster      Create K8s cluster
  gitlab       Deploy GitLab CE + root user + PAT
  gitops       Create gitops repo + push manifests
  argocd       Deploy ArgoCD + App of Apps
  kargo        Deploy cert-manager + Kargo + git credentials for the project
  portforward  Start port-forwarding
  status       Show cluster status

Cleanup:
  delete-kargo    Delete Kargo resources only
  delete-argocd   Delete ArgoCD resources only
  delete-gitops   Delete the gitops repository only
  delete-gitlab   Delete GitLab resources only
  teardown        Guided cleanup, one block at a time
  clean           Delete the cluster
```

### Examples

```bash
# Full bootstrap with kind (default)
./deploy-k8s-bootstrap.sh all

# Full bootstrap with GKE
./deploy-k8s-bootstrap.sh --provider=gke all

# Step-by-step (kind)
./deploy-k8s-bootstrap.sh prereq
./deploy-k8s-bootstrap.sh cluster
./deploy-k8s-bootstrap.sh gitlab
./deploy-k8s-bootstrap.sh gitops
./deploy-k8s-bootstrap.sh argocd

# Check status
./deploy-k8s-bootstrap.sh status

# Smontaggio guidato, con una conferma per ogni componente
./deploy-k8s-bootstrap.sh teardown

# Smontaggio non interattivo, cluster escluso
ASSUME_YES=1 ./deploy-k8s-bootstrap.sh teardown

# Solo il cluster
./deploy-k8s-bootstrap.sh clean
```

---

## 🚀 Demo Kargo

Kargo aggiunge alle pipeline GitOps la capacita' di promuovere artefatti tra ambienti (dev, staging, prod) con un meccanismo basato su git. Osserva un registry immagini, produce Freight quando scopre nuove versioni e le fa avanzare lungo una catena di Stage, scrivendo i manifest renderizzati su branch dedicati. ArgoCD legge da quei branch e applica le modifiche.

La demo usa un'applicazione nginx con overlay kustomize: 1 replica in dev, 2 in staging, 3 in prod.

Per il dettaglio completo vedi [docs/KARGO-DEMO.md](docs/KARGO-DEMO.md).

---

## 🎯 Adding a New Application

1. **Create manifest directory:**
   ```bash
   mkdir -p manifests/myapp
   ```

2. **Add Kubernetes manifests:**
   ```bash
   cat > manifests/myapp/deployment.yaml << EOF
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: myapp
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: myapp
     template:
       metadata:
         labels:
           app: myapp
       spec:
         containers:
         - name: myapp
           image: nginx:alpine
           ports:
           - containerPort: 80
   EOF
   ```

3. **Create ArgoCD Application:**
   ```bash
   cp manifests/gitops-inventory/inventory/_template-application.yaml \
      manifests/gitops-inventory/inventory/myapp-application.yaml
   
   # Edit and replace <APP_NAME> with "myapp"
   # Edit and replace <APP_NAMESPACE> with "myapp"
   ```

4. **Re-run gitops step:**
   ```bash
   ./deploy-k8s-bootstrap.sh gitops
   ```

5. **ArgoCD auto-syncs** — your app is deployed! 🎉

---

## 📁 Project Structure

```
.
├── deploy-k8s-bootstrap.sh          # Main entry point
├── lib/
│   ├── common.sh                    # Logging, utilities
│   ├── config.sh                    # Configuration (both providers)
│   ├── prereq-kind.sh               # kind prerequisites
│   ├── prereq-gke.sh                # GKE prerequisites
│   ├── cluster-kind.sh              # kind cluster management
│   ├── cluster-gke.sh               # GKE cluster management
│   ├── gitlab.sh                    # GitLab deploy + root user + PAT
│   ├── argocd.sh                    # ArgoCD deploy + App of Apps
│   └── gitops.sh                    # Gitops repo init (auto-discovery)
├── manifests/
│   ├── gitlab/
│   │   └── gitlab-deployment.yaml   # GitLab CE deployment
│   ├── argocd/
│   │   └── argocd-core.yaml         # ArgoCD project config
│   ├── nginx/                       # Example app
│   │   └── nginx-deployment.yaml
│   ├── kargo-project/               # Kargo control-plane resources
│   │   ├── project.yaml             # Project (creates namespace)
│   │   ├── warehouse.yaml           # Image registry watcher
│   │   ├── stages.yaml              # dev, staging, prod stages
│   │   └── promotion-task.yaml      # 7-step promotion process
│   ├── kargo-demo/                  # Application manifests
│   │   ├── base/                    # Shared kustomize base
│   │   └── stages/                  # Overlays per stage
│   └── gitops-inventory/
│       ├── app-of-apps.yaml         # Root ArgoCD Application
│       └── inventory/
│           ├── _template-application.yaml
│           ├── gitlab-application.yaml
│           ├── argocd-application.yaml
│           └── nginx-application.yaml
└── README.md
```

---

## 🔧 Configuration

### Environment Variables

```bash
# Provider selection
CLUSTER_PROVIDER=kind|gke              # Default: kind

# Common
GITLAB_ROOT_PASSWORD=<password>        # Default: Gk3B00tstr4p2025xZ
GITLAB_LOCAL_PORT=8080                 # Default: 8080
ARGOCD_LOCAL_PORT=8443                 # Default: 8443

# kind-specific
KIND_CLUSTER_NAME=gitops-lab           # Default: gitops-lab

# GKE-specific
GKE_PROJECT_ID=<project-id>            # Required for GKE
GKE_CLUSTER_NAME=<cluster-name>        # Default: poc-gitops-1
GKE_ZONE=<zone>                        # Default: us-central1-c
GKE_MACHINE_TYPE=<type>                # Default: n2-standard-4
GKE_NUM_NODES=<count>                  # Default: 2
```

### Edit Configuration

All configuration is centralized in `lib/config.sh`. Edit this file to customize:
- Cluster names
- Resource sizes
- Network settings (GKE)
- Passwords (change default!)

---

## 🐛 Troubleshooting

### GitLab not starting

```bash
# Check pod status
kubectl get pods -n gitlab

# Check logs
kubectl logs -n gitlab -l app=gitlab --tail=100

# GitLab takes 5-10 minutes to fully start
# Wait for readiness probe to pass
```

### ArgoCD Applications stuck in "OutOfSync"

```bash
# Check ArgoCD logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server

# Manually sync
kubectl get applications -n argocd
argocd app sync <app-name>
```

### kind cluster creation fails

```bash
# Check Docker is running
docker info

# Delete existing cluster
kind delete cluster --name gitops-lab

# Retry
./deploy-k8s-bootstrap.sh cluster
```

### GKE authentication issues

```bash
# Re-authenticate
gcloud auth login
gcloud auth application-default login

# Set project
gcloud config set project <PROJECT_ID>
```

---

## 🔐 Security Notes

- **Default password** (`Gk3B00tstr4p2025xZ`) is for **demo purposes only**
- **Change it** via `GITLAB_ROOT_PASSWORD` env var for production
- **PAT tokens** are stored in Kubernetes secrets (not in manifests)
- **kind clusters** are local-only (no external exposure)
- **GKE clusters** use master authorized networks (configure in `lib/config.sh`)

---

## 🎓 How It Works

### Bootstrap Flow

1. **Prerequisites** → Install tools (docker/gcloud, kind/kubectl)
2. **Cluster** → Create K8s cluster (kind or GKE)
3. **GitLab** → Deploy GitLab CE, create root user, generate PAT
4. **Gitops** → Create `gitops` repo, push all manifests (auto-discovered)
5. **ArgoCD** → Install ArgoCD, configure repo credentials, deploy App of Apps
6. **Kargo** → Install Kargo, create git credentials in project namespace

### Auto-Discovery

The `gitops` step automatically discovers:
- All directories under `manifests/` (except `gitops-inventory`)
- All files in `manifests/gitops-inventory/inventory/`

**Add a new app?** Just create `manifests/myapp/` and `inventory/myapp-application.yaml` → re-run `gitops` step.

### App of Apps Pattern

ArgoCD's "App of Apps" pattern:
- **Root app** (`apps`) watches `inventory/` directory
- **Child apps** (gitlab, argocd, nginx...) are defined in `inventory/`
- **Commit to git** → ArgoCD auto-syncs → apps deployed

---

## 📊 Resource Requirements

### kind (Local)
- **RAM:** 8GB minimum (GitLab is memory-hungry)
- **CPU:** 4 cores recommended
- **Disk:** 20GB free space

### GKE (Cloud)
- **Default:** 2x n2-standard-4 nodes (8 vCPU, 32GB RAM total)
- **Cost:** ~$200/month (use spot instances to reduce)
- **Disk:** 50GB per node

---

## 🤝 Contributing

Contributions welcome! This is a learning/demo project.

**To add a new provider:**
1. Create `lib/prereq-<provider>.sh`
2. Create `lib/cluster-<provider>.sh`
3. Update `lib/config.sh` with provider-specific config
4. Test with `CLUSTER_PROVIDER=<provider> ./deploy-k8s-bootstrap.sh all`

---

## 📝 License

MIT License - feel free to use, modify, and distribute.

---

## 🙏 Acknowledgments

- [kind](https://kind.sigs.k8s.io/) - Kubernetes IN Docker
- [GitLab CE](https://about.gitlab.com/install/) - DevOps platform
- [ArgoCD](https://argo-cd.readthedocs.io/) - GitOps continuous delivery
- [Kargo](https://kargo.akuity.io/) - Multi-stage promotion pipeline for GitOps

