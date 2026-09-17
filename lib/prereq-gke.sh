#!/usr/bin/env bash
# Purpose: prerequisites for GKE provider (gcloud, kubectl, argocd CLI, GCP APIs)

prereq_check_all() {
    log_step "PREREQUISITES [gke]: Checking all..."

    log_step "PREREQ: Checking gcloud CLI..."
    if ! command_exists gcloud; then
        log_error "gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install"
        exit 1
    fi
    log_success "gcloud CLI found: $(gcloud --version | head -1)"

    log_step "PREREQ: Checking gcloud authentication..."
    if ! gcloud auth print-access-token &> /dev/null; then
        log_error "Not authenticated. Run: gcloud auth login"
        exit 1
    fi
    log_success "gcloud authenticated"

    log_info "Ensuring gcloud beta..."
    gcloud components install beta --quiet 2>/dev/null || true

    log_info "Setting project to '${GKE_PROJECT_ID}'..."
    gcloud config set project "${GKE_PROJECT_ID}" --quiet

    log_step "PREREQ: Enabling GCP APIs..."
    local apis=("container.googleapis.com" "compute.googleapis.com" "iam.googleapis.com")
    for api in "${apis[@]}"; do
        gcloud services enable "${api}" --project="${GKE_PROJECT_ID}" --quiet 2>/dev/null || true
    done
    log_success "GCP APIs enabled"

    log_step "PREREQ: Checking kubectl..."
    if ! command_exists kubectl; then
        log_info "Installing kubectl..."
        local os arch version
        os=$(uname -s | tr '[:upper:]' '[:lower:]')
        arch=$(uname -m); [[ "${arch}" == "x86_64" ]] && arch="amd64"; [[ "${arch}" == "aarch64" ]] && arch="arm64"
        version=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
        download_file "https://dl.k8s.io/release/${version}/bin/${os}/${arch}/kubectl" /tmp/kubectl
        chmod +x /tmp/kubectl
        sudo mv /tmp/kubectl /usr/local/bin/kubectl
    fi
    log_success "kubectl ready"

    log_step "PREREQ: Checking Helm..."
    if ! command_exists helm; then
        log_error "Helm not found. Install: https://helm.sh/docs/intro/install/"
        return 1
    fi
    local helm_version
    helm_version=$(helm version --short 2>/dev/null | sed 's/^v//' | cut -d. -f1-2)
    if [[ "$(printf '%s\n' "3.13" "${helm_version}" | sort -V | head -1)" != "3.13" ]]; then
        log_error "Helm >= 3.13 required (found: ${helm_version}). Upgrade: https://helm.sh/docs/intro/install/"
        return 1
    fi
    log_success "Helm ready: $(helm version --short)"

    log_success "PREREQUISITES [gke]: All checks passed"
}
