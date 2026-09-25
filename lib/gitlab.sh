#!/usr/bin/env bash
# Purpose: GitLab CE deploy, root user creation, PAT management

gitlab_get_pod() {
    kubectl get pods -n "${GITLAB_NAMESPACE}" -l app=gitlab \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

gitlab_get_pat() {
    kubectl get secret "${GITLAB_PAT_SECRET_NAME}" -n "${GITLAB_NAMESPACE}" \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || echo ""
}

gitlab_rails_runner() {
    local gitlab_pod="$1"
    local ruby_code="$2"
    kubectl exec -n "${GITLAB_NAMESPACE}" "${gitlab_pod}" -- \
        gitlab-rails runner "${ruby_code}" 2>/dev/null
}

# Il pod si risolve a ogni tentativo: un riavvio (patch Spot, eviction) cambia il nome e
# un exec sul pod vecchio fallirebbe fino al timeout. Si interroga puma via HTTP invece di
# un rails runner, che per rispondere carica Rails da capo (circa due minuti a chiamata).
gitlab_wait_for_rails() {
    local max_attempts="${1:-90}"
    local attempt=0 gitlab_pod status

    log_info "Waiting for GitLab Rails to be ready..."
    while [[ ${attempt} -lt ${max_attempts} ]]; do
        gitlab_pod=$(gitlab_get_pod)
        status=$(kubectl exec -n "${GITLAB_NAMESPACE}" "${gitlab_pod:-none}" -- \
            curl -s -o /dev/null -w "%{http_code}" http://localhost:80/users/sign_in 2>/dev/null || echo "000")
        if [[ "${status}" == "200" ]]; then
            log_success "GitLab Rails is ready"
            return 0
        fi
        attempt=$((attempt + 1))
        log_info "Waiting for Rails... (${attempt}/${max_attempts}, HTTP ${status})"
        sleep 10
    done
    log_error "GitLab Rails did not become ready"
    return 1
}

gitlab_wait_for_api() {
    local pat="$1"
    local max_attempts="${2:-120}"
    local attempt=0 gitlab_pod status

    log_info "Waiting for GitLab API..."
    while [[ ${attempt} -lt ${max_attempts} ]]; do
        gitlab_pod=$(gitlab_get_pod)
        status=$(kubectl exec -n "${GITLAB_NAMESPACE}" "${gitlab_pod:-none}" -- \
            curl -sf -o /dev/null -w "%{http_code}" \
            -H "PRIVATE-TOKEN: ${pat}" \
            http://localhost:80/api/v4/version 2>/dev/null || echo "000")
        if [[ "${status}" == "200" ]]; then
            log_success "GitLab API is responding"
            return 0
        fi
        attempt=$((attempt + 1))
        log_info "Waiting for API... (${attempt}/${max_attempts}, HTTP ${status})"
        sleep 10
    done
    log_error "GitLab API timeout"
    return 1
}

gitlab_pat_is_valid() {
    local pat="$1" gitlab_pod
    [[ -n "${pat}" ]] || return 1
    gitlab_pod=$(gitlab_get_pod)
    [[ "$(kubectl exec -n "${GITLAB_NAMESPACE}" "${gitlab_pod}" -- \
        curl -sf -o /dev/null -w "%{http_code}" -H "PRIVATE-TOKEN: ${pat}" \
        http://localhost:80/api/v4/user 2>/dev/null)" == "200" ]]
}

# Utente root, password e PAT in un solo rails runner: ogni invocazione carica Rails da
# capo e costa circa due minuti, tre chiamate separate ne costavano sei.
gitlab_bootstrap_root() {
    log_step "GITLAB: Ensuring root user, password and Personal Access Token..."

    gitlab_wait_for_rails || return 1

    if gitlab_pat_is_valid "$(gitlab_get_pat)"; then
        log_success "Existing PAT is still valid, root already configured"
        return 0
    fi

    local gitlab_pod output pat_token
    gitlab_pod=$(gitlab_get_pod)
    # La password passa come variabile d'ambiente del processo nel pod, non interpolata nel
    # codice Ruby: un apice nella password romperebbe lo script.
    output=$(kubectl exec -n "${GITLAB_NAMESPACE}" "${gitlab_pod}" -- \
        env GITLAB_PW="${GITLAB_ROOT_PASSWORD}" gitlab-rails runner '
pw = ENV.fetch("GITLAB_PW")
u = User.find_by(username: "root")
if u.nil?
  u = User.new(username: "root", email: "admin@example.com", name: "Administrator", admin: true, user_type: :human)
  u.skip_confirmation!
  u.assign_personal_namespace(Organizations::Organization.default_organization)
  puts "ROOT_CREATED"
end
u.password = pw
u.password_confirmation = pw
u.save!
u.personal_access_tokens.where(name: "bootstrap-token").each(&:revoke!)
token = u.personal_access_tokens.create!(
  name: "bootstrap-token",
  scopes: [:api, :read_repository, :write_repository],
  expires_at: 365.days.from_now
)
puts "PAT_TOKEN=#{token.token}"
' 2>/dev/null)
    pat_token=$(grep -o 'PAT_TOKEN=.*' <<< "${output}" | head -1)
    pat_token="${pat_token#PAT_TOKEN=}"
    if [[ -z "${pat_token}" ]]; then
        log_error "Failed to configure root and create PAT"
        return 1
    fi
    grep -q ROOT_CREATED <<< "${output}" && log_info "Root user created"

    kubectl create secret generic "${GITLAB_PAT_SECRET_NAME}" \
        --namespace="${GITLAB_NAMESPACE}" \
        --from-literal=token="${pat_token}" \
        --dry-run=client -o yaml | kubectl apply -f -

    if gitlab_pat_is_valid "${pat_token}"; then
        log_success "Root configured, PAT stored in secret '${GITLAB_PAT_SECRET_NAME}'"
    else
        log_error "PAT verification failed"
        return 1
    fi
}

gitlab_deploy() {
    log_step "GITLAB: Deploying GitLab CE..."

    if kubectl get namespace "${GITLAB_NAMESPACE}" &>/dev/null; then
        if kubectl get deployment -n "${GITLAB_NAMESPACE}" gitlab-ce &>/dev/null; then
            log_warn "GitLab is already deployed"
            read -r -p "Redeploy? [y/N]: " response
            if [[ ! "${response}" =~ ^[Yy]$ ]]; then
                log_info "Skipping GitLab deployment"
                return 0
            fi
        fi
    fi

    kubectl create namespace "${GITLAB_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    local gitlab_manifest="${SCRIPT_DIR}/repos/platform/gitlab/gitlab-deployment.yaml"
    if [[ ! -f "${gitlab_manifest}" ]]; then
        log_error "GitLab manifest not found: ${gitlab_manifest}"
        exit 1
    fi

    kubectl apply -f "${gitlab_manifest}"

    log_info "Waiting for GitLab to be ready (8-12 minutes)..."
    wait_for_pod_ready "${GITLAB_NAMESPACE}" "app=gitlab" 1200 || {
        log_error "GitLab failed to start"
        log_info "Check: kubectl logs -n ${GITLAB_NAMESPACE} -l app=gitlab"
        return 1
    }

    gitlab_bootstrap_root || return 1

    log_success "GITLAB: Deployed and configured"
}

gitlab_delete() {
    log_step "GITLAB: Deleting GitLab resources..."

    log_info "Deleting GitLab namespace..."
    kubectl delete namespace "${GITLAB_NAMESPACE}" --ignore-not-found 2>/dev/null || true

    log_success "GITLAB: Resources deleted"
}

gitlab_info() {
    log_info "GitLab Access Information:"
    local pat
    pat=$(gitlab_get_pat)
    echo ""
    echo "  Port-forward:   kubectl port-forward -n ${GITLAB_NAMESPACE} svc/gitlab ${GITLAB_LOCAL_PORT}:80"
    echo "  GitLab URL:     http://localhost:${GITLAB_LOCAL_PORT}"
    echo "  Root Username:  root"
    echo "  Root Password:  ${GITLAB_ROOT_PASSWORD}"
    echo "  API Token:      ${pat:-N/A}"
    echo "  API Test:       curl -H 'PRIVATE-TOKEN: <token>' http://localhost:${GITLAB_LOCAL_PORT}/api/v4/user"
    echo ""
}

# ---------------------------------------------------------------------------
# GitLab via API, dall'interno del pod
# ---------------------------------------------------------------------------

gitlab_api() {
    local method="$1" path="$2" data="${3:-}"
    local pod pat
    pod=$(gitlab_get_pod)
    pat=$(gitlab_get_pat)
    if [[ -n "${data}" ]]; then
        printf '%s' "${data}" | kubectl exec -i -n "${GITLAB_NAMESPACE}" "${pod}" -- \
            curl -sf -X "${method}" -H "PRIVATE-TOKEN: ${pat}" -H 'Content-Type: application/json' \
            --data @- "http://localhost:80/api/v4${path}"
    else
        kubectl exec -n "${GITLAB_NAMESPACE}" "${pod}" -- \
            curl -sf -X "${method}" -H "PRIVATE-TOKEN: ${pat}" "http://localhost:80/api/v4${path}"
    fi
}

# Il repo e' l'ultimo argomento, opzionale: di default quello dell'app promossa da Kargo.
gitlab_repo_path() {
    jq -rn --arg r "root/${1:-${KARGO_PROJECT}}" '$r|@uri'
}

gitlab_file_raw() {
    local file="$1" ref="$2" repo="${3:-}"
    gitlab_api GET "/projects/$(gitlab_repo_path "${repo}")/repository/files/$(jq -rn --arg f "${file}" '$f|@uri')/raw?ref=$(jq -rn --arg r "${ref}" '$r|@uri')"
}

# Uso: gitlab_commit_file FILE CONTENUTO MESSAGGIO [REPO]  (su main). Stampa lo short id.
gitlab_commit_file() {
    local file="$1" content="$2" message="$3" repo="${4:-}"
    gitlab_api POST "/projects/$(gitlab_repo_path "${repo}")/repository/commits" \
        "$(jq -cn --arg f "${file}" --arg c "${content}" --arg m "${message}" \
            '{branch: "main", commit_message: $m, actions: [{action: "update", file_path: $f, content: $c}]}')" |
        jq -r '.short_id // empty'
}

gitlab_last_commit() {
    local ref="$1" repo="${2:-}"
    gitlab_api GET "/projects/$(gitlab_repo_path "${repo}")/repository/commits?ref_name=$(jq -rn --arg r "${ref}" '$r|@uri')&per_page=1" |
        jq -r '.[0] | "\(.short_id)  \(.author_name) <\(.author_email)>  \(.title)"'
}
