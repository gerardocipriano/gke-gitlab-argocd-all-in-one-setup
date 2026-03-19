#!/usr/bin/env bash
# Purpose: install/check prerequisites (gcloud, kubectl, argocd CLI, GCP APIs)

prereq_check_gcloud() {
    log_step "PREREQ: Checking gcloud CLI..."
    if ! command_exists gcloud; then
        log_error "gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install"
        exit 1
    fi
    log_success "gcloud CLI found: $(gcloud --version | head -1)"
}

prereq_check_gcloud_auth() {
    log_step "PREREQ: Checking gcloud authentication..."
    if ! gcloud auth print-access-token &> /dev/null; then
        log_error "Not authenticated. Run: gcloud auth login"
        exit 1
    fi
    log_success "gcloud authentication verified"
}

prereq_check_gcloud_beta() {
    log_info "Ensuring gcloud beta component..."
    gcloud components install beta --quiet 2>/dev/null || true
    log_success "gcloud beta ready"
}

prereq_set_project() {
    log_info "Setting gcloud project to '${GKE_PROJECT_ID}'..."
    gcloud config set project "${GKE_PROJECT_ID}" --quiet
    log_success "Project set to ${GKE_PROJECT_ID}"
}

prereq_install_kubectl() {
    log_step "PREREQ: Checking kubectl..."
    if command_exists kubectl; then
        log_success "kubectl already installed"
        return 0
    fi
    log_info "Installing kubectl ${KUBECTL_VERSION}..."
    local os arch
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m); [[ "${arch}" == "x86_64" ]] && arch="amd64"
    download_file "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${os}/${arch}/kubectl" /tmp/kubectl
    sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
    log_success "kubectl installed"
}

prereq_install_argocd_cli() {
    log_step "PREREQ: Checking argocd CLI..."
    if command_exists argocd; then
        log_success "argocd CLI already installed"
        return 0
    fi
    log_info "Installing argocd CLI ${ARGOCD_CLI_VERSION}..."
    local os arch
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m); [[ "${arch}" == "x86_64" ]] && arch="amd64"
    download_file "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_CLI_VERSION}/argocd-${os}-${arch}" /tmp/argocd
    sudo install -o root -g root -m 0755 /tmp/argocd /usr/local/bin/argocd
    log_success "argocd CLI installed"
}

prereq_enable_gcp_apis() {
    log_step "PREREQ: Enabling GCP APIs..."
    local apis=(
        "container.googleapis.com"
        "compute.googleapis.com"
        "iam.googleapis.com"
        "logging.googleapis.com"
        "monitoring.googleapis.com"
        "cloudresourcemanager.googleapis.com"
    )
    for api in "${apis[@]}"; do
        log_debug "Enabling ${api}..."
        gcloud services enable "${api}" --project="${GKE_PROJECT_ID}" --quiet 2>/dev/null || true
    done
    log_success "GCP APIs enabled"
}

prereq_check_all() {
    log_step "PREREQUISITES: Checking all..."
    prereq_check_gcloud
    prereq_check_gcloud_auth
    prereq_check_gcloud_beta
    prereq_set_project
    prereq_enable_gcp_apis
    prereq_install_kubectl
    prereq_install_argocd_cli
    log_success "PREREQUISITES: All checks passed"
}
