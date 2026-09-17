#!/usr/bin/env bash
# Purpose: Kargo install, password hash, git credentials, and info

kargo_generate_password_hash() {
    if command_exists htpasswd; then
        htpasswd -bnBC 10 '' "${KARGO_ADMIN_PASSWORD}" | tr -d ':\n'
    elif command_exists docker; then
        docker run --rm httpd:2.4-alpine \
            htpasswd -bnBC 10 '' "${KARGO_ADMIN_PASSWORD}" | tr -d ':\n'
    else
        log_warn "Using precomputed hash for default Kargo admin password"
        echo "${KARGO_ADMIN_PASSWORD_HASH}"
    fi
}

kargo_deploy() {
    log_step "KARGO: Deploying Kargo..."

    if kubectl get namespace "${KARGO_NAMESPACE}" &>/dev/null; then
        if kubectl get deployment -n "${KARGO_NAMESPACE}" kargo-api &>/dev/null; then
            log_warn "Kargo is already deployed"
            read -r -p "Redeploy? [y/N]: " response
            if [[ ! "${response}" =~ ^[Yy]$ ]]; then
                log_info "Skipping Kargo deployment"
                return 0
            fi
        fi
    fi

    local password_hash
    password_hash=$(kargo_generate_password_hash)

    local token_signing_key
    # I caratteri =+/ romperebbero il parsing di helm --set
    token_signing_key=$(openssl rand -base64 48 | tr -d "=+/" | head -c 32)

    log_info "Installing/Updating Kargo via Helm..."
    helm upgrade --install kargo "${KARGO_CHART}" \
        --namespace "${KARGO_NAMESPACE}" \
        --create-namespace \
        --version "${KARGO_VERSION}" \
        --wait \
        --timeout 10m \
        --set api.adminAccount.passwordHash="${password_hash}" \
        --set api.adminAccount.tokenSigningKey="${token_signing_key}" \
        --set api.service.type=NodePort \
        --set api.service.nodePort=30081

    log_info "Waiting for kargo-api deployment to become Available..."
    kubectl wait --for=condition=Available \
        deployment/kargo-api \
        -n "${KARGO_NAMESPACE}" \
        --timeout=300s

    kargo_create_git_credentials

    log_success "KARGO: Fully deployed"
}

kargo_create_git_credentials() {
    log_info "Waiting for Kargo project namespace to be created..."
    local elapsed=0
    local interval=5
    while [[ ${elapsed} -lt 120 ]]; do
        if kubectl get namespace "${KARGO_PROJECT}" &>/dev/null; then
            break
        fi
        sleep ${interval}
        elapsed=$((elapsed + interval))
    done

    if ! kubectl get namespace "${KARGO_PROJECT}" &>/dev/null; then
        log_warn "Kargo project namespace '${KARGO_PROJECT}' not found after 120s"
        log_warn "Run manually once the Project resource is synced: kubectl create namespace ${KARGO_PROJECT}"
        return 0
    fi

    local pat
    pat=$(gitlab_get_pat)
    if [[ -z "${pat}" ]]; then
        log_warn "No GitLab PAT found, skipping Kargo git credentials"
        return 0
    fi

    log_info "Creating git credentials secret in Kargo project..."
    kubectl create secret generic gitops-repo \
        --namespace "${KARGO_PROJECT}" \
        --from-literal=repoURL="http://gitlab.gitlab.svc.cluster.local/root/gitops.git" \
        --from-literal=username=oauth2 \
        --from-literal=password="${pat}" \
        --dry-run=client -o yaml | kubectl apply -f -

    kubectl label secret gitops-repo \
        -n "${KARGO_PROJECT}" \
        kargo.akuity.io/cred-type=git \
        --overwrite

    log_success "Kargo git credentials created"
}

kargo_delete() {
    log_step "KARGO: Deleting Kargo resources..."

    # Se ArgoCD e' ancora vivo, la root Application "apps" ricrea queste Application al
    # primo sync: per una rimozione definitiva togliere i manifest dal repo gitops.
    if kubectl get application apps -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
        log_warn "ArgoCD is still running: the app-of-apps will recreate these Applications"
    fi

    log_info "Deleting ArgoCD Applications for Kargo stages..."
    for app in kargo-demo-dev kargo-demo-staging kargo-demo-prod kargo-project; do
        kubectl delete application "${app}" -n "${ARGOCD_NAMESPACE}" --ignore-not-found 2>/dev/null || true
    done

    log_info "Deleting Kargo resources in project namespace..."
    kubectl delete stages --all -n "${KARGO_PROJECT}" --ignore-not-found 2>/dev/null || true
    kubectl delete warehouses --all -n "${KARGO_PROJECT}" --ignore-not-found 2>/dev/null || true
    kubectl delete promotiontasks --all -n "${KARGO_PROJECT}" --ignore-not-found 2>/dev/null || true

    # Project is cluster-scoped; deleting it removes the project namespace
    kubectl delete project "${KARGO_PROJECT}" --ignore-not-found 2>/dev/null || true

    log_info "Deleting application namespaces..."
    for ns in kargo-demo-dev kargo-demo-staging kargo-demo-prod; do
        kubectl delete namespace "${ns}" --ignore-not-found 2>/dev/null || true
    done

    log_info "Uninstalling Kargo Helm release..."
    helm uninstall kargo -n "${KARGO_NAMESPACE}" 2>/dev/null || true
    kubectl delete namespace "${KARGO_NAMESPACE}" --ignore-not-found 2>/dev/null || true

    log_success "KARGO: Resources deleted"
}

kargo_info() {
    local kargo_url="https://localhost:${KARGO_LOCAL_PORT}"

    local items=(
        "Kargo URL:      ${kargo_url}"
        "Kargo User:     admin"
        "Kargo Password: ${KARGO_ADMIN_PASSWORD}"
        ""
    )

    if kubectl get namespace "${KARGO_PROJECT}" &>/dev/null; then
        local stages
        stages=$(kubectl get stages -n "${KARGO_PROJECT}" --no-headers 2>/dev/null || echo "")
        if [[ -n "${stages}" ]]; then
            items+=("Stages:")
            while IFS= read -r line; do
                items+=("  ${line}")
            done <<< "${stages}"
        else
            items+=("Stages: (none yet)")
        fi
    else
        items+=("Stages: (namespace not ready)")
    fi

    print_summary_box "KARGO ACCESS" "${items[@]}"
}
