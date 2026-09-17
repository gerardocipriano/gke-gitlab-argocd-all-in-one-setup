#!/usr/bin/env bash
# Purpose: centralized configuration for all bootstrap modules

# Provider: "kind" or "gke" — set via env var or --provider flag
CLUSTER_PROVIDER="${CLUSTER_PROVIDER:-kind}"

# Common
readonly GITLAB_NAMESPACE="${GITLAB_NAMESPACE:-gitlab}"
readonly GITLAB_ROOT_PASSWORD="${GITLAB_ROOT_PASSWORD:-Gk3B00tstr4p2025xZ}"
readonly GITLAB_PAT_SECRET_NAME="gitlab-bootstrap-pat"
readonly ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
readonly ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"
readonly GITLAB_LOCAL_PORT="${GITLAB_LOCAL_PORT:-8080}"
readonly ARGOCD_LOCAL_PORT="${ARGOCD_LOCAL_PORT:-8443}"

# kind-specific
readonly KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-gitops-lab}"

# GKE-specific
readonly GKE_PROJECT_ID="${GKE_PROJECT_ID:-formazione-gerardo-cipriano}"
readonly GKE_CLUSTER_NAME="${GKE_CLUSTER_NAME:-poc-gitops-1}"
readonly GKE_ZONE="${GKE_ZONE:-us-central1-c}"
readonly GKE_REGION="${GKE_REGION:-us-central1}"
readonly GKE_NETWORK="${GKE_NETWORK:-injenia-test}"
readonly GKE_SUBNETWORK="${GKE_SUBNETWORK:-injenia-gke-usc1}"
readonly GKE_SERVICE_ACCOUNT="${GKE_SERVICE_ACCOUNT:-gke-sa@${GKE_PROJECT_ID}.iam.gserviceaccount.com}"
readonly GKE_MACHINE_TYPE="${GKE_MACHINE_TYPE:-n2-standard-4}"
readonly GKE_NUM_NODES="${GKE_NUM_NODES:-2}"
readonly GKE_DISK_SIZE="${GKE_DISK_SIZE:-50}"

# Kargo
readonly KARGO_NAMESPACE="${KARGO_NAMESPACE:-kargo}"
readonly KARGO_PROJECT="${KARGO_PROJECT:-kargo-demo}"
readonly KARGO_LOCAL_PORT="${KARGO_LOCAL_PORT:-8081}"
readonly KARGO_ADMIN_PASSWORD="${KARGO_ADMIN_PASSWORD:-Karg0D3m02025xZ}"
# Fallback usato solo se htpasswd e docker non sono disponibili: bcrypt della password di
# default. Deve stare tra apici singoli, il dollaro nel formato bcrypt e' significativo.
if [[ -z "${KARGO_ADMIN_PASSWORD_HASH:-}" ]]; then
    KARGO_ADMIN_PASSWORD_HASH='$2y$10$q.Pdac1DMfDWvcvOLCChf.dZwaKnrU.FRTkrmtY91P8snuWt3ZJ3m'
fi
readonly KARGO_ADMIN_PASSWORD_HASH
readonly KARGO_CHART="${KARGO_CHART:-oci://ghcr.io/akuity/kargo-charts/kargo}"
readonly KARGO_VERSION="${KARGO_VERSION:-1.9.2}"
