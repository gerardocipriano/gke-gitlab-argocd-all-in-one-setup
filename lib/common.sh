#!/usr/bin/env bash
# Purpose: shared logging, utilities, and K8s helpers

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# =============================================================================
# LOGGING
# =============================================================================

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
# SHELL UTILITIES
# =============================================================================

command_exists() {
    command -v "$1" &> /dev/null
}

download_file() {
    local url="$1"
    local output="$2"
    if command_exists curl; then
        curl -fsSL -o "${output}" "${url}"
    elif command_exists wget; then
        wget -q -O "${output}" "${url}"
    else
        log_error "Neither curl nor wget available"
        return 1
    fi
}

# =============================================================================
# KUBERNETES HELPERS
# =============================================================================

wait_for_pod_ready() {
    local namespace="$1"
    local label="$2"
    local timeout="${3:-600}"

    log_info "Waiting for pod '${label}' in '${namespace}' (${timeout}s)..."
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

# Purpose: trova una porta TCP libera sull'host, partendo da quella preferita.
# Serve perché i port-forward della demo collidono spesso con servizi già in ascolto.
port_in_listen() {
    local port="$1"
    if command_exists ss; then
        ss -ltnH "sport = :${port}" 2>/dev/null | grep -q .
    else
        (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null
    fi
}

port_is_free() {
    ! port_in_listen "$1"
}

find_free_port() {
    local port="$1"
    local max_attempts="${2:-50}"
    local attempt=0
    while (( attempt < max_attempts )); do
        if port_is_free "${port}"; then
            echo "${port}"
            return 0
        fi
        port=$(( port + 1 ))
        attempt=$(( attempt + 1 ))
    done
    log_error "Nessuna porta libera trovata a partire da $1"
    return 1
}

# Purpose: port-forward in background che sopravvive alla funzione chiamante.
# Stampa la porta host effettivamente usata su stdout, i log vanno in ${PF_LOG_DIR}.
start_port_forward() {
    local namespace="$1" service="$2" remote_port="$3" preferred_port="$4"
    local log_dir="${PF_LOG_DIR:-/tmp}"
    local local_port
    local_port=$(find_free_port "${preferred_port}") || return 1

    kubectl port-forward -n "${namespace}" "svc/${service}" \
        "${local_port}:${remote_port}" > "${log_dir}/pf-${service}.log" 2>&1 &
    disown

    # Attende che il forward sia in ascolto: la chiamata successiva vedrà la porta occupata
    # e non la riassegnerà a un altro servizio.
    local attempt=0
    while (( attempt < 10 )); do
        port_in_listen "${local_port}" && break
        sleep 1
        attempt=$(( attempt + 1 ))
    done

    echo "${local_port}"
}
