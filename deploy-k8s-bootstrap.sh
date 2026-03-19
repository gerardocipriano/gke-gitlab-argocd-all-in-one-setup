#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# KUBERNETES CLUSTER BOOTSTRAP - MAIN ENTRY POINT
# Complete GitOps Environment: GKE + GitLab + ArgoCD (App of Apps)
#
# Bootstrap flow:
#   1. prereq   → install tools, enable APIs
#   2. cluster   → create GKE cluster
#   3. gitlab    → deploy GitLab CE + root user + PAT
#   4. gitops    → create repo + push all manifests (gitlab, argocd, inventory)
#   5. argocd    → install ArgoCD + repo creds + App of Apps
#
# After bootstrap, a commit to the gitops repo can:
#   A. Deploy a new app by adding an ArgoCD Application in inventory/
#   B. Modify GitLab deployment by editing manifests/gitlab/
#   C. Modify ArgoCD config by editing manifests/argocd/
# =============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/prereq.sh"
source "${SCRIPT_DIR}/lib/cluster.sh"
source "${SCRIPT_DIR}/lib/gitlab.sh"
source "${SCRIPT_DIR}/lib/argocd.sh"
source "${SCRIPT_DIR}/lib/gitops.sh"

# =============================================================================
# PORT FORWARDING
# =============================================================================

cmd_portforward() {
    log_step "PORTFORWARD: Setting up port-forwarding..."

    kubectl port-forward -n "${GITLAB_NAMESPACE}" svc/gitlab "${GITLAB_LOCAL_PORT}:80" &
    local gitlab_pid=$!
    kubectl port-forward -n "${ARGOCD_NAMESPACE}" svc/argocd-server "${ARGOCD_LOCAL_PORT}:443" &
    local argocd_pid=$!
    sleep 3

    local pat
    pat=$(gitlab_get_pat)
    local argocd_password
    argocd_password=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "N/A")

    print_summary_box "SERVICES ACCESS" \
        "GitLab PID:      ${gitlab_pid}" \
        "GitLab URL:      http://localhost:${GITLAB_LOCAL_PORT}" \
        "GitLab User:     root" \
        "GitLab Password: ${GITLAB_ROOT_PASSWORD}" \
        "GitLab PAT:      ${pat:-N/A}" \
        "" \
        "ArgoCD PID:      ${argocd_pid}" \
        "ArgoCD URL:      https://localhost:${ARGOCD_LOCAL_PORT}" \
        "ArgoCD User:     admin" \
        "ArgoCD Password: ${argocd_password}"

    log_info "To stop: kill ${gitlab_pid} ${argocd_pid}"
}

# =============================================================================
# STATUS
# =============================================================================

cmd_status() {
    echo ""
    echo "=============================================="
    echo "  GKE CLUSTER STATUS"
    echo "=============================================="
    echo ""

    local status
    status=$(cluster_status 2>/dev/null || echo "UNKNOWN")
    echo "Cluster Status: ${status}"
    echo ""

    if [[ "${status}" == "RUNNING" ]]; then
        kubectl get nodes -o wide 2>/dev/null || true
        echo ""
        if kubectl get namespace "${GITLAB_NAMESPACE}" &>/dev/null; then
            log_info "GitLab Pods:"
            kubectl get pods -n "${GITLAB_NAMESPACE}" -o wide 2>/dev/null || true
            echo ""
            gitlab_info
        fi
        if kubectl get namespace "${ARGOCD_NAMESPACE}" &>/dev/null; then
            log_info "ArgoCD Pods:"
            kubectl get pods -n "${ARGOCD_NAMESPACE}" -o wide 2>/dev/null || true
            echo ""
            log_info "ArgoCD Applications:"
            kubectl get applications -n "${ARGOCD_NAMESPACE}" 2>/dev/null || true
            echo ""
            argocd_info
        fi
    fi
}

# =============================================================================
# USAGE
# =============================================================================

print_usage() {
    echo ""
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  all          Complete bootstrap (default)"
    echo "  prereq       Install prerequisites"
    echo "  cluster      Create GKE cluster"
    echo "  gitlab       Deploy GitLab CE + root user + PAT"
    echo "  gitops       Create gitops repo + push manifests"
    echo "  argocd       Deploy ArgoCD + App of Apps"
    echo "  portforward  Start port-forwarding"
    echo "  clean        Remove all resources"
    echo "  status       Show cluster status"
    echo ""
    echo "Environment Variables:"
    echo "  GITLAB_ROOT_PASSWORD   (default: Gk3B00tstr4p2025xZ)"
    echo "  GITLAB_LOCAL_PORT      (default: 8080)"
    echo "  ARGOCD_LOCAL_PORT      (default: 8443)"
    echo ""
}

# =============================================================================
# MAIN ROUTER
# =============================================================================

main() {
    log_header "KUBERNETES BOOTSTRAP: Starting"
    log_info "Project: ${GKE_PROJECT_ID} | Cluster: ${GKE_CLUSTER_NAME} | Zone: ${GKE_ZONE}"

    case "${1:-all}" in
        prereq)      prereq_check_all ;;
        cluster)
            prereq_check_gcloud
            prereq_check_gcloud_auth
            prereq_set_project
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
            log_error "Unknown command: ${1}"
            print_usage
            exit 1
            ;;
    esac

    log_success "KUBERNETES BOOTSTRAP: Operation completed"
}

main "$@"
