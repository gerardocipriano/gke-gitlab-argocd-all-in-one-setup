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

gitlab_wait_for_rails() {
    local gitlab_pod="$1"
    local max_attempts="${2:-60}"
    local attempt=0

    log_info "Waiting for GitLab Rails to be ready..."
    while [[ ${attempt} -lt ${max_attempts} ]]; do
        if gitlab_rails_runner "${gitlab_pod}" 'puts "ok"' &>/dev/null; then
            log_success "GitLab Rails is ready"
            return 0
        fi
        attempt=$((attempt + 1))
        log_info "Waiting for Rails... (${attempt}/${max_attempts})"
        sleep 10
    done
    log_error "GitLab Rails did not become ready"
    return 1
}

gitlab_wait_for_api() {
    local gitlab_pod="$1"
    local pat="$2"
    local max_attempts="${3:-120}"
    local attempt=0

    log_info "Waiting for GitLab API..."
    while [[ ${attempt} -lt ${max_attempts} ]]; do
        local status
        status=$(kubectl exec -n "${GITLAB_NAMESPACE}" "${gitlab_pod}" -- \
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

gitlab_ensure_root_user() {
    log_step "GITLAB: Ensuring root admin user exists..."

    local gitlab_pod
    gitlab_pod=$(gitlab_get_pod)
    if [[ -z "${gitlab_pod}" ]]; then
        log_error "GitLab pod not found"
        return 1
    fi

    gitlab_wait_for_rails "${gitlab_pod}" || return 1

    local admin_count
    admin_count=$(gitlab_rails_runner "${gitlab_pod}" 'puts User.admins.count' | tail -1)

    if [[ "${admin_count}" =~ ^[0-9]+$ ]] && [[ "${admin_count}" -gt 0 ]]; then
        log_success "Root admin exists (${admin_count} admin(s))"
        log_info "Resetting root password to match config..."
        gitlab_rails_runner "${gitlab_pod}" "
u = User.find_by(username: 'root')
u.password = '${GITLAB_ROOT_PASSWORD}'
u.password_confirmation = '${GITLAB_ROOT_PASSWORD}'
u.save!
puts 'PASSWORD_RESET_OK'
" | tail -1
        return 0
    fi

    log_warn "No admin users found — creating root user..."
    gitlab_rails_runner "${gitlab_pod}" "
u = User.new(
  username: 'root',
  email: 'admin@example.com',
  name: 'Administrator',
  password: '${GITLAB_ROOT_PASSWORD}',
  password_confirmation: '${GITLAB_ROOT_PASSWORD}',
  admin: true,
  user_type: :human
)
u.skip_confirmation!
u.assign_personal_namespace(Organizations::Organization.default_organization)
u.save!
puts 'ROOT_USER_CREATED: id=' + u.id.to_s
" | tail -1

    log_success "Root admin user created | username=root"
}

gitlab_create_pat() {
    log_step "GITLAB: Creating Personal Access Token..."

    local existing_pat
    existing_pat=$(gitlab_get_pat)
    if [[ -n "${existing_pat}" ]]; then
        local gitlab_pod
        gitlab_pod=$(gitlab_get_pod)
        local pat_valid
        pat_valid=$(kubectl exec -n "${GITLAB_NAMESPACE}" "${gitlab_pod}" -- \
            curl -sf -o /dev/null -w "%{http_code}" \
            -H "PRIVATE-TOKEN: ${existing_pat}" \
            http://localhost:80/api/v4/user 2>/dev/null || echo "000")
        if [[ "${pat_valid}" == "200" ]]; then
            log_success "Existing PAT is still valid"
            return 0
        fi
        log_warn "Existing PAT is invalid, creating new one..."
    fi

    local gitlab_pod
    gitlab_pod=$(gitlab_get_pod)
    if [[ -z "${gitlab_pod}" ]]; then
        log_error "GitLab pod not found"
        return 1
    fi

    # Purpose: create PAT via rails runner (only reliable method in GitLab 18.x)
    local pat_output
    pat_output=$(gitlab_rails_runner "${gitlab_pod}" '
u = User.find_by(username: "root")
u.personal_access_tokens.where(name: "bootstrap-token").each(&:revoke!)
token = u.personal_access_tokens.create!(
  name: "bootstrap-token",
  scopes: [:api, :read_repository, :write_repository],
  expires_at: 365.days.from_now
)
puts "PAT_TOKEN=#{token.token}"
' | grep "PAT_TOKEN=" | head -1)

    local pat_token="${pat_output#PAT_TOKEN=}"
    if [[ -z "${pat_token}" ]]; then
        log_error "Failed to create PAT"
        return 1
    fi

    # Purpose: store PAT in K8s secret for use by gitops and argocd modules
    kubectl create secret generic "${GITLAB_PAT_SECRET_NAME}" \
        --namespace="${GITLAB_NAMESPACE}" \
        --from-literal=token="${pat_token}" \
        --dry-run=client -o yaml | kubectl apply -f -

    log_success "PAT created and stored in secret '${GITLAB_PAT_SECRET_NAME}'"

    local verify_status
    verify_status=$(kubectl exec -n "${GITLAB_NAMESPACE}" "${gitlab_pod}" -- \
        curl -sf -o /dev/null -w "%{http_code}" \
        -H "PRIVATE-TOKEN: ${pat_token}" \
        http://localhost:80/api/v4/user 2>/dev/null || echo "000")

    if [[ "${verify_status}" == "200" ]]; then
        log_success "PAT verified successfully"
    else
        log_error "PAT verification failed (HTTP ${verify_status})"
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

    local gitlab_manifest="${SCRIPT_DIR}/manifests/gitlab/gitlab-deployment.yaml"
    if [[ ! -f "${gitlab_manifest}" ]]; then
        log_error "GitLab manifest not found: ${gitlab_manifest}"
        exit 1
    fi

    kubectl apply -f "${gitlab_manifest}"

    log_info "Waiting for GitLab to be ready (10-15 minutes)..."
    wait_for_pod_ready "${GITLAB_NAMESPACE}" "app=gitlab" 1200 || {
        log_error "GitLab failed to start"
        log_info "Check: kubectl logs -n ${GITLAB_NAMESPACE} -l app=gitlab"
        return 1
    }

    log_info "Waiting for GitLab internal services..."
    sleep 60

    gitlab_ensure_root_user
    gitlab_create_pat

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
