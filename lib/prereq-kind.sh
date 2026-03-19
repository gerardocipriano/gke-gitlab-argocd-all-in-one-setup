#!/usr/bin/env bash
# Purpose: prerequisites for kind provider (docker, kind, kubectl)

prereq_check_all() {
    log_step "PREREQUISITES [kind]: Checking all..."

    log_step "PREREQ: Checking Docker..."
    if ! command_exists docker; then
        log_error "Docker not found. Install: https://docs.docker.com/get-docker/"
        exit 1
    fi
    if ! docker info &>/dev/null; then
        log_error "Docker daemon is not running"
        exit 1
    fi
    log_success "Docker is running"

    log_step "PREREQ: Checking kind..."
    if ! command_exists kind; then
        log_info "Installing kind..."
        local os arch
        os=$(uname -s | tr '[:upper:]' '[:lower:]')
        arch=$(uname -m); [[ "${arch}" == "x86_64" ]] && arch="amd64"; [[ "${arch}" == "aarch64" ]] && arch="arm64"
        download_file "https://kind.sigs.k8s.io/dl/v0.25.0/kind-${os}-${arch}" /tmp/kind
        chmod +x /tmp/kind
        sudo mv /tmp/kind /usr/local/bin/kind
    fi
    log_success "kind ready: $(kind --version)"

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

    log_success "PREREQUISITES [kind]: All checks passed"
}
