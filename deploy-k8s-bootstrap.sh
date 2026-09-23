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

# --provider va letto prima di caricare i moduli del provider, in qualunque posizione.
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --provider=*) CLUSTER_PROVIDER="${1#*=}"; shift ;;
        --provider)   CLUSTER_PROVIDER="${2:-}"; shift 2 ;;
        *)            ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

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
source "${SCRIPT_DIR}/lib/kargo.sh"

# =============================================================================
# PORT FORWARDING
# =============================================================================

cmd_portforward() {
    log_step "PORTFORWARD: Setting up port-forwarding..."

    # Su kind i NodePort sono gia' mappati sull'host dalla configurazione del cluster,
    # quindi il port-forward serve solo quando il provider e' GKE.
    local gitlab_port="${GITLAB_LOCAL_PORT}"
    local argocd_port="${ARGOCD_LOCAL_PORT}"
    local kargo_port="${KARGO_LOCAL_PORT}"

    if [[ "${CLUSTER_PROVIDER}" == "kind" ]]; then
        log_info "kind: i servizi sono gia' esposti via NodePort, nessun port-forward necessario"
    else
        gitlab_port=$(start_port_forward "${GITLAB_NAMESPACE}" gitlab 80 "${GITLAB_LOCAL_PORT}")
        log_info "GitLab port-forward su localhost:${gitlab_port}"

        argocd_port=$(start_port_forward "${ARGOCD_NAMESPACE}" argocd-server 443 "${ARGOCD_LOCAL_PORT}")
        log_info "ArgoCD port-forward su localhost:${argocd_port}"

        if kubectl get svc -n "${KARGO_NAMESPACE}" kargo-api &>/dev/null; then
            kargo_port=$(start_port_forward "${KARGO_NAMESPACE}" kargo-api 443 "${KARGO_LOCAL_PORT}")
            log_info "Kargo port-forward su localhost:${kargo_port}"
        else
            kargo_port="n/d"
        fi

        sleep 3
    fi

    local pat
    pat=$(gitlab_get_pat)
    local argocd_password
    argocd_password=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "N/A")

    print_summary_box "SERVICES ACCESS (${CLUSTER_PROVIDER})" \
        "GitLab URL:      http://localhost:${gitlab_port}" \
        "GitLab User:     root" \
        "GitLab Password: ${GITLAB_ROOT_PASSWORD}" \
        "GitLab PAT:      ${pat:-N/A}" \
        "" \
        "ArgoCD URL:      https://localhost:${argocd_port}" \
        "ArgoCD User:     admin" \
        "ArgoCD Password: ${argocd_password}" \
        "" \
        "Kargo URL:       https://localhost:${kargo_port}" \
        "Kargo User:      admin" \
        "Kargo Password:  ${KARGO_ADMIN_PASSWORD}"

    if [[ "${CLUSTER_PROVIDER}" != "kind" ]]; then
        log_info "Per fermare i port-forward: pkill -f 'kubectl port-forward'"
    fi
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
        if kubectl get namespace "${KARGO_NAMESPACE}" &>/dev/null; then
            log_info "Kargo Pods:"
            kubectl get pods -n "${KARGO_NAMESPACE}" -o wide 2>/dev/null || true
            if kubectl get namespace "${KARGO_PROJECT}" &>/dev/null; then
                log_info "Kargo Stages:"
                kubectl get stages -n "${KARGO_PROJECT}" 2>/dev/null || true
                log_info "Kargo Freight:"
                kubectl get freight -n "${KARGO_PROJECT}" 2>/dev/null || true
            fi
            kargo_info
        fi
    fi
}

# =============================================================================
# TEARDOWN (resource-by-resource cleanup)
# =============================================================================

ask_confirm() {
    local message="$1"
    if [[ "${ASSUME_YES:-0}" == "1" ]]; then
        return 0
    fi
    read -r -p "${message} [y/N]: " response
    [[ "${response}" =~ ^[Yy]$ ]]
}

cmd_teardown() {
    log_step "TEARDOWN: Starting resource-by-resource cleanup..."

    # ArgoCD va per primo: finche' e' vivo, la root Application risincronizza e ricrea
    # le risorse Kargo appena cancellate.
    log_info "==> ArgoCD (Applications, AppProject, credentials, installation)"
    if ask_confirm "Delete ArgoCD?"; then
        argocd_delete
    else
        log_info "Skipping ArgoCD"
    fi

    log_info "==> Kargo (stages, project, namespaces, Helm release)"
    if ask_confirm "Delete Kargo?"; then
        kargo_delete
    else
        log_info "Skipping Kargo"
    fi

    log_info "==> GitOps (gitops project in GitLab, residual Job/ConfigMap)"
    if ask_confirm "Delete GitOps repository?"; then
        gitops_delete_repository
    else
        log_info "Skipping GitOps"
    fi

    log_info "==> GitLab (namespace, PAT)"
    if ask_confirm "Delete GitLab?"; then
        gitlab_delete
    else
        log_info "Skipping GitLab"
    fi

    # Il cluster non rientra in ASSUME_YES: va chiesto sempre, o forzato con DELETE_CLUSTER=1.
    log_info "==> Cluster"
    if [[ "${DELETE_CLUSTER:-0}" == "1" ]] || ASSUME_YES=0 ask_confirm "Delete the entire cluster?"; then
        cluster_delete
    else
        log_info "Skipping cluster deletion"
    fi

    log_success "TEARDOWN: Completed"
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
    echo "  kargo        Deploy Kargo + credenziali git del progetto"
    echo "  portforward  Start port-forwarding"
    echo "  clean        Delete cluster"
    echo "  status       Show cluster status"
    echo ""
    echo "Cleanup:"
    echo "  delete-kargo    Delete Kargo resources only"
    echo "  delete-argocd   Delete ArgoCD resources only"
    echo "  delete-gitops   Delete gitops repository only"
    echo "  delete-gitlab   Delete GitLab resources only"
    echo "  teardown        Interactive full cleanup (reverse of bootstrap)"
    echo ""
    echo "Examples:"
    echo "  $0 all                        # kind (default)"
    echo "  $0 --provider=gke all         # GKE"
    echo "  CLUSTER_PROVIDER=gke $0 all   # GKE via env var"
    echo "  $0 teardown                   # interactive cleanup"
    echo "  ASSUME_YES=1 $0 teardown      # non-interactive cleanup (cluster escluso)"
    echo "  ASSUME_YES=1 DELETE_CLUSTER=1 $0 teardown   # cleanup completo, cluster incluso"
    echo ""
}

# Sposta i componenti di piattaforma su nodi Spot. No-op sul provider kind.
# GitLab non e' qui: lo patcha gitlab_deploy prima di attendere il boot. I workload creati
# da Argo CD (demo nginx, stage Kargo) restano fuori: la patch verrebbe riallineata.
deploy_spot_scheduling() {
    case "$1" in
        argocd) cluster_schedule_spot "${ARGOCD_NAMESPACE}" ;;
        kargo)
            cluster_schedule_spot "${CERT_MANAGER_NAMESPACE}"
            cluster_schedule_spot "${KARGO_NAMESPACE}"
            ;;
    esac
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
        argocd)      argocd_deploy; deploy_spot_scheduling argocd ;;
        kargo)       kargo_deploy; deploy_spot_scheduling kargo ;;
        delete-kargo)    kargo_delete ;;
        delete-argocd)   argocd_delete ;;
        delete-gitops)   gitops_delete_repository ;;
        delete-gitlab)   gitlab_delete ;;
        portforward) cmd_portforward ;;
        teardown)    cmd_teardown ;;
        clean)       cluster_delete ;;
        status)      cmd_status ;;
        all)
            prereq_check_all
            cluster_create
            cluster_verify
            gitlab_deploy
            gitops_create_repository
            argocd_deploy
            deploy_spot_scheduling argocd
            kargo_deploy
            deploy_spot_scheduling kargo
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
