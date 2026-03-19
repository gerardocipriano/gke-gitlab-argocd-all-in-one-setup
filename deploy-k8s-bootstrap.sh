#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# KUBERNETES BOOTSTRAP - kind + GitLab + ArgoCD (App of Apps)
#
# Bootstrap flow:
#   1. prereq   → install docker, kind, kubectl
#   2. cluster  → create kind cluster
#   3. gitlab   → deploy GitLab CE + root user + PAT
#   4. gitops   → create repo + push all manifests (auto-discovered)
#   5. argocd   → install ArgoCD + repo creds + App of Apps
#
# After bootstrap, a commit to the gitops repo can:
#   A. Deploy a new app → add ArgoCD Application in inventory/
#   B. Modify GitLab    → edit manifests/gitlab/
#   C. Modify ArgoCD    → edit manifests/argocd/
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
# PORT FORWARDING (ArgoCD only — GitLab uses NodePort via kind)
# =============================================================================

cmd_portforward() {
    log_step "PORTFORWARD: Setting up port-forwarding for ArgoCD..."

    kubectl port-forward -n "${ARGOCD_NAMESPACE}" svc/argocd-server "${ARGOCD_LOCAL_PORT}:443" &
    local argocd_pid=$!
    sleep 3

    local pat
    pat=$(gitlab_get_pat)
    local argocd_password
    argocd_password=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "N/A")

    print_summary_box "SERVICES ACCESS" \
        "GitLab URL:      http://localhost:${GITLAB_LOCAL_PORT}  (NodePort)" \
        "GitLab User:     root" \
        "GitLab Password: ${GITLAB_ROOT_PASSWORD}" \
        "GitLab PAT:      ${pat:-N/A}" \
        "" \
        "ArgoCD PID:      ${argocd_pid}" \
        "ArgoCD URL:      https://localhost:${ARGOCD_LOCAL_PORT}  (port-forward)" \
        "ArgoCD User:     admin" \
        "ArgoCD Password: ${argocd_password}"

    log_info "GitLab is accessible directly (NodePort)"
    log_info "To stop ArgoCD port-forward: kill ${argocd_pid}"
}

# =============================================================================
# STATUS
# =============================================================================

cmd_status() {
    print_summary_box "CLUSTER STATUS" \
        "Cluster:  ${KIND_CLUSTER_NAME}" \
        "Status:   $(cluster_status)"

    if [[ "$(cluster_status)" == "RUNNING" ]]; then
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
    echo "  prereq       Install prerequisites (docker, kind, kubectl)"
    echo "  cluster      Create kind cluster"
    echo "  gitlab       Deploy GitLab CE + root user + PAT"
    echo "  gitops       Create gitops repo + push manifests (auto-discovered)"
    echo "  argocd       Deploy ArgoCD + App of Apps"
    echo "  portforward  Start port-forwarding (ArgoCD)"
    echo "  clean        Delete kind cluster"
    echo "  status       Show cluster status"
    echo ""
    echo "Environment Variables:"
    echo "  KIND_CLUSTER_NAME      (default: gitops-lab)"
    echo "  GITLAB_ROOT_PASSWORD   (default: Gk3B00tstr4p2025xZ)"
    echo "  GITLAB_LOCAL_PORT      (default: 8080)"
    echo "  ARGOCD_LOCAL_PORT      (default: 8443)"
    echo ""
}

# =============================================================================
# MAIN ROUTER
# =============================================================================

main() {
    log_header "KUBERNETES BOOTSTRAP: kind + GitLab + ArgoCD"
    log_info "Cluster: ${KIND_CLUSTER_NAME}"

    case "${1:-all}" in
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
            read -r -p "Start ArgoCD port-forwarding now? [Y/n]: " response
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
