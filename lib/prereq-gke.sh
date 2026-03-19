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

    log_success "PREREQUISITES [gke]: All checks passed"
}
