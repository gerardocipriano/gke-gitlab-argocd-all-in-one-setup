#!/usr/bin/env bash
# Purpose: centralized configuration for all bootstrap modules

readonly KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-gitops-lab}"

# Purpose: password has NO special bash chars (no ! $ ` \) to avoid shell expansion
readonly GITLAB_NAMESPACE="${GITLAB_NAMESPACE:-gitlab}"
readonly GITLAB_ROOT_PASSWORD="${GITLAB_ROOT_PASSWORD:-Gk3B00tstr4p2025xZ}"
readonly GITLAB_PAT_SECRET_NAME="gitlab-bootstrap-pat"

readonly ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
readonly ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"

readonly GITLAB_LOCAL_PORT="${GITLAB_LOCAL_PORT:-8080}"
readonly ARGOCD_LOCAL_PORT="${ARGOCD_LOCAL_PORT:-8443}"
