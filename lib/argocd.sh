#!/usr/bin/env bash
# Purpose: ArgoCD install, repo credentials, and App of Apps deployment

argocd_deploy() {
    log_step "ARGOCD: Deploying ArgoCD..."

    if kubectl get namespace "${ARGOCD_NAMESPACE}" &>/dev/null; then
        if kubectl get deployment -n "${ARGOCD_NAMESPACE}" argocd-server &>/dev/null; then
            log_warn "ArgoCD is already deployed"
            read -r -p "Redeploy? [y/N]: " response
            if [[ ! "${response}" =~ ^[Yy]$ ]]; then
                log_info "Skipping ArgoCD deployment"
                return 0
            fi
        fi
    fi

    kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    log_info "Installing ArgoCD from upstream manifest..."
    kubectl apply -n "${ARGOCD_NAMESPACE}" \
        --server-side --force-conflicts \
        -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

    log_info "Waiting for ArgoCD components..."
    kubectl wait --for=condition=Available \
        deployment/argocd-server \
        deployment/argocd-repo-server \
        -n "${ARGOCD_NAMESPACE}" \
        --timeout=600s

    # Apply ArgoCD project config (gitops AppProject)
    local argocd_manifest="${SCRIPT_DIR}/manifests/argocd/argocd-core.yaml"
    if [[ -f "${argocd_manifest}" ]]; then
        kubectl apply -f "${argocd_manifest}"
    fi

    argocd_create_repo_credentials
    argocd_deploy_app_of_apps

    log_success "ARGOCD: Fully deployed with App of Apps"
}

argocd_create_repo_credentials() {
    local pat
    pat=$(gitlab_get_pat)
    if [[ -z "${pat}" ]]; then
        log_warn "No GitLab PAT found, skipping ArgoCD repo credentials"
        return 0
    fi

    log_info "Creating ArgoCD repository credentials with PAT..."
    cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-repo-credentials
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: http://gitlab.${GITLAB_NAMESPACE}.svc.cluster.local/root/gitops.git
  username: oauth2
  password: "${pat}"
EOF
    log_success "ArgoCD repo credentials created"
}

argocd_deploy_app_of_apps() {
    log_step "ARGOCD: Deploying App of Apps..."

    local appofapps_manifest="${SCRIPT_DIR}/manifests/gitops-inventory/app-of-apps.yaml"
    if [[ ! -f "${appofapps_manifest}" ]]; then
        log_error "App of Apps manifest not found: ${appofapps_manifest}"
        return 1
    fi

    kubectl apply -f "${appofapps_manifest}"
    log_info "Waiting for App of Apps to sync..."
    sleep 15

    log_success "App of Apps deployed"
    log_info "ArgoCD Applications:"
    kubectl get applications -n "${ARGOCD_NAMESPACE}" 2>/dev/null || true
}

argocd_delete() {
    log_step "ARGOCD: Deleting ArgoCD resources..."

    # Remove finalizers first; otherwise Application deletion hangs indefinitely
    log_info "Removing finalizers from ArgoCD Applications..."
    for app in $(kubectl get applications -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        kubectl patch application "${app}" -n "${ARGOCD_NAMESPACE}" \
            --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
    done

    log_info "Deleting all ArgoCD Applications..."
    kubectl delete applications --all -n "${ARGOCD_NAMESPACE}" 2>/dev/null || true

    log_info "Deleting ArgoCD AppProject..."
    kubectl delete appproject gitops -n "${ARGOCD_NAMESPACE}" --ignore-not-found 2>/dev/null || true

    log_info "Deleting repo credentials secret..."
    kubectl delete secret gitlab-repo-credentials -n "${ARGOCD_NAMESPACE}" --ignore-not-found 2>/dev/null || true

    log_info "Deleting ArgoCD installation..."
    kubectl delete -n "${ARGOCD_NAMESPACE}" \
        -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" 2>/dev/null || true
    kubectl delete namespace "${ARGOCD_NAMESPACE}" --ignore-not-found 2>/dev/null || true

    log_success "ARGOCD: Resources deleted"
}

argocd_info() {
    log_info "ArgoCD Access Information:"
    local argocd_password
    argocd_password=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "N/A")
    echo ""
    echo "  Port-forward:   kubectl port-forward -n ${ARGOCD_NAMESPACE} svc/argocd-server ${ARGOCD_LOCAL_PORT}:443"
    echo "  ArgoCD URL:     https://localhost:${ARGOCD_LOCAL_PORT}"
    echo "  Username:       admin"
    echo "  Password:       ${argocd_password}"
    echo ""
}
