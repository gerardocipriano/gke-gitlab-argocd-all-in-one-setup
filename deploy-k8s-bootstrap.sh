#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# KUBERNETES CLUSTER BOOTSTRAP SCRIPT
# Complete GitOps Environment: GKE + GitLab + ArgoCD
# =============================================================================
#
# This script creates a complete Kubernetes environment on GKE with:
# - GKE Cluster (Google Kubernetes Engine)
# - GitLab CE (single pod deployment)
# - ArgoCD (GitOps continuous delivery)
# - App of Apps pattern for GitOps
#
# Usage:
#   ./deploy-k8s-bootstrap.sh [COMMAND] [OPTIONS]
#
# Commands:
#   all         Complete bootstrap (default)
#   prereq      Install prerequisites (gcloud, kubectl, etc.)
#   cluster     Create GKE cluster
#   gitlab      Deploy GitLab
#   argocd      Deploy ArgoCD
#   gitops      Initialize gitops repository
#   appofapps   Deploy App of Apps
#   clean       Remove all resources
#   status      Show cluster status
#
# =============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="${SCRIPT_DIR}"

# =============================================================================
# GKE CONFIGURATION
# =============================================================================

readonly GKE_PROJECT_ID="formazione-gerardo-cipriano"
readonly GKE_CLUSTER_NAME="poc-redis-1"
readonly GKE_ZONE="us-central1-c"
readonly GKE_REGION="us-central1"
readonly GKE_NETWORK="injenia-test"
readonly GKE_SUBNETWORK="injenia-gke-usc1"
readonly GKE_SERVICE_ACCOUNT="gke-sa@${GKE_PROJECT_ID}.iam.gserviceaccount.com"
readonly GKE_MACHINE_TYPE="n2-standard-4"
readonly GKE_NUM_NODES="2"
readonly GKE_DISK_SIZE="50"
readonly GKE_MASTER_AUTHORIZED_NETWORKS="87.18.50.199/32,77.89.24.226/32"

# =============================================================================
# GITLAB CONFIGURATION
# =============================================================================

readonly GITLAB_NAMESPACE="${GITLAB_NAMESPACE:-gitlab}"
readonly GITLAB_IMAGE="${GITLAB_IMAGE:-gitlab/gitlab-ce:18.6.0-ce.0}"
readonly GITLAB_ROOT_PASSWORD="${GITLAB_ROOT_PASSWORD:-GitLabAdmin123!}"

# =============================================================================
# ARGOCd CONFIGURATION
# =============================================================================

readonly ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
readonly ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"
readonly ARGOCD_CLI_VERSION="${ARGOCD_CLI_VERSION:-v2.13.0}"

# =============================================================================
# GITOPS CONFIGURATION
# =============================================================================

readonly GITOPS_REPO_NAME="${GITOPS_REPO_NAME:-gitops}"
readonly GITOPS_REPO_DIR="${SCRIPT_DIR}/gitops-repo"

# =============================================================================
# TOOL VERSIONS
# =============================================================================

readonly KUBECTL_VERSION="${KUBECTL_VERSION:-v1.32.0}"

# =============================================================================
# COLORS AND LOGGING
# =============================================================================

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""
    case "${level}" in
        "ERROR")   color="${RED}" ;;
        "SUCCESS") color="${GREEN}" ;;
        "INFO")    color="${BLUE}" ;;
        "WARN")    color="${YELLOW}" ;;
        "DEBUG")   color="${CYAN}" ;;
        "STEP")    color="${MAGENTA}" ;;
        "HEADER")  color="${BOLD}${CYAN}" ;;
        *)         color="${NC}" ;;
    esac
    printf "[%s] [%b%s%b] %s\n" "$timestamp" "$color" "$level" "$NC" "$message" >&2
}

log_info()    { log "INFO" "$1"; }
log_success() { log "SUCCESS" "$1"; }
log_error()   { log "ERROR" "$1"; }
log_warn()    { log "WARN" "$1"; }
log_debug()   { log "DEBUG" "$1"; }
log_step()    { log "STEP" "$1"; }
log_header()  { log "HEADER" "$1"; }

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

command_exists() {
    command -v "$1" &> /dev/null
}

get_arch() {
    local arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "arm" ;;
        *)       echo "${arch}" ;;
    esac
}

get_os() {
    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "${os}" in
        darwin) echo "darwin" ;;
        linux)  echo "linux" ;;
        *)      echo "${os}" ;;
    esac
}

is_root() {
    [[ $EUID -eq 0 ]]
}

run_with_sudo() {
    if is_root; then
        "$@"
    elif command_exists sudo; then
        sudo "$@"
    else
        log_error "sudo is required but not available"
        exit 1
    fi
}

wait_for_pod_ready() {
    local namespace="$1"
    local label="$2"
    local timeout="${3:-600}"
    
    log_info "Waiting for pod '${label}' in namespace '${namespace}' (${timeout}s)..."
    
    local elapsed=0
    local interval=10
    
    while [[ ${elapsed} -lt ${timeout} ]]; do
        if kubectl get pods -n "${namespace}" -l "${label}" \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
            
            local ready
            ready=$(kubectl get pods -n "${namespace}" -l "${label}" \
                -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
            
            if [[ "${ready}" == "true" ]]; then
                log_success "Pod is ready"
                return 0
            fi
        fi
        
        sleep ${interval}
        elapsed=$((elapsed + interval))
        printf "."
    done
    
    printf "\n"
    log_error "Timeout waiting for pod"
    return 1
}

retry_command() {
    local max_attempts="${1:-5}"
    local delay="${2:-5}"
    local cmd="${3}"
    shift 3
    
    local attempt=1
    while [[ ${attempt} -le ${max_attempts} ]]; do
        if eval "${cmd}"; then
            return 0
        fi
        
        if [[ ${attempt} -lt ${max_attempts} ]]; then
            log_warn "Attempt ${attempt}/${max_attempts} failed, retrying in ${delay}s..."
            sleep ${delay}
        fi
        attempt=$((attempt + 1))
    done
    
    return 1
}

print_summary_box() {
    local title="$1"
    shift
    local items=("$@")
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    printf "║ %-60s ║\n" "${title}"
    echo "╠══════════════════════════════════════════════════════════════╣"
    for item in "${items[@]}"; do
        printf "║ %-60s ║\n" "${item}"
    done
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
}

# =============================================================================
# PREREQUISITES INSTALLATION
# =============================================================================

check_gcloud() {
    log_step "PREREQ: Checking gcloud CLI..."
    
    if ! command_exists gcloud; then
        log_error "gcloud CLI not found"
        log_info "Please install Google Cloud SDK: https://cloud.google.com/sdk/docs/install"
        exit 1
    fi
    
    log_success "gcloud CLI found: $(gcloud --version | head -1)"
}

check_gcloud_auth() {
    log_step "PREREQ: Checking gcloud authentication..."
    
    if ! gcloud auth print-access-token &> /dev/null; then
        log_error "Not authenticated with gcloud"
        log_info "Run: gcloud auth login"
        exit 1
    fi
    
    log_success "gcloud authentication verified"
}

check_gcloud_beta() {
    log_info "Ensuring gcloud beta component is installed..."
    gcloud components install beta --quiet 2>/dev/null || true
    log_success "gcloud beta component ready"
}

set_gcloud_project() {
    log_info "Setting gcloud project to '${GKE_PROJECT_ID}'..."
    gcloud config set project "${GKE_PROJECT_ID}" --quiet
    log_success "Project set to ${GKE_PROJECT_ID}"
}

install_kubectl() {
    log_step "PREREQ: Checking kubectl..."
    
    if command_exists kubectl; then
        log_success "kubectl is already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"
        return 0
    fi
    
    log_info "Installing kubectl ${KUBECTL_VERSION}..."
    
    local os
    os=$(get_os)
    local arch
    arch=$(get_arch)
    
    local kubectl_url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${os}/${arch}/kubectl"
    
    curl -fsSL "${kubectl_url}" -o /tmp/kubectl
    run_with_sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
    
    log_success "kubectl installed: $(kubectl version --client)"
}

install_argocd_cli() {
    log_step "PREREQ: Checking argocd CLI..."
    
    if command_exists argocd; then
        log_success "argocd CLI is already installed"
        return 0
    fi
    
    log_info "Installing argocd CLI ${ARGOCD_CLI_VERSION}..."
    
    local os
    os=$(get_os)
    local arch
    arch=$(get_arch)
    
    local argocd_url="https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_CLI_VERSION}/argocd-${os}-${arch}"
    
    curl -fsSL "${argocd_url}" -o /tmp/argocd
    run_with_sudo install -o root -g root -m 0755 /tmp/argocd /usr/local/bin/argocd
    
    log_success "argocd CLI installed"
}

enable_gcp_apis() {
    log_step "PREREQ: Enabling required GCP APIs..."
    
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
        gcloud services enable "${api}" \
            --project="${GKE_PROJECT_ID}" \
            --quiet 2>/dev/null || true
    done
    
    log_success "Required APIs enabled"
}

check_prerequisites() {
    log_header "PREREQUISITES: Checking and installing required tools..."
    
    check_gcloud
    check_gcloud_auth
    check_gcloud_beta
    set_gcloud_project
    enable_gcp_apis
    install_kubectl
    install_argocd_cli
    
    log_success "PREREQUISITES: All checks passed"
}

# =============================================================================
# GKE CLUSTER MANAGEMENT
# =============================================================================

check_cluster_exists() {
    gcloud container clusters describe "${GKE_CLUSTER_NAME}" \
        --project="${GKE_PROJECT_ID}" \
        --zone="${GKE_ZONE}" &> /dev/null
}

get_cluster_status() {
    if check_cluster_exists; then
        gcloud container clusters describe "${GKE_CLUSTER_NAME}" \
            --project="${GKE_PROJECT_ID}" \
            --zone="${GKE_ZONE}" \
            --format='value(status)'
    else
        echo "NOT_FOUND"
    fi
}

create_gke_cluster() {
    log_step "CLUSTER: Creating GKE cluster '${GKE_CLUSTER_NAME}'..."
    log_info "Project: ${GKE_PROJECT_ID}"
    log_info "Zone: ${GKE_ZONE}"
    log_info "Machine Type: ${GKE_MACHINE_TYPE}"
    log_info "Nodes: ${GKE_NUM_NODES}"
    
    # Check if cluster already exists
    if check_cluster_exists; then
        local status
        status=$(get_cluster_status)
        log_warn "Cluster '${GKE_CLUSTER_NAME}' already exists with status: ${status}"
        read -r -p "Do you want to delete and recreate it? [y/N]: " response
        if [[ "${response}" =~ ^[Yy]$ ]]; then
            delete_gke_cluster
        else
            log_info "Using existing cluster"
            get_gke_credentials
            return 0
        fi
    fi
    
    log_info "Creating GKE cluster (this may take 10-15 minutes)..."
    log_info "Using spot instances for cost optimization"
    
    # Create GKE cluster with exact parameters provided
    gcloud beta container clusters create "${GKE_CLUSTER_NAME}" \
        --project "${GKE_PROJECT_ID}" \
        --zone "${GKE_ZONE}" \
        --tier "standard" \
        --no-enable-basic-auth \
        --release-channel "regular" \
        --machine-type "${GKE_MACHINE_TYPE}" \
        --image-type "COS_CONTAINERD" \
        --disk-type "pd-balanced" \
        --disk-size "${GKE_DISK_SIZE}" \
        --metadata "disable-legacy-endpoints=true" \
        --service-account "${GKE_SERVICE_ACCOUNT}" \
        --max-pods-per-node "32" \
        --spot \
        --num-nodes "${GKE_NUM_NODES}" \
        --logging=SYSTEM,WORKLOAD \
        --monitoring=SYSTEM,STORAGE,POD,DEPLOYMENT,STATEFULSET,DAEMONSET,HPA,CADVISOR,KUBELET \
        --enable-ip-alias \
        --network "projects/${GKE_PROJECT_ID}/global/networks/${GKE_NETWORK}" \
        --subnetwork "projects/${GKE_PROJECT_ID}/regions/${GKE_REGION}/subnetworks/${GKE_SUBNETWORK}" \
        --cluster-secondary-range-name "pods" \
        --services-secondary-range-name "svc" \
        --no-enable-intra-node-visibility \
        --cluster-dns=clouddns \
        --cluster-dns-scope=cluster \
        --default-max-pods-per-node "110" \
        --enable-ip-access \
        --security-posture=standard \
        --workload-vulnerability-scanning=disabled \
        --enable-master-authorized-networks \
        --master-authorized-networks "${GKE_MASTER_AUTHORIZED_NETWORKS}" \
        --no-enable-google-cloud-access \
        --addons "HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver" \
        --enable-autoupgrade \
        --enable-autorepair \
        --max-surge-upgrade 1 \
        --max-unavailable-upgrade 0 \
        --binauthz-evaluation-mode=DISABLED \
        --enable-managed-prometheus \
        --enable-shielded-nodes \
        --shielded-integrity-monitoring \
        --no-shielded-secure-boot \
        --node-locations "${GKE_ZONE}" \
        --quiet
    
    log_success "GKE cluster '${GKE_CLUSTER_NAME}' created"
    
    # Get credentials
    get_gke_credentials
}

delete_gke_cluster() {
    log_step "CLUSTER: Deleting GKE cluster '${GKE_CLUSTER_NAME}'..."
    
    if check_cluster_exists; then
        gcloud container clusters delete "${GKE_CLUSTER_NAME}" \
            --project="${GKE_PROJECT_ID}" \
            --zone="${GKE_ZONE}" \
            --quiet
        log_success "GKE cluster deleted"
    else
        log_warn "GKE cluster does not exist"
    fi
}

get_gke_credentials() {
    log_info "Getting GKE cluster credentials..."
    
    gcloud container clusters get-credentials "${GKE_CLUSTER_NAME}" \
        --project="${GKE_PROJECT_ID}" \
        --zone="${GKE_ZONE}"
    
    log_success "GKE credentials configured for kubectl"
}

verify_cluster() {
    log_step "VERIFY: Verifying cluster health..."
    
    # Wait for cluster to be running
    local max_attempts=30
    local attempt=0
    
    while [[ ${attempt} -lt ${max_attempts} ]]; do
        local status
        status=$(get_cluster_status)
        
        if [[ "${status}" == "RUNNING" ]]; then
            log_success "Cluster is RUNNING"
            break
        fi
        
        attempt=$((attempt + 1))
        log_info "Waiting for cluster... (attempt ${attempt}/${max_attempts}, status: ${status})"
        sleep 10
    done
    
    if [[ ${attempt} -eq ${max_attempts} ]]; then
        log_error "Cluster did not become ready within timeout"
        return 1
    fi
    
    # Test kubectl connectivity
    log_info "Testing kubectl connectivity..."
    kubectl cluster-info
    
    log_info "Cluster nodes:"
    kubectl get nodes -o wide
    
    log_success "VERIFY: Cluster is healthy and accessible"
}

# =============================================================================
# GITLAB DEPLOYMENT
# =============================================================================

deploy_gitlab() {
    log_step "GITLAB: Deploying GitLab CE..."
    
    # Check if GitLab is already deployed
    if kubectl get namespace "${GITLAB_NAMESPACE}" &>/dev/null; then
        if kubectl get deployment -n "${GITLAB_NAMESPACE}" gitlab-ce &>/dev/null; then
            log_warn "GitLab is already deployed"
            read -r -p "Do you want to redeploy? [y/N]: " response
            if [[ ! "${response}" =~ ^[Yy]$ ]]; then
                log_info "Skipping GitLab deployment"
                return 0
            fi
        fi
    fi
    
    # Create namespace
    kubectl create namespace "${GITLAB_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    
    # Apply GitLab manifests
    local gitlab_manifest="${SCRIPT_DIR}/manifests/gitlab/gitlab-deployment.yaml"
    
    if [[ ! -f "${gitlab_manifest}" ]]; then
        log_error "GitLab manifest not found: ${gitlab_manifest}"
        exit 1
    fi
    
    # Update password in manifest if different from default
    if [[ "${GITLAB_ROOT_PASSWORD}" != "GitLabAdmin123!" ]]; then
        sed -i "s/GitLabAdmin123!/${GITLAB_ROOT_PASSWORD}/g" "${gitlab_manifest}"
    fi
    
    kubectl apply -f "${gitlab_manifest}"
    
    log_info "Waiting for GitLab to be ready (this may take 5-10 minutes)..."
    log_info "GitLab requires significant resources for startup..."
    
    # Wait for GitLab pod to be ready
    wait_for_pod_ready "${GITLAB_NAMESPACE}" "app=gitlab" 900 || {
        log_error "GitLab failed to start"
        log_info "Check logs: kubectl logs -n ${GITLAB_NAMESPACE} -l app=gitlab"
        return 1
    }
    
    # Wait for GitLab to be fully operational
    log_info "Waiting for GitLab services to be ready..."
    sleep 30
    
    log_success "GITLAB: GitLab CE deployed successfully"
}

get_gitlab_info() {
    log_info "GitLab Access Information:"
    
    # Get LoadBalancer IP for GKE
    local gitlab_ip
    gitlab_ip=$(kubectl get svc gitlab -n "${GITLAB_NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    if [[ -n "${gitlab_ip}" ]]; then
        echo ""
        echo "  GitLab URL:     http://${gitlab_ip}"
        echo "  GitLab SSH:     ssh://git@${gitlab_ip}:22"
    else
        echo ""
        echo "  GitLab URL:     (waiting for LoadBalancer IP...)"
        echo "  Check with:     kubectl get svc gitlab -n ${GITLAB_NAMESPACE}"
    fi
    
    echo "  Root Username:  root"
    echo "  Root Password:  ${GITLAB_ROOT_PASSWORD}"
    echo ""
}

# =============================================================================
# GITOPS REPOSITORY SETUP
# =============================================================================

create_gitops_repository() {
    log_step "GITOPS: Creating gitops repository in GitLab..."
    
    # Wait for GitLab API to be ready
    log_info "Waiting for GitLab API to be ready..."
    local max_attempts=30
    local attempt=0
    
    while [[ ${attempt} -lt ${max_attempts} ]]; do
        local gitlab_pod
        gitlab_pod=$(kubectl get pods -n "${GITLAB_NAMESPACE}" -l app=gitlab -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        
        if [[ -n "${gitlab_pod}" ]]; then
            if kubectl exec -n "${GITLAB_NAMESPACE}" "${gitlab_pod}" -- \
                curl -sf http://localhost:80/-/health > /dev/null 2>&1; then
                break
            fi
        fi
        
        attempt=$((attempt + 1))
        log_info "Waiting for GitLab API... (${attempt}/${max_attempts})"
        sleep 10
    done
    
    if [[ ${attempt} -eq ${max_attempts} ]]; then
        log_error "GitLab API is not responding"
        return 1
    fi
    
    local gitlab_pod
    gitlab_pod=$(kubectl get pods -n "${GITLAB_NAMESPACE}" -l app=gitlab -o jsonpath='{.items[0].metadata.name}')
    
    # Create gitops project using GitLab Rails runner
    log_info "Creating 'gitops' project..."
    
    kubectl exec -n "${GITLAB_NAMESPACE}" "${gitlab_pod}" -- \
        gitlab-rails runner "
            project = Project.find_by(path: 'gitops')
            if project.nil?
                project = Projects::CreateService.new(
                    User.find_by(username: 'root'),
                    {
                        name: 'gitops',
                        path: 'gitops',
                        namespace_id: User.find_by(username: 'root').namespace_id,
                        visibility: 'private',
                        initialize_with_readme: false
                    }
                ).execute
                puts 'Project created'
            else
                puts 'Project already exists'
            end
        "
    
    # Create repository structure locally
    log_info "Initializing repository structure..."
    mkdir -p "${GITOPS_REPO_DIR}"/{inventory,manifests/{gitlab,argocd}}
    
    # Copy manifests to gitops repo
    cp "${SCRIPT_DIR}/manifests/gitlab/gitlab-deployment.yaml" \
        "${GITOPS_REPO_DIR}/manifests/gitlab/" 2>/dev/null || true
    cp "${SCRIPT_DIR}/manifests/argocd/argocd-core.yaml" \
        "${GITOPS_REPO_DIR}/manifests/argocd/" 2>/dev/null || true
    cp "${SCRIPT_DIR}/manifests/gitops-inventory/inventory/"*.yaml \
        "${GITOPS_REPO_DIR}/inventory/" 2>/dev/null || true
    
    # Create README
    cat > "${GITOPS_REPO_DIR}/README.md" << 'EOF'
# GitOps Repository

This repository contains Kubernetes manifests managed by ArgoCD.

## Structure

```
├── inventory/              # ArgoCD Application manifests
│   ├── apps.yaml          # App of Apps (root application)
│   ├── gitlab-application.yaml
│   └── argocd-application.yaml
├── manifests/             # Kubernetes resource manifests
│   ├── gitlab/           # GitLab deployment
│   └── argocd/           # ArgoCD configuration
└── README.md
```

## Usage

### Deploy a new application

1. Create a new directory in `manifests/<app-name>/`
2. Add your Kubernetes manifests
3. Create an ArgoCD Application in `inventory/<app-name>-application.yaml`
4. Commit and push

### Modify existing deployments

1. Edit the relevant manifest in `manifests/`
2. Commit and push
3. ArgoCD will automatically sync the changes
EOF
    
    # Create a Kubernetes Job to push to GitLab
    log_info "Pushing initial content to GitLab..."
    
    # Create ConfigMap with repository content
    kubectl create configmap gitops-content \
        --from-file="${GITOPS_REPO_DIR}" \
        --namespace="${GITLAB_NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
    
    # Create Job to initialize repository
    cat << PUSH_EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: gitops-init
  namespace: ${GITLAB_NAMESPACE}
spec:
  template:
    spec:
      containers:
      - name: git
        image: alpine/git:v2.36.3
        command:
        - /bin/sh
        - -c
        - |
          apk add --no-cache curl
          
          # Wait for GitLab API
          sleep 30
          
          # Clone empty repo
          git clone http://root:${GITLAB_ROOT_PASSWORD}@gitlab.${GITLAB_NAMESPACE}.svc.cluster.local/root/gitops.git /tmp/gitops
          cd /tmp/gitops
          
          # Create structure
          mkdir -p inventory manifests/gitlab manifests/argocd
          
          # Create README
          cat > README.md << 'READMEEOF'
# GitOps Repository

Managed by ArgoCD App of Apps pattern.
READMEEOF
          
          git config user.email "bootstrap@local"
          git config user.name "Bootstrap"
          git add .
          git commit -m "Initial commit - GitOps repository structure"
          git push origin master
          
          echo "Repository initialized successfully"
        env:
        - name: GITLAB_ROOT_PASSWORD
          value: "${GITLAB_ROOT_PASSWORD}"
        - name: GIT_TERMINAL_PROMPT
          value: "0"
      restartPolicy: OnFailure
PUSH_EOF
    
    # Wait for job to complete
    log_info "Waiting for repository initialization..."
    kubectl wait --for=condition=complete job/gitops-init -n "${GITLAB_NAMESPACE}" --timeout=300s 2>/dev/null || {
        log_warn "Job may still be running. Check with: kubectl logs -n ${GITLAB_NAMESPACE} job/gitops-init"
    }
    
    # Clean up job
    kubectl delete job gitops-init -n "${GITLAB_NAMESPACE}" 2>/dev/null || true
    
    log_success "GITOPS: Repository initialized"
}

# =============================================================================
# ARGOCd DEPLOYMENT
# =============================================================================

deploy_argocd() {
    log_step "ARGOCD: Deploying ArgoCD..."
    
    # Check if ArgoCD is already installed
    if kubectl get namespace "${ARGOCD_NAMESPACE}" &>/dev/null; then
        if kubectl get deployment -n "${ARGOCD_NAMESPACE}" argocd-server &>/dev/null; then
            log_warn "ArgoCD is already deployed"
            read -r -p "Do you want to redeploy? [y/N]: " response
            if [[ ! "${response}" =~ ^[Yy]$ ]]; then
                log_info "Skipping ArgoCD deployment"
                return 0
            fi
        fi
    fi
    
    # Create namespace
    kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    
    # Install ArgoCD
    log_info "Installing ArgoCD (this may take a few minutes)..."
    
    kubectl apply -n "${ARGOCD_NAMESPACE}" \
        --server-side --force-conflicts \
        -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
    
    # Wait for ArgoCD to be ready
    log_info "Waiting for ArgoCD components..."
    
    kubectl wait --for=condition=Available \
        deployment/argocd-server \
        deployment/argocd-repo-server \
        deployment/argocd-application-controller \
        -n "${ARGOCD_NAMESPACE}" \
        --timeout=600s
    
    # Apply additional configuration
    local argocd_manifest="${SCRIPT_DIR}/manifests/argocd/argocd-core.yaml"
    if [[ -f "${argocd_manifest}" ]]; then
        kubectl apply -f "${argocd_manifest}"
    fi
    
    log_success "ARGOCD: ArgoCD deployed successfully"
}

get_argocd_info() {
    log_info "ArgoCD Access Information:"
    
    # Get initial admin password
    local argocd_password
    argocd_password=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "N/A")
    
    # Get LoadBalancer IP for GKE
    local argocd_ip
    argocd_ip=$(kubectl get svc argocd-server -n "${ARGOCD_NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    if [[ -n "${argocd_ip}" ]]; then
        echo ""
        echo "  ArgoCD URL:     https://${argocd_ip}"
    else
        echo ""
        echo "  ArgoCD URL:     (waiting for LoadBalancer IP...)"
        echo "  Check with:     kubectl get svc argocd-server -n ${ARGOCD_NAMESPACE}"
    fi
    
    echo "  Username:       admin"
    echo "  Password:       ${argocd_password}"
    echo ""
}

# =============================================================================
# APP OF APPS DEPLOYMENT
# =============================================================================

deploy_app_of_apps() {
    log_step "APPOFAPPS: Deploying App of Apps..."
    
    # Wait for ArgoCD to be ready
    log_info "Ensuring ArgoCD is ready..."
    kubectl wait --for=condition=Available \
        deployment/argocd-server \
        -n "${ARGOCD_NAMESPACE}" \
        --timeout=300s
    
    # Apply App of Apps manifest
    local appofapps_manifest="${SCRIPT_DIR}/manifests/gitops-inventory/app-of-apps.yaml"
    
    if [[ ! -f "${appofapps_manifest}" ]]; then
        log_error "App of Apps manifest not found: ${appofapps_manifest}"
        exit 1
    fi
    
    kubectl apply -f "${appofapps_manifest}"
    
    # Wait for application to be created
    log_info "Waiting for App of Apps to be created..."
    sleep 10
    
    log_success "APPOFAPPS: App of Apps deployed"
    
    # Show application status
    log_info "ArgoCD Applications:"
    kubectl get applications -n "${ARGOCD_NAMESPACE}" 2>/dev/null || true
}

# =============================================================================
# CLEANUP
# =============================================================================

clean_all() {
    log_step "CLEAN: Removing all resources..."
    
    # Delete GKE cluster
    delete_gke_cluster
    
    # Clean local files
    rm -rf "${GITOPS_REPO_DIR}"
    
    log_success "CLEAN: All resources removed"
}

# =============================================================================
# STATUS
# =============================================================================

show_status() {
    echo ""
    echo "=============================================="
    echo "  GKE CLUSTER STATUS"
    echo "=============================================="
    echo ""
    
    log_info "Project: ${GKE_PROJECT_ID}"
    log_info "Cluster: ${GKE_CLUSTER_NAME}"
    log_info "Zone: ${GKE_ZONE}"
    echo ""
    
    # Cluster status
    local cluster_status
    cluster_status=$(get_cluster_status 2>/dev/null || echo "UNKNOWN")
    
    echo "Cluster Status: ${cluster_status}"
    echo ""
    
    if [[ "${cluster_status}" == "RUNNING" ]]; then
        # Kubernetes cluster info
        log_info "Kubernetes Cluster Info:"
        kubectl cluster-info 2>/dev/null || true
        echo ""
        
        log_info "Nodes:"
        kubectl get nodes -o wide 2>/dev/null || true
        echo ""
        
        log_info "Namespaces:"
        kubectl get namespaces 2>/dev/null || true
        echo ""
        
        # GitLab status
        if kubectl get namespace "${GITLAB_NAMESPACE}" &>/dev/null; then
            log_info "GitLab Pods:"
            kubectl get pods -n "${GITLAB_NAMESPACE}" -o wide 2>/dev/null || true
            echo ""
            get_gitlab_info
        fi
        
        # ArgoCD status
        if kubectl get namespace "${ARGOCD_NAMESPACE}" &>/dev/null; then
            log_info "ArgoCD Pods:"
            kubectl get pods -n "${ARGOCD_NAMESPACE}" -o wide 2>/dev/null || true
            echo ""
            log_info "ArgoCD Applications:"
            kubectl get applications -n "${ARGOCD_NAMESPACE}" 2>/dev/null || true
            echo ""
            get_argocd_info
        fi
    fi
    
    print_summary_box "GKE CONFIGURATION" \
        "Project ID:          ${GKE_PROJECT_ID}" \
        "Cluster Name:        ${GKE_CLUSTER_NAME}" \
        "Zone:                ${GKE_ZONE}" \
        "Machine Type:        ${GKE_MACHINE_TYPE}" \
        "Node Count:          ${GKE_NUM_NODES} (Spot instances)" \
        "Service Account:     ${GKE_SERVICE_ACCOUNT}" \
        "Network:             ${GKE_NETWORK}" \
        "Subnetwork:          ${GKE_SUBNETWORK}" \
        "Master Auth IPs:     ${GKE_MASTER_AUTHORIZED_NETWORKS}"
}

# =============================================================================
# MAIN
# =============================================================================

print_usage() {
    echo ""
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  all         Complete bootstrap (prereq + cluster + gitlab + argocd + gitops)"
    echo "  prereq      Install prerequisites (gcloud, kubectl, argocd CLI)"
    echo "  cluster     Create GKE cluster"
    echo "  gitlab      Deploy GitLab CE"
    echo "  argocd      Deploy ArgoCD"
    echo "  gitops      Initialize gitops repository"
    echo "  appofapps   Deploy App of Apps"
    echo "  clean       Remove all resources (delete GKE cluster)"
    echo "  status      Show cluster status"
    echo "  help        Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  GITLAB_ROOT_PASSWORD   GitLab root password (default: GitLabAdmin123!)"
    echo "  ARGOCD_NAMESPACE       ArgoCD namespace (default: argocd)"
    echo "  ARGOCD_VERSION         ArgoCD version (default: stable)"
    echo ""
    echo "Examples:"
    echo "  $0 all                  # Complete bootstrap"
    echo "  $0 cluster              # Create GKE cluster only"
    echo "  $0 status               # Show cluster status"
    echo ""
}

main() {
    log_header "KUBERNETES BOOTSTRAP: Starting GKE deployment"
    log_info "Project: ${GKE_PROJECT_ID}"
    log_info "Cluster: ${GKE_CLUSTER_NAME}"
    log_info "Zone: ${GKE_ZONE}"
    
    case "${1:-all}" in
        prereq)
            check_prerequisites
            ;;
        cluster)
            check_gcloud
            check_gcloud_auth
            set_gcloud_project
            create_gke_cluster
            verify_cluster
            ;;
        gitlab)
            deploy_gitlab
            ;;
        argocd)
            deploy_argocd
            ;;
        gitops)
            create_gitops_repository
            ;;
        appofapps)
            deploy_app_of_apps
            ;;
        clean)
            clean_all
            ;;
        status)
            show_status
            ;;
        all)
            # Prerequisites
            check_prerequisites
            
            # GKE Cluster
            create_gke_cluster
            verify_cluster
            
            # GitLab
            deploy_gitlab
            
            # GitOps Repository
            create_gitops_repository
            
            # ArgoCD
            deploy_argocd
            
            # App of Apps
            deploy_app_of_apps
            
            # Show status
            show_status
            ;;
        help|--help|-h)
            print_usage
            ;;
        *)
            log_error "Unknown command: ${1}"
            print_usage
            exit 1
            ;;
    esac
    
    log_success "KUBERNETES BOOTSTRAP: Operation completed successfully"
}

main "$@"
