#!/usr/bin/env bash
# =============================================================================
# Common Functions Library
# Shared utilities for Kubernetes bootstrap scripts
# =============================================================================

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m'

# Logging functions
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

# Check if command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Check if running as root
is_root() {
    [[ $EUID -eq 0 ]]
}

# Wait for condition with timeout
wait_for() {
    local condition="$1"
    local timeout="${2:-300}"
    local message="${3:-Waiting...}"
    local interval="${4:-5}"
    
    local elapsed=0
    log_info "${message}"
    
    while [[ ${elapsed} -lt ${timeout} ]]; do
        if eval "${condition}"; then
            return 0
        fi
        sleep ${interval}
        elapsed=$((elapsed + interval))
        printf "."
    done
    printf "\n"
    return 1
}

# Wait for pod to be ready
wait_for_pod() {
    local namespace="$1"
    local label_selector="$2"
    local timeout="${3:-300}"
    
    log_info "Waiting for pod with label '${label_selector}' in namespace '${namespace}'..."
    
    if kubectl wait --for=condition=Ready pod \
        -l "${label_selector}" \
        -n "${namespace}" \
        --timeout="${timeout}s" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Wait for deployment to be available
wait_for_deployment() {
    local namespace="$1"
    local deployment="$2"
    local timeout="${3:-300}"
    
    log_info "Waiting for deployment '${deployment}' in namespace '${namespace}'..."
    
    if kubectl rollout status deployment/"${deployment}" \
        -n "${namespace}" \
        --timeout="${timeout}s" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Get random password
generate_password() {
    local length="${1:-16}"
    tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c "${length}"
}

# Base64 encode (URL safe)
base64_encode() {
    echo -n "$1" | base64 | tr -d '\n'
}

# Base64 decode
base64_decode() {
    echo "$1" | base64 -d
}

# Check if port is in use
port_in_use() {
    local port="$1"
    if command_exists ss; then
        ss -tuln | grep -q ":${port} "
    elif command_exists netstat; then
        netstat -tuln | grep -q ":${port} "
    else
        return 1
    fi
}

# Get available port
get_available_port() {
    local start_port="${1:-30000}"
    local end_port="${2:-32767}"
    
    for port in $(seq ${start_port} ${end_port}); do
        if ! port_in_use ${port}; then
            echo ${port}
            return 0
        fi
    done
    return 1
}

# Check minimum system requirements
check_memory() {
    local required_mb="$1"
    local available_kb
    available_kb=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}')
    
    if [[ -z "${available_kb}" ]]; then
        # Fallback to free memory
        available_kb=$(grep MemFree /proc/meminfo | awk '{print $2}')
    fi
    
    local available_mb=$((available_kb / 1024))
    
    if [[ ${available_mb} -lt ${required_mb} ]]; then
        log_warn "Low memory: ${available_mb}MB available, ${required_mb}MB recommended"
        return 1
    fi
    
    log_info "Memory check passed: ${available_mb}MB available"
    return 0
}

# Retry command with exponential backoff
retry() {
    local max_attempts="${1:-3}"
    local delay="${2:-5}"
    local cmd="${3}"
    shift 3
    
    local attempt=1
    while [[ ${attempt} -le ${max_attempts} ]]; do
        if eval "${cmd} \"$@\""; then
            return 0
        fi
        
        if [[ ${attempt} -lt ${max_attempts} ]]; then
            local wait_time=$((delay * (2 ** (attempt - 1))))
            log_warn "Attempt ${attempt} failed, retrying in ${wait_time}s..."
            sleep ${wait_time}
        fi
        attempt=$((attempt + 1))
    done
    
    return 1
}

# Download file with progress
download_file() {
    local url="$1"
    local output="$2"
    
    if command_exists curl; then
        curl -fsSL -o "${output}" "${url}"
    elif command_exists wget; then
        wget -q -O "${output}" "${url}"
    else
        log_error "Neither curl nor wget is available"
        return 1
    fi
}

# Print section header
print_header() {
    local title="$1"
    echo ""
    echo "=============================================="
    echo "  ${title}"
    echo "=============================================="
    echo ""
}

# Print summary box
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
