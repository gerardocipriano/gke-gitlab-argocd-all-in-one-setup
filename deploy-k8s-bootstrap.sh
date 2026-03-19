#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# KUBERNETES BOOTSTRAP - GitLab + ArgoCD (App of Apps)
# Supports: kind (local) or GKE (cloud)
#
# Usage:
#   ./deploy-k8s-bootstrap.sh [--provider kind|gke] [COMMAND]
#   CLUSTER_PROVIDER=gke ./deploy-k8s-bootstrap.sh all
#
# Bootstrap flow:
#   1. prereq  → install tools
#   2. cluster → create K8s cluster (kind or GKE)
#   3. gitlab  → deploy GitLab CE + root user + PAT
#   4. gitops  → create repo + push all manifests (auto-discovered)
#   5. argocd  → install ArgoCD + repo creds + App of Apps
# =============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common + config first
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/config.sh"

# Parse --provider flag before sourcing provider-specific modules
for arg in "$@"; do
    case "${arg}" in
        --provider=*) CLUSTER_PROVIDER="${arg#*=}"; shift ;;
        --provider)   CLUSTER_PROVIDER="${2:-}"; shift 2 ;;
    esac
done

if [[ "${CLUSTER_PROVIDER}" != "kind" && "${CLUSTER_PROVIDER}" != "gke" ]]; then
    echo "ERROR: CLUSTER_PROVIDER must be 'kind' or 'gke' (got: '${CLUSTER_PROVIDER}')" >&2
    exit 1
fi

# Source provider-specific modules
source "${SCRIPT_DIR}/lib/prereq-${CLUSTER_PROVIDER}.sh"
source "${SCRIPT_DIR}/lib/cluster-${CLUSTER_PROVIDER}.sh"

# Source provider-agnostic modules
source "${SCRIPT_DIR}/lib/gitlab.sh"
source "${SCRIPT_DIR}/lib/argocd.sh"
source "${SCRIPT_DIR}/lib/gitops.sh"

# =============================================================================
# PORT FORWARDING
# =============================================================================

cmd_portforward() {
    log_step "PORTFORWARD: Setting up port-forwarding..."

    if [[ "${CLUSTER_PROVIDER}" == "kind" ]]; then
        log_info "GitLab is accessible directly via NodePort: http://localhost:${GITLAB_LOCAL_PORT}"
    else
        kubectl port-forward -n "${GITLAB_NAMESPACE}" svc/gitlab "${GITLAB_LOCAL_PORT}:80" &
        log_info "GitLab port-forward started (PID: $!)"
    fi

    kubectl port-forward -n "${ARGOCD_NAMESPACE}" svc/argocd-server "${ARGOCD_LOCAL_PORT}:443" &
    local argocd_pid=$!
    sleep 3

    local pat
    pat=$(gitlab_get_pat)
    local argocd_password
    argocd_password=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "N/A")

    print_summary_box "SERVICES ACCESS (${CLUSTER_PROVIDER})" \
        "GitLab URL:      http://localhost:${GITLAB_LOCAL_PORT}" \
        "GitLab User:     root" \
        "GitLab Password: ${GITLAB_ROOT_PASSWORD}" \
        "GitLab PAT:      ${pat:-N/A}" \
        "" \
        "ArgoCD URL:      https://localhost:${ARGOCD_LOCAL_PORT}" \
        "ArgoCD User:     admin" \
        "ArgoCD Password: ${argocd_password}"
}

# =============================================================================
# STATUS
# =============================================================================

cmd_status() {
    print_summary_box "CLUSTER STATUS" \
        "Provider: ${CLUSTER_PROVIDER}" \
        "Cluster:  $(cluster_info_label)" \
        "Status:   $(cluster_status)"

    if [[ "$(cluster_status)" == "RUNNING" ]]; then
        kubectl get nodes -o wide 2>/dev/null || true
        echo ""
        if kubectl get namespace "${GITLAB_NAMESPACE}" &>/dev/null; then
            log_info "GitLab Pods:"
            kubectl get pods -n "${GITLAB_NAMESPACE}" -o wide 2>/dev/null || true
            gitlab_info
        fi
        if kubectl get namespace "${ARGOCD_NAMESPACE}" &>/dev/null; then
            log_info "ArgoCD Pods:"
            kubectl get pods -n "${ARGOCD_NAMESPACE}" -o wide 2>/dev/null || true
            log_info "ArgoCD Applications:"
            kubectl get applications -n "${ARGOCD_NAMESPACE}" 2>/dev/null || true
            argocd_info
        fi
    fi
}

# =============================================================================
# USAGE
# =============================================================================

print_usage() {
    echo ""
    echo "Usage: $0 [--provider kind|gke] [COMMAND]"
    echo ""
    echo "Providers:"
    echo "  kind         Local cluster via Docker (default)"
    echo "  gke          Google Kubernetes Engine"
    echo ""
    echo "Commands:"
    echo "  all          Complete bootstrap (default)"
    echo "  prereq       Install prerequisites"
    echo "  cluster      Create K8s cluster"
    echo "  gitlab       Deploy GitLab CE + root user + PAT"
    echo "  gitops       Create gitops repo + push manifests"
    echo "  argocd       Deploy ArgoCD + App of Apps"
    echo "  portforward  Start port-forwarding"
    echo "  clean        Delete cluster"
    echo "  status       Show cluster status"
    echo ""
    echo "Examples:"
    echo "  $0 all                        # kind (default)"
    echo "  $0 --provider=gke all         # GKE"
    echo "  CLUSTER_PROVIDER=gke $0 all   # GKE via env var"
    echo ""
}

# =============================================================================
# MAIN ROUTER
# =============================================================================

main() {
    log_header "KUBERNETES BOOTSTRAP [${CLUSTER_PROVIDER}]"
    log_info "Provider: ${CLUSTER_PROVIDER} | Cluster: $(cluster_info_label)"

    local cmd="${1:-all}"

    case "${cmd}" in
        prereq)      prereq_check_all ;;
        cluster)
            prereq_check_all
            cluster_create
            cluster_verify
            ;;
        gitlab)      gitlab_deploy ;;
        gitops)      gitops_create_repository ;;
        argocd)      argocd_deploy ;;
        portforward) cmd_portforward ;;
        clean)       cluster_delete ;;
        status)      cmd_status ;;
        all)
            prereq_check_all
            cluster_create
            cluster_verify
            gitlab_deploy
            gitops_create_repository
            argocd_deploy
            cmd_status
            echo ""
            read -r -p "Start port-forwarding now? [Y/n]: " response
            if [[ ! "${response}" =~ ^[Nn]$ ]]; then
                cmd_portforward
            fi
            ;;
        help|--help|-h) print_usage ;;
        *)
            log_error "Unknown command: ${cmd}"
            print_usage
            exit 1
            ;;
    esac

    log_success "KUBERNETES BOOTSTRAP [${CLUSTER_PROVIDER}]: Operation completed"
}

main "$@"
