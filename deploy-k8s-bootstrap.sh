#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# KUBERNETES CLUSTER BOOTSTRAP SCRIPT
# Complete GitOps Environment: Kind/GKE + GitLab + ArgoCD
# =============================================================================
#
# This script creates a complete Kubernetes environment with:
# - Kind cluster (default) or GKE cluster (optional)
# - GitLab CE (single pod deployment)
# - ArgoCD (GitOps continuous delivery)
# - App of Apps pattern for GitOps
#
# Usage:
#   ./deploy-k8s-bootstrap.sh [COMMAND] [OPTIONS]
#
# Commands:
#   all         Complete bootstrap (default)
#   prereq      Install prerequisites (docker, kind, kubectl, etc.)
#   cluster     Create Kubernetes cluster
#   gitlab      Deploy GitLab
#   argocd      Deploy ArgoCD
#   gitops      Initialize gitops repository
#   gke         Deploy to GKE (alternative to kind)
#   clean       Remove all resources
#   status      Show cluster status
#
# =============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="${SCRIPT_DIR}"

# =============================================================================
# CONFIGURATION
# =============================================================================

# Cluster type: "kind" or "gke"
readonly CLUSTER_TYPE="${CLUSTER_TYPE:-kind}"

# Kind configuration
readonly KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-gitops-cluster}"
readonly KIND_CONFIG_FILE="${SCRIPT_DIR}/manifests/kind-config.yaml"

# GKE configuration
readonly GKE_PROJECT_ID="${GKE_PROJECT_ID:-formazione-gerardo-cipriano}"
readonly GKE_CLUSTER_NAME="${GKE_CLUSTER_NAME:-poc-redis-1}"
readonly GKE_ZONE="${GKE_ZONE:-us-central1-c}"
readonly GKE_REGION="${GKE_REGION:-us-central1}"
readonly GKE_NETWORK="${GKE_NETWORK:-injenia-test}"
readonly GKE_SUBNETWORK="${GKE_SUBNETWORK:-injenia-gke-usc1}"
readonly GKE_SERVICE_ACCOUNT="${GKE_SERVICE_ACCOUNT:-gke-sa@${GKE_PROJECT_ID}.iam.gserviceaccount.com}"
readonly GKE_MACHINE_TYPE="${GKE_MACHINE_TYPE:-n2-standard-4}"
readonly GKE_NUM_NODES="${GKE_NUM_NODES:-2}"
readonly GKE_MASTER_AUTHORIZED_NETWORKS="${GKE_MASTER_AUTHORIZED_NETWORKS:-87.18.50.199/32,77.89.24.226/32}"

# GitLab configuration
readonly GITLAB_NAMESPACE="${GITLAB_NAMESPACE:-gitlab}"
readonly GITLAB_IMAGE="${GITLAB_IMAGE:-gitlab/gitlab-ce:18.6.0-ce.0}"
readonly GITLAB_ROOT_PASSWORD="${GITLAB_ROOT_PASSWORD:-GitLabAdmin123!}"
readonly GITLAB_NODEPORT_HTTP="${GITLAB_NODEPORT_HTTP:-30080}"
readonly GITLAB_NODEPORT_SSH="${GITLAB_NODEPORT_SSH:-30222}"

# ArgoCD configuration
readonly ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
readonly ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"
readonly ARGOCD_NODEPORT="${ARGOCD_NODEPORT:-30081}"

# GitOps repository configuration
readonly GITOPS_REPO_NAME="${GITOPS_REPO_NAME:-gitops}"
readonly GITOPS_REPO_DIR="${SCRIPT_DIR}/gitops-repo"

# Tool versions
readonly KIND_VERSION="${KIND_VERSION:-v0.26.0}"
readonly KUBECTL_VERSION="${KUBECTL_VERSION:-v1.32.0}"
readonly ARGOCD_CLI_VERSION="${ARGOCD_CLI_VERSION:-v2.13.0}"

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

wait_for_service() {
    local namespace="$1"
    local service="$2"
    local timeout="${3:-300}"
    
    log_info "Waiting for service '${service}' in namespace '${namespace}'..."
    
    kubectl wait --for=condition=Ready \
        -n "${namespace}" \
        "service/${service}" \
        --timeout="${timeout}s" 2>/dev/null || true
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

# =============================================================================
# PREREQUISITES INSTALLATION
# =============================================================================

install_docker() {
    log_step "INSTALL: Checking Docker..."
    
    if command_exists docker; then
        log_success "Docker is already installed: $(docker --version)"
        return 0
    fi
    
    log_info "Installing Docker..."
    
    # Detect OS
    if [[ -f /etc/debian_version ]] || [[ -f /etc/lsb-release ]]; then
        # Debian/Ubuntu
        run_with_sudo apt-get update
        run_with_sudo apt-get install -y \
            apt-transport-https \
            ca-certificates \
            curl \
            gnupg \
            lsb-release
        
        # Add Docker's official GPG key
        curl -fsSL https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]')/gpg | \
            run_with_sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        
        # Add Docker repository
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
            https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]') \
            $(lsb_release -cs) stable" | \
            run_with_sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        run_with_sudo apt-get update
        run_with_sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
    elif [[ -f /etc/redhat-release ]]; then
        # RHEL/CentOS/Fedora
        run_with_sudo yum install -y yum-utils
        run_with_sudo yum-config-manager --add-repo \
            https://download.docker.com/linux/centos/docker-ce.repo
        run_with_sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        run_with_sudo systemctl enable --now docker
        
    else
        log_error "Unsupported OS for automatic Docker installation"
        log_info "Please install Docker manually: https://docs.docker.com/engine/install/"
        exit 1
    fi
    
    # Add current user to docker group
    if ! groups | grep -q docker; then
        run_with_sudo usermod -aG docker "$USER"
        log_warn "Added user to docker group. You may need to log out and back in."
    fi
    
    # Start Docker service
    run_with_sudo systemctl enable --now docker 2>/dev/null || true
    
    log_success "Docker installed: $(docker --version)"
}

install_kubectl() {
    log_step "INSTALL: Checking kubectl..."
    
    if command_exists kubectl; then
        log_success "kubectl is already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
        return 0
    fi
    
    log_info "Installing kubectl ${KUBECTL_VERSION}..."
    
    local os
    os=$(get_os)
    local arch
    arch=$(get_arch)
    
    local kubectl_url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${os}/${arch}/kubectl"
    
    curl -fsSL "${kubectl_url}" -o /tmp/kubectl
    curl -fsSL "${kubectl_url}.sha256" -o /tmp/kubectl.sha256
    
    # Verify checksum
    if command_exists sha256sum; then
        pushd /tmp > /dev/null
        sha256sum -c kubectl.sha256 || log_warn "Checksum verification failed"
        popd > /dev/null
    fi
    
    run_with_sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
    
    log_success "kubectl installed: $(kubectl version --client)"
}

install_kind() {
    log_step "INSTALL: Checking kind..."
    
    if command_exists kind; then
        log_success "kind is already installed: $(kind version)"
        return 0
    fi
    
    log_info "Installing kind ${KIND_VERSION}..."
    
    local os
    os=$(get_os)
    local arch
    arch=$(get_arch)
    
    local kind_url="https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${os}-${arch}"
    
    curl -fsSL "${kind_url}" -o /tmp/kind
    run_with_sudo install -o root -g root -m 0755 /tmp/kind /usr/local/bin/kind
    
    log_success "kind installed: $(kind version)"
}

install_cloud_provider_kind() {
    log_step "INSTALL: Checking cloud-provider-kind..."
    
    if command_exists cloud-provider-kind; then
        log_success "cloud-provider-kind is already installed"
        return 0
    fi
    
    log_info "Installing cloud-provider-kind..."
    
    local os
    os=$(get_os)
    local arch
    arch=$(get_arch)
    
    # cloud-provider-kind releases
    local cpk_version="v0.3.0"
    local cpk_url="https://github.com/kubernetes-sigs/cloud-provider-kind/releases/download/${cpk_version}/cloud-provider-kind_${os}_${arch}"
    
    curl -fsSL "${cpk_url}" -o /tmp/cloud-provider-kind
    run_with_sudo install -o root -g root -m 0755 /tmp/cloud-provider-kind /usr/local/bin/cloud-provider-kind
    
    log_success "cloud-provider-kind installed"
}

install_argocd_cli() {
    log_step "INSTALL: Checking argocd CLI..."
    
    if command_exists argocd; then
        log_success "argocd CLI is already installed: $(argocd version --client --short 2>/dev/null || true)"
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

install_prerequisites() {
    log_header "PREREQUISITES: Installing required tools..."
    
    install_docker
    install_kubectl
    install_kind
    install_cloud_provider_kind
    install_argocd_cli
    
    log_success "PREREQUISITES: All tools installed"
}

# =============================================================================
# KIND CLUSTER MANAGEMENT
# =============================================================================

create_kind_config() {
    log_info "Creating kind cluster configuration..."
    
    cat > "${KIND_CONFIG_FILE}" << 'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      # GitLab HTTP
      - containerPort: 30080
        hostPort: 80
        protocol: TCP
      # GitLab SSH
      - containerPort: 30222
        hostPort: 2222
        protocol: TCP
      # ArgoCD UI
      - containerPort: 30081
        hostPort: 8080
        protocol: TCP
  - role: worker
    extraMounts:
      - hostPath: /tmp/kind-storage
        containerPath: /data
  - role: worker
    extraMounts:
      - hostPath: /tmp/kind-storage
        containerPath: /data
EOF
    
    log_debug "Kind config created at ${KIND_CONFIG_FILE}"
}

create_kind_cluster() {
    log_step "CLUSTER: Creating kind cluster '${KIND_CLUSTER_NAME}'..."
    
    # Check if cluster already exists
    if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
        log_warn "Cluster '${KIND_CLUSTER_NAME}' already exists"
        read -r -p "Do you want to delete and recreate it? [y/N]: " response
        if [[ "${response}" =~ ^[Yy]$ ]]; then
            delete_kind_cluster
        else
            log_info "Using existing cluster"
            kind export kubeconfig --name "${KIND_CLUSTER_NAME}"
            return 0
        fi
    fi
    
    # Create config file
    mkdir -p "${SCRIPT_DIR}/manifests"
    create_kind_config
    
    # Create storage directory
    mkdir -p /tmp/kind-storage
    
    # Create cluster
    log_info "Creating cluster (this may take a few minutes)..."
    kind create cluster \
        --name "${KIND_CLUSTER_NAME}" \
        --config "${KIND_CONFIG_FILE}" \
        --image "kindest/node:v1.32.0"
    
    # Export kubeconfig
    kind export kubeconfig --name "${KIND_CLUSTER_NAME}"
    
    # Wait for cluster to be ready
    log_info "Waiting for cluster to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
    
    log_success "CLUSTER: Kind cluster created"
}

delete_kind_cluster() {
    log_step "CLUSTER: Deleting kind cluster '${KIND_CLUSTER_NAME}'..."
    
    if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
        kind delete cluster --name "${KIND_CLUSTER_NAME}"
        log_success "Cluster deleted"
    else
        log_warn "Cluster '${KIND_CLUSTER_NAME}' does not exist"
    fi
}

start_cloud_provider_kind() {
    log_step "CLUSTER: Starting cloud-provider-kind..."
    
    # Check if already running
    if pgrep -f "cloud-provider-kind" > /dev/null; then
        log_info "cloud-provider-kind is already running"
        return 0
    fi
    
    # Start in background
    nohup cloud-provider-kind > /tmp/cloud-provider-kind.log 2>&1 &
    
    sleep 2
    
    if pgrep -f "cloud-provider-kind" > /dev/null; then
        log_success "cloud-provider-kind started (PID: $(pgrep -f 'cloud-provider-kind'))"
    else
        log_error "Failed to start cloud-provider-kind"
        return 1
    fi
}

# =============================================================================
# GKE CLUSTER MANAGEMENT
# =============================================================================

check_gcloud_prerequisites() {
    log_info "Checking gcloud prerequisites..."
    
    if ! command_exists gcloud; then
        log_error "gcloud CLI not found. Please install Google Cloud SDK"
        log_info "Visit: https://cloud.google.com/sdk/docs/install"
        exit 1
    fi
    
    if ! gcloud auth print-access-token &> /dev/null; then
        log_error "Not authenticated with gcloud. Run: gcloud auth login"
        exit 1
    fi
    
    gcloud config set project "${GKE_PROJECT_ID}" --quiet
    
    # Ensure beta component
    gcloud components install beta --quiet 2>/dev/null || true
    
    log_success "gcloud prerequisites verified"
}

create_gke_cluster() {
    log_step "GKE: Creating GKE cluster '${GKE_CLUSTER_NAME}'..."
    
    check_gcloud_prerequisites
    
    # Check if cluster exists
    if gcloud container clusters describe "${GKE_CLUSTER_NAME}" \
        --project="${GKE_PROJECT_ID}" \
        --zone="${GKE_ZONE}" &> /dev/null; then
        log_warn "Cluster '${GKE_CLUSTER_NAME}' already exists"
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
    
    gcloud beta container clusters create "${GKE_CLUSTER_NAME}" \
        --project="${GKE_PROJECT_ID}" \
        --zone="${GKE_ZONE}" \
        --tier="standard" \
        --no-enable-basic-auth \
        --release-channel="regular" \
        --machine-type="${GKE_MACHINE_TYPE}" \
        --image-type="COS_CONTAINERD" \
        --disk-type="pd-balanced" \
        --disk-size="50" \
        --metadata="disable-legacy-endpoints=true" \
        --service-account="${GKE_SERVICE_ACCOUNT}" \
        --max-pods-per-node="32" \
        --spot \
        --num-nodes="${GKE_NUM_NODES}" \
        --logging=SYSTEM,WORKLOAD \
        --monitoring=SYSTEM,STORAGE,POD,DEPLOYMENT,STATEFULSET,DAEMONSET,HPA,CADVISOR,KUBELET \
        --enable-ip-alias \
        --network="projects/${GKE_PROJECT_ID}/global/networks/${GKE_NETWORK}" \
        --subnetwork="projects/${GKE_PROJECT_ID}/regions/${GKE_REGION}/subnetworks/${GKE_SUBNETWORK}" \
        --cluster-secondary-range-name="pods" \
        --services-secondary-range-name="svc" \
        --no-enable-intra-node-visibility \
        --cluster-dns=clouddns \
        --cluster-dns-scope=cluster \
        --default-max-pods-per-node="110" \
        --enable-ip-access \
        --security-posture=standard \
        --workload-vulnerability-scanning=disabled \
        --enable-master-authorized-networks \
        --master-authorized-networks="${GKE_MASTER_AUTHORIZED_NETWORKS}" \
        --no-enable-google-cloud-access \
        --addons="HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver" \
        --enable-autoupgrade \
        --enable-autorepair \
        --max-surge-upgrade=1 \
        --max-unavailable-upgrade=0 \
        --binauthz-evaluation-mode=DISABLED \
        --enable-managed-prometheus \
        --enable-shielded-nodes \
        --shielded-integrity-monitoring \
        --no-shielded-secure-boot \
        --node-locations="${GKE_ZONE}" \
        --quiet
    
    get_gke_credentials
    
    log_success "GKE cluster created"
}

delete_gke_cluster() {
    log_step "GKE: Deleting GKE cluster '${GKE_CLUSTER_NAME}'..."
    
    check_gcloud_prerequisites
    
    if gcloud container clusters describe "${GKE_CLUSTER_NAME}" \
        --project="${GKE_PROJECT_ID}" \
        --zone="${GKE_ZONE}" &> /dev/null; then
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
    
    log_success "GKE credentials configured"
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
    
    # Check GitLab health
    local gitlab_pod
    gitlab_pod=$(kubectl get pods -n "${GITLAB_NAMESPACE}" -l app=gitlab -o jsonpath='{.items[0].metadata.name}')
    
    log_info "Checking GitLab status..."
    kubectl exec -n "${GITLAB_NAMESPACE}" "${gitlab_pod}" -- \
        gitlab-ctl status || true
    
    log_success "GITLAB: GitLab CE deployed successfully"
}

get_gitlab_info() {
    log_info "GitLab Access Information:"
    
    local gitlab_url=""
    local gitlab_ip=""
    
    if [[ "${CLUSTER_TYPE}" == "kind" ]]; then
        gitlab_url="http://localhost"
        gitlab_ip="localhost"
    else
        # GKE - get LoadBalancer IP
        gitlab_ip=$(kubectl get svc gitlab -n "${GITLAB_NAMESPACE}" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        
        if [[ -n "${gitlab_ip}" ]]; then
            gitlab_url="http://${gitlab_ip}"
        else
            gitlab_url="http://localhost:${GITLAB_NODEPORT_HTTP}"
        fi
    fi
    
    echo ""
    echo "  GitLab URL:     ${gitlab_url}"
    echo "  Root Username:  root"
    echo "  Root Password:  ${GITLAB_ROOT_PASSWORD}"
    echo "  SSH Port:       ${GITLAB_NODEPORT_SSH}"
    echo ""
}

# =============================================================================
# GITOPS REPOSITORY SETUP
# =============================================================================

create_gitlab_token() {
    log_info "Creating GitLab personal access token..."
    
    local gitlab_pod
    gitlab_pod=$(kubectl get pods -n "${GITLAB_NAMESPACE}" -l app=gitlab -o jsonpath='{.items[0].metadata.name}')
    
    # Create token using GitLab Rails console
    # This is a workaround since the API requires authentication
    local token
    token=$(kubectl exec -n "${GITLAB_NAMESPACE}" "${gitlab_pod}" -- \
        gitlab-rails runner "
            user = User.find_by(username: 'root')
            token = user.personal_access_tokens.create(
                name: 'bootstrap-token',
                scopes: [:api, :read_repository, :write_repository],
                expires_at: 365.days.from_now
            )
            token.set_token('glpat-bootstrap-token-12345')
            token.save!
            puts token.token
        " 2>/dev/null || echo "glpat-bootstrap-token-12345")
    
    echo "${token}"
}

create_gitops_repository() {
    log_step "GITOPS: Creating gitops repository in GitLab..."
    
    # Wait for GitLab API to be ready
    log_info "Waiting for GitLab API to be ready..."
    local max_attempts=30
    local attempt=0
    
    while [[ ${attempt} -lt ${max_attempts} ]]; do
        if kubectl exec -n "${GITLAB_NAMESPACE}" \
            $(kubectl get pods -n "${GITLAB_NAMESPACE}" -l app=gitlab -o jsonpath='{.items[0].metadata.name}') \
            -- curl -sf http://localhost:80/-/health > /dev/null 2>&1; then
            break
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
    
    # Create gitops project using GitLab API
    log_info "Creating 'gitops' project..."
    
    # Use GitLab Rails runner to create the project
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
    
    # Create repository structure
    log_info "Initializing repository structure..."
    mkdir -p "${GITOPS_REPO_DIR}"/{inventory,manifests/{gitlab,argocd}}
    
    # Copy manifests to gitops repo
    cp "${SCRIPT_DIR}/manifests/gitlab/gitlab-deployment.yaml" \
        "${GITOPS_REPO_DIR}/manifests/gitlab/"
    cp "${SCRIPT_DIR}/manifests/argocd/argocd-core.yaml" \
        "${GITOPS_REPO_DIR}/manifests/argocd/"
    cp "${SCRIPT_DIR}/manifests/gitops-inventory/inventory/"*.yaml \
        "${GITOPS_REPO_DIR}/inventory/"
    
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
    
    # Initialize git and push to GitLab
    log_info "Pushing to GitLab..."
    
    cd "${GITOPS_REPO_DIR}"
    git init
    git config user.email "bootstrap@local"
    git config user.name "Bootstrap"
    git add .
    git commit -m "Initial commit - GitOps repository"
    
    # Configure remote and push
    # Use GitLab service URL from inside the cluster
    git remote remove origin 2>/dev/null || true
    
    local gitlab_git_url
    if [[ "${CLUSTER_TYPE}" == "kind" ]]; then
        # For kind, use NodePort or port-forward
        gitlab_git_url="http://root:${GITLAB_ROOT_PASSWORD}@localhost:${GITLAB_NODEPORT_HTTP}/root/gitops.git"
    else
        gitlab_git_url="http://gitlab.${GITLAB_NAMESPACE}.svc.cluster.local/root/gitops.git"
    fi
    
    # Use kubectl exec to push from inside the cluster or use GitLab's internal API
    # Alternative: create a job to push the repo
    log_info "Creating git push job..."
    
    # Create a job that clones and pushes
    cat << 'PUSH_EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: gitops-init
  namespace: gitlab
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
          git clone http://root:${GITLAB_ROOT_PASSWORD}@gitlab.gitlab.svc.cluster.local/root/gitops.git /tmp/gitops
          cd /tmp/gitops
          
          # Create structure
          mkdir -p inventory manifests/gitlab manifests/argocd
          
          # Create README
          cat > README.md << 'EOF'
# GitOps Repository

Managed by ArgoCD App of Apps pattern.
EOF
          
          git config user.email "bootstrap@local"
          git config user.name "Bootstrap"
          git add .
          git commit -m "Initial commit"
          git push origin master
        env:
        - name: GITLAB_ROOT_PASSWORD
          value: "${GITLAB_ROOT_PASSWORD}"
      restartPolicy: OnFailure
PUSH_EOF
    
    # Wait for job to complete
    kubectl wait --for=condition=complete job/gitops-init -n gitlab --timeout=300s || true
    
    # Clean up job
    kubectl delete job gitops-init -n gitlab 2>/dev/null || true
    
    cd "${PROJECT_ROOT}"
    
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
    kubectl apply -f "${SCRIPT_DIR}/manifests/argocd/argocd-core.yaml"
    
    # Expose ArgoCD UI via NodePort
    kubectl patch svc argocd-server -n "${ARGOCD_NAMESPACE}" \
        -p "{\"spec\": {\"type\": \"NodePort\", \"ports\": [{\"port\": 80, \"targetPort\": 8080, \"nodePort\": ${ARGOCD_NODEPORT}}]}}"
    
    log_success "ARGOCD: ArgoCD deployed successfully"
}

get_argocd_info() {
    log_info "ArgoCD Access Information:"
    
    # Get initial admin password
    local argocd_password
    argocd_password=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" | base64 -d)
    
    local argocd_url=""
    
    if [[ "${CLUSTER_TYPE}" == "kind" ]]; then
        argocd_url="http://localhost:${ARGOCD_NODEPORT}"
    else
        local lb_ip
        lb_ip=$(kubectl get svc argocd-server -n "${ARGOCD_NAMESPACE}" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        
        if [[ -n "${lb_ip}" ]]; then
            argocd_url="https://${lb_ip}"
        else
            argocd_url="https://localhost:${ARGOCD_NODEPORT}"
        fi
    fi
    
    echo ""
    echo "  ArgoCD URL:     ${argocd_url}"
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
    
    # Apply App of Apps
    kubectl apply -f "${SCRIPT_DIR}/manifests/gitops-inventory/app-of-apps.yaml"
    
    # Wait for application to be synced
    log_info "Waiting for App of Apps to sync..."
    sleep 10
    
    log_success "APPOFAPPS: App of Apps deployed"
    
    # Sync the application
    log_info "Triggering initial sync..."
    argocd app sync apps --server localhost:${ARGOCD_NODEPORT} \
        --grpc-web --insecure \
        --auth-token "$(kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)" 2>/dev/null || \
        log_warn "Could not sync via CLI. Please sync manually in UI."
}

# =============================================================================
# CLEANUP
# =============================================================================

clean_all() {
    log_step "CLEAN: Removing all resources..."
    
    if [[ "${CLUSTER_TYPE}" == "kind" ]]; then
        delete_kind_cluster
    else
        delete_gke_cluster
    fi
    
    # Clean local files
    rm -rf "${GITOPS_REPO_DIR}"
    rm -rf /tmp/kind-storage
    
    log_success "CLEAN: All resources removed"
}

# =============================================================================
# STATUS
# =============================================================================

show_status() {
    print_header "CLUSTER STATUS"
    
    echo "Cluster Type: ${CLUSTER_TYPE}"
    echo ""
    
    # Kubernetes cluster info
    log_info "Kubernetes Cluster:"
    kubectl cluster-info
    echo ""
    
    log_info "Nodes:"
    kubectl get nodes -o wide
    echo ""
    
    log_info "Namespaces:"
    kubectl get namespaces
    echo ""
    
    # GitLab status
    if kubectl get namespace "${GITLAB_NAMESPACE}" &>/dev/null; then
        log_info "GitLab Pods:"
        kubectl get pods -n "${GITLAB_NAMESPACE}" -o wide
        echo ""
        get_gitlab_info
    fi
    
    # ArgoCD status
    if kubectl get namespace "${ARGOCD_NAMESPACE}" &>/dev/null; then
        log_info "ArgoCD Pods:"
        kubectl get pods -n "${ARGOCD_NAMESPACE}" -o wide
        echo ""
        log_info "ArgoCD Applications:"
        kubectl get applications -n "${ARGOCD_NAMESPACE}"
        echo ""
        get_argocd_info
    fi
    
    print_summary_box "QUICK ACCESS" \
        "GitLab:  http://localhost (user: root, pass: ${GITLAB_ROOT_PASSWORD})" \
        "ArgoCD:  http://localhost:${ARGOCD_NODEPORT}" \
        "SSH:     ssh -p ${GITLAB_NODEPORT_SSH} git@localhost"
}

# =============================================================================
# MAIN
# =============================================================================

print_usage() {
    echo ""
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  all         Complete bootstrap (prereq + cluster + gitlab + argocd + gitops)"
    echo "  prereq      Install prerequisites only (docker, kind, kubectl, etc.)"
    echo "  cluster     Create Kubernetes cluster (kind or gke)"
    echo "  gitlab      Deploy GitLab CE"
    echo "  argocd      Deploy ArgoCD"
    echo "  gitops      Initialize gitops repository"
    echo "  appofapps   Deploy App of Apps"
    echo "  gke         Deploy to GKE (alternative cluster type)"
    echo "  clean       Remove all resources"
    echo "  status      Show cluster status"
    echo "  help        Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  CLUSTER_TYPE         Cluster type: 'kind' (default) or 'gke'"
    echo "  KIND_CLUSTER_NAME    Kind cluster name (default: gitops-cluster)"
    echo "  GITLAB_ROOT_PASSWORD GitLab root password (default: GitLabAdmin123!)"
    echo "  GKE_PROJECT_ID       GCP Project ID for GKE deployment"
    echo "  GKE_CLUSTER_NAME     GKE cluster name"
    echo ""
    echo "Examples:"
    echo "  $0 all                      # Complete kind setup"
    echo "  $0 cluster gitlab argocd    # Individual steps"
    echo "  CLUSTER_TYPE=gke $0 all     # GKE deployment"
    echo ""
}

main() {
    log_header "KUBERNETES BOOTSTRAP: Starting deployment"
    log_info "Cluster type: ${CLUSTER_TYPE}"
    log_info "Project root: ${PROJECT_ROOT}"
    
    case "${1:-all}" in
        prereq)
            install_prerequisites
            ;;
        cluster)
            if [[ "${CLUSTER_TYPE}" == "gke" ]]; then
                create_gke_cluster
            else
                create_kind_cluster
                start_cloud_provider_kind
            fi
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
        gke)
            create_gke_cluster
            ;;
        clean)
            clean_all
            ;;
        status)
            show_status
            ;;
        all)
            # Prerequisites
            install_prerequisites
            
            # Cluster
            if [[ "${CLUSTER_TYPE}" == "gke" ]]; then
                create_gke_cluster
            else
                create_kind_cluster
                start_cloud_provider_kind
            fi
            
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
