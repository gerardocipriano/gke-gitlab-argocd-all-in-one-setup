#!/usr/bin/env bash
# Purpose: Kargo install, password hash, git credentials, and info

# Il binario docker può esserci con il daemon spento: si controlla docker info, non la
# presenza del comando, altrimenti l'hash esce vuoto e set -e chiude lo script in silenzio.
kargo_generate_password_hash() {
    if command_exists htpasswd; then
        htpasswd -bnBC 10 '' "${KARGO_ADMIN_PASSWORD}" | tr -d ':\n'
    elif command_exists python3 && python3 -c 'import bcrypt' 2>/dev/null; then
        KARGO_PW="${KARGO_ADMIN_PASSWORD}" python3 -c \
            'import bcrypt, os; print(bcrypt.hashpw(os.environ["KARGO_PW"].encode(), bcrypt.gensalt(10)).decode(), end="")'
    elif command_exists docker && docker info &>/dev/null; then
        docker run --rm httpd:2.4-alpine \
            htpasswd -bnBC 10 '' "${KARGO_ADMIN_PASSWORD}" | tr -d ':\n'
    elif [[ "${KARGO_ADMIN_PASSWORD}" == "Karg0D3m02025xZ" ]]; then
        log_warn "htpasswd, python3-bcrypt e docker assenti: uso l'hash precalcolato della password di default"
        echo "${KARGO_ADMIN_PASSWORD_HASH}"
    else
        log_error "Serve htpasswd, python3 con bcrypt o docker attivo per l'hash di KARGO_ADMIN_PASSWORD"
        return 1
    fi
}

# Il chart di Kargo crea Certificate e Issuer per l'API e i webhook server: senza le CRD di
# cert-manager l'installazione fallisce in fase di rendering.
kargo_install_cert_manager() {
    # La presenza delle CRD non basta: sopravvivono a un helm uninstall, e senza il
    # controller i Certificate di Kargo non vengono mai emessi (pod in ContainerCreating
    # su secret kargo-api-cert assente). Si guarda il deployment.
    if kubectl get deployment cert-manager -n "${CERT_MANAGER_NAMESPACE}" &>/dev/null; then
        log_info "cert-manager already installed"
        return 0
    fi

    log_info "Installing cert-manager ${CERT_MANAGER_VERSION} (dipendenza di Kargo)..."
    helm upgrade --install cert-manager \
        oci://quay.io/jetstack/charts/cert-manager \
        --namespace "${CERT_MANAGER_NAMESPACE}" \
        --create-namespace \
        --version "${CERT_MANAGER_VERSION}" \
        --set crds.enabled=true \
        --set global.leaderElection.namespace="${CERT_MANAGER_NAMESPACE}" \
        --set-string 'nodeSelector.cloud\.google\.com/gke-spot=true' \
        --set-string 'webhook.nodeSelector.cloud\.google\.com/gke-spot=true' \
        --set-string 'cainjector.nodeSelector.cloud\.google\.com/gke-spot=true' \
        --set-string 'startupapicheck.nodeSelector.cloud\.google\.com/gke-spot=true' \
        --wait \
        --timeout 10m

    # leaderElection.namespace: di default cert-manager prende il lease in kube-system, che
    # su GKE Autopilot è un managed namespace e GKE Warden nega la scrittura. Senza questo
    # flag il controller resta senza leadership, i Certificate non vengono emessi e i pod
    # Kargo restano in ContainerCreating sul secret kargo-api-cert assente.
    kubectl wait --for=condition=Available \
        deployment/cert-manager-webhook \
        -n "${CERT_MANAGER_NAMESPACE}" \
        --timeout=300s

    log_success "cert-manager installed"
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

    kargo_install_cert_manager

    local password_hash
    password_hash=$(kargo_generate_password_hash) || return 1
    if [[ -z "${password_hash}" ]]; then
        log_error "Hash della password admin di Kargo vuoto"
        return 1
    fi

    local token_signing_key
    # I caratteri =+/ romperebbero il parsing di helm --set
    token_signing_key=$(openssl rand -base64 48 | tr -d "=+/" | head -c 32)

    # GitLab gira dentro il cluster senza TLS, quindi il repo GitOps si raggiunge in HTTP.
    # Di default il controller rifiuta di usare credenziali git su HTTP e ogni promozione
    # fallisce sul clone: per questa demo locale il flag va abilitato. In un ambiente reale
    # si mette TLS su GitLab e si lascia il default.
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
        --set api.service.nodePort=30081 \
        --set controller.allowCredentialsOverHTTP=true

    log_info "Waiting for kargo-api deployment to become Available..."
    kubectl wait --for=condition=Available \
        deployment/kargo-api \
        -n "${KARGO_NAMESPACE}" \
        --timeout=300s

    kargo_create_git_credentials

    log_success "KARGO: Fully deployed"
}

# Le credenziali git devono esistere prima del primo Freight, altrimenti la promozione
# automatica di dev fallisce sul clone e non viene ritentata. Per questo il namespace del
# progetto si crea qui, con l'etichetta che Kargo richiede per adottarlo, e il secret ci va
# dentro prima che ArgoCD crei Project e Warehouse.
kargo_create_git_credentials() {
    local pat
    pat=$(gitlab_get_pat)
    if [[ -z "${pat}" ]]; then
        log_error "PAT GitLab assente: le credenziali git di Kargo non si possono creare"
        return 1
    fi

    log_info "Creating project namespace and git credentials before the Project..."
    kubectl create namespace "${KARGO_PROJECT}" --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace "${KARGO_PROJECT}" kargo.akuity.io/project=true --overwrite

    # Il vincolo fisso va applicato prima del secret: senza credenziali il Warehouse non
    # riesce a leggere il repo privato, quindi non può produrre un Freight con il vincolo vero.
    local seeding=0
    if [[ -z "$(kubectl get freight -n "${KARGO_PROJECT}" -o name 2>/dev/null)" ]]; then
        seeding=1
        log_info "Pinning the Warehouse to podinfo ${KARGO_SEED_TAG} for the first Freight..."
        kargo_commit_constraint "${KARGO_SEED_TAG}" \
            "chore(warehouse): ${KARGO_SEED_TAG} come Freight di partenza" || return 1
        kargo_wait_constraint "${KARGO_SEED_TAG}" || return 1
    fi

    kubectl create secret generic gitops-repo \
        --namespace "${KARGO_PROJECT}" \
        --from-literal=repoURL="http://gitlab.${GITLAB_NAMESPACE}.svc.cluster.local/root/${KARGO_PROJECT}.git" \
        --from-literal=username=oauth2 \
        --from-literal=password="${pat}" \
        --dry-run=client -o yaml | kubectl apply -f -
    kubectl label secret gitops-repo -n "${KARGO_PROJECT}" kargo.akuity.io/cred-type=git --overwrite

    # kargo-project ha tentato il sync prima che esistessero le CRD ed è in retry con backoff
    # fino a 2 minuti: si chiede il sync subito.
    kubectl patch application kargo-project -n "${ARGOCD_NAMESPACE}" --type merge \
        -p '{"operation":{"initiatedBy":{"username":"bootstrap"},"sync":{}}}' &>/dev/null || true

    log_info "Waiting for the Kargo Stages..."
    local elapsed=0
    while (( elapsed < 300 )); do
        [[ "$(kubectl get stages -n "${KARGO_PROJECT}" --no-headers 2>/dev/null | wc -l)" -ge 3 ]] && break
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done
    if (( elapsed >= 300 )); then
        log_error "Stage Kargo assenti dopo 300s: controlla l'Application kargo-project"
        return 1
    fi
    log_success "Kargo git credentials created, Project and Stages synced"

    (( seeding == 1 )) && { kargo_seed_freight || return 1; }
    return 0
}

# Due Freight per la demo, il più vecchio creato per primo: l'auto-promozione di dev sceglie
# il Freight creato per ultimo, non il tag più alto, e un 6.9.3 aggiunto dopo farebbe
# tornare dev indietro. Con un solo vincolo il Warehouse crea un Freight solo dal tag più recente.
kargo_seed_freight() {
    local original
    original=$(sed -n 's/.*constraint: "\(.*\)".*/\1/p' \
        "${SCRIPT_DIR}/repos/${KARGO_PROJECT}/kargo/warehouse.yaml" | head -1)

    kargo_wait_freight_count 1 || return 1
    log_info "Restoring the Warehouse constraint ${original}..."
    kargo_commit_constraint "${original}" \
        "chore(warehouse): torna a osservare la serie ${original}" || return 1
    kargo_wait_constraint "${original}" || return 1
    kargo_wait_freight_count 2 || return 1
    log_success "Two Freight ready: podinfo ${KARGO_SEED_TAG} and the newest of ${original}"
}

# Committa su main kargo/warehouse.yaml con il vincolo indicato e chiede il sync ad ArgoCD.
kargo_commit_constraint() {
    local want="$1" message="$2" content current
    content=$(gitlab_file_raw kargo/warehouse.yaml main) || {
        log_error "kargo/warehouse.yaml non leggibile da GitLab"
        return 1
    }
    current=$(sed -n 's/.*constraint: "\(.*\)".*/\1/p' <<< "${content}" | head -1)
    if [[ "${current}" != "${want}" ]]; then
        gitlab_commit_file kargo/warehouse.yaml \
            "${content//constraint: \"${current}\"/constraint: \"${want}\"}" "${message}" >/dev/null || {
            log_error "Commit del vincolo ${want} fallito"
            return 1
        }
    fi
    kubectl patch application kargo-project -n "${ARGOCD_NAMESPACE}" --type merge \
        -p '{"operation":{"initiatedBy":{"username":"bootstrap"},"sync":{}}}' &>/dev/null || true
}

kargo_wait_constraint() {
    local want="$1" elapsed=0
    while (( elapsed < 180 )); do
        [[ "$(kubectl get warehouse kargo-demo -n "${KARGO_PROJECT}" \
            -o jsonpath='{.spec.subscriptions[0].image.constraint}' 2>/dev/null)" == "${want}" ]] && return 0
        sleep 3
        elapsed=$(( elapsed + 3 ))
    done
    log_error "Il Warehouse non ha il vincolo ${want} dopo 180s: controlla l'Application kargo-project"
    return 1
}

# Il refresh evita di aspettare l'intervallo del Warehouse (5 minuti) o il suo backoff.
kargo_wait_freight_count() {
    local want="$1" elapsed=0
    kubectl annotate warehouse kargo-demo -n "${KARGO_PROJECT}" \
        "kargo.akuity.io/refresh=$(date +%s)" --overwrite &>/dev/null || true
    while (( elapsed < 300 )); do
        (( $(kubectl get freight -n "${KARGO_PROJECT}" --no-headers 2>/dev/null | wc -l) >= want )) && return 0
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done
    log_error "Meno di ${want} Freight dopo 300s: controlla il Warehouse nella UI di Kargo"
    return 1
}

kargo_delete() {
    log_step "KARGO: Deleting Kargo resources..."

    # Se ArgoCD è ancora vivo, la root Application "apps" ricrea queste Application al
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
        kubectl delete namespace "${ns}" --ignore-not-found --wait=false 2>/dev/null || true
    done

    log_info "Uninstalling cert-manager Helm release..."
    helm uninstall cert-manager -n "${CERT_MANAGER_NAMESPACE}" 2>/dev/null || true
    kubectl delete namespace "${CERT_MANAGER_NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true

    log_info "Uninstalling Kargo Helm release..."
    helm uninstall kargo -n "${KARGO_NAMESPACE}" 2>/dev/null || true
    kubectl delete namespace "${KARGO_NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true

    # helm lascia in piedi le CRD per policy: senza questo passaggio restano orfane nel cluster
    log_info "Deleting Kargo CRDs..."
    kubectl get crd -o name 2>/dev/null | grep 'kargo\.akuity\.io$' |
        xargs -r kubectl delete --ignore-not-found 2>/dev/null || true

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
