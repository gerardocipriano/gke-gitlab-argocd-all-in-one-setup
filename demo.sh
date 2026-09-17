#!/usr/bin/env bash
# demo.sh - Percorso guidato alla demo Kargo, dal cluster vuoto alla promozione in prod.
# Uso: ./demo.sh [--provider kind|gke] [--from N] [--list] [--help]
# Ogni passo spiega cosa sta per succedere, mostra il comando e chiede conferma.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEPLOY="${SCRIPT_DIR}/deploy-k8s-bootstrap.sh"

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/config.sh"

PROVIDER="gke"
START_STEP=1
LIST_ONLY=0

usage() {
    cat <<EOF

Uso: $0 [--provider kind|gke] [--from N] [--list] [--help]

Opzioni:
  --provider kind|gke   Provider del cluster (default: kind)
  --from N              Riparte dal passo N, saltando i precedenti
  --list                Elenca i passi ed esce
  --help                Questo messaggio

Esempi:
  $0                        percorso completo su kind
  $0 --provider gke         percorso completo su GKE
  $0 --from 6               riprende dal passo 6

EOF
}

# =============================================================================
# PASSI
# =============================================================================

# titolo|spiegazione|comando di deploy-k8s-bootstrap.sh (vuoto = passo solo guidato)
STEPS=(
"Prerequisiti|Controlla e installa gli strumenti richiesti: kubectl, helm e il client del provider. Nessuna risorsa viene creata, quindi il passo e' ripetibile.|prereq"
"Cluster Kubernetes|Crea il cluster su cui gira tutta la demo. Con kind e' un container Docker locale, con GKE un cluster gestito raggiungibile via DNS endpoint.|cluster"
"GitLab|Installa GitLab CE dentro il cluster. E' la sorgente di verita' GitOps: ospitera' il repository che ArgoCD legge e su cui Kargo scrive a ogni promozione.|gitlab"
"Repository GitOps|Crea il repo gitops e ci pusha i manifest. Oltre a main vengono creati i branch stage/dev, stage/staging e stage/prod: li scrivera' Kargo con i manifest gia' renderizzati.|gitops"
"ArgoCD e App of Apps|Installa ArgoCD e la root Application che genera tutte le altre leggendo la cartella inventory del repo. Da qui in poi lo stato del cluster segue il git.|argocd"
"Kargo|Installa Kargo e crea le credenziali git del progetto. ArgoCD sincronizza Project, Warehouse, PromotionTask e i tre Stage.|kargo"
"Accessi alle UI|Espone le tre interfacce e stampa le credenziali. E' il momento di guardare la catena dev, staging, prod nella UI di Kargo.|"
"Promozione|Il Warehouse scopre i tag dell'immagine e crea un Freight. dev si promuove da solo, staging e prod si promuovono a mano: e' il gesto centrale della demo.|"
"Pulizia|Smonta la demo risorsa per risorsa, con una conferma per ogni blocco. Il cluster viene cancellato solo se lo chiedi esplicitamente.|teardown"
)

readonly TOTAL_STEPS=${#STEPS[@]}

step_field() {
    local index="$1" field="$2"
    echo "${STEPS[${index}]}" | cut -d'|' -f"${field}"
}

list_steps() {
    echo ""
    echo "Passi della demo Kargo:"
    echo ""
    local i
    for (( i = 0; i < TOTAL_STEPS; i++ )); do
        printf "  %d. %s\n" "$(( i + 1 ))" "$(step_field "${i}" 1)"
    done
    echo ""
    echo "Riprendi da un passo con: $0 --from N"
    echo ""
}

# =============================================================================
# INTERAZIONE
# =============================================================================

# Restituisce: 0 esegui, 1 salta. Su 'q' esce dicendo come riprendere.
ask_step() {
    local num="$1" prompt="$2"
    local choice
    read -r -p "${prompt} [Invio esegui / s salta / q esci]: " choice
    case "${choice}" in
        [qQ])
            echo ""
            log_info "Per riprendere da qui: $0 --provider ${PROVIDER} --from ${num}"
            exit 0
            ;;
        [sS]) return 1 ;;
        *)    return 0 ;;
    esac
}

print_step_header() {
    local num="$1"
    echo ""
    log_header "PASSO ${num} DI ${TOTAL_STEPS}: $(step_field "$(( num - 1 ))" 1)"
    echo ""
    # fold tiene le spiegazioni leggibili su terminali stretti
    step_field "$(( num - 1 ))" 2 | fold -s -w 78
    echo ""
}

run_deploy() {
    local cmd="$1"
    log_info "Comando: ./deploy-k8s-bootstrap.sh --provider ${PROVIDER} ${cmd}"
    echo ""
    "${DEPLOY}" --provider "${PROVIDER}" "${cmd}"
}

# =============================================================================
# VERIFICHE
# =============================================================================

verify_cluster() {
    log_info "Verifica: nodi del cluster"
    kubectl get nodes 2>/dev/null || log_warn "Nessun nodo raggiungibile: controlla il kubeconfig"
}

verify_gitlab() {
    log_info "Verifica: pod GitLab"
    kubectl get pods -n "${GITLAB_NAMESPACE}" 2>/dev/null || log_warn "Namespace ${GITLAB_NAMESPACE} assente"
    echo ""
    log_info "Atteso: un pod gitlab in stato Running. Il primo avvio richiede 5-10 minuti."
}

verify_gitops() {
    log_info "Verifica: branch del repo gitops"
    local pod pat
    pod=$(gitlab_get_pod)
    pat=$(gitlab_get_pat)
    if [[ -z "${pod}" || -z "${pat}" ]]; then
        log_warn "Pod GitLab o PAT non disponibili, salto la verifica"
        return 0
    fi
    kubectl exec -n "${GITLAB_NAMESPACE}" "${pod}" -- \
        curl -sf -H "PRIVATE-TOKEN: ${pat}" \
        "http://localhost:80/api/v4/projects/root%2Fgitops/repository/branches" 2>/dev/null |
        grep -o '"name":"[^"]*"' || log_warn "Impossibile leggere i branch dalla API GitLab"
    echo ""
    log_info "Attesi: main, stage/dev, stage/staging, stage/prod."
}

verify_argocd() {
    log_info "Verifica: Application ArgoCD"
    kubectl get applications -n "${ARGOCD_NAMESPACE}" 2>/dev/null || log_warn "Nessuna Application trovata"
    echo ""
    log_info "Attese: apps, gitlab, argocd, nginx, kargo-project e le tre kargo-demo-*."
    log_info "Le kargo-demo-* restano OutOfSync finche' non arriva la prima promozione."
}

verify_kargo() {
    log_info "Verifica: pod Kargo"
    kubectl get pods -n "${KARGO_NAMESPACE}" 2>/dev/null || log_warn "Namespace ${KARGO_NAMESPACE} assente"
    echo ""
    log_info "Verifica: Stage del progetto ${KARGO_PROJECT}"
    kubectl get stages -n "${KARGO_PROJECT}" 2>/dev/null ||
        log_warn "Stage non ancora presenti: ArgoCD deve prima sincronizzare kargo-project"
}

# =============================================================================
# PASSI GUIDATI
# =============================================================================

step_access() {
    if [[ "${PROVIDER}" == "kind" ]]; then
        log_info "Con kind i servizi sono gia' esposti via NodePort, non serve port-forward."
    else
        log_info "Avvio i port-forward in background. Restano vivi finche' non li fermi."
        kubectl port-forward -n "${GITLAB_NAMESPACE}" svc/gitlab "${GITLAB_LOCAL_PORT}:80" \
            >/tmp/pf-gitlab.log 2>&1 &
        disown
        kubectl port-forward -n "${ARGOCD_NAMESPACE}" svc/argocd-server "${ARGOCD_LOCAL_PORT}:443" \
            >/tmp/pf-argocd.log 2>&1 &
        disown
        kubectl port-forward -n "${KARGO_NAMESPACE}" svc/kargo-api "${KARGO_LOCAL_PORT}:443" \
            >/tmp/pf-kargo.log 2>&1 &
        disown
        sleep 3
        log_info "Per fermarli: pkill -f 'kubectl port-forward'"
    fi

    local argocd_password
    argocd_password=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "N/A")

    print_summary_box "ACCESSI" \
        "GitLab:  http://localhost:${GITLAB_LOCAL_PORT}  root / ${GITLAB_ROOT_PASSWORD}" \
        "ArgoCD:  https://localhost:${ARGOCD_LOCAL_PORT} admin / ${argocd_password}" \
        "Kargo:   https://localhost:${KARGO_LOCAL_PORT}  admin / ${KARGO_ADMIN_PASSWORD}"

    echo ""
    log_info "Nella UI di Kargo apri il progetto kargo-demo e guarda tre cose:"
    log_info "  1. il Warehouse, che elenca i tag dell'immagine che sta osservando"
    log_info "  2. il Freight, l'unita' promuovibile con dentro il riferimento all'immagine"
    log_info "  3. la catena dei tre Stage: dev riceve dal Warehouse, staging da dev, prod da staging"
}

step_promotion() {
    log_info "Freight disponibili:"
    kubectl get freight -n "${KARGO_PROJECT}" 2>/dev/null || log_warn "Nessun Freight: il Warehouse potrebbe non raggiungere il registry"
    echo ""
    log_info "Promozioni gia' avvenute:"
    kubectl get promotions -n "${KARGO_PROJECT}" 2>/dev/null || true
    echo ""
    log_info "dev si promuove da solo: e' la promotionPolicy nel Project."
    log_info "Per staging e prod apri lo Stage nella UI e clicca Promote sul Freight."
    log_info "Equivalente da riga di comando, se hai la CLI kargo:"
    log_info "  kargo promote --project ${KARGO_PROJECT} --stage staging --freight <nome>"
    echo ""
    read -r -p "Premi Invio quando hai promosso staging e prod: " _

    echo ""
    log_info "Stato dei tre ambienti:"
    local ns expected
    for ns in dev staging prod; do
        case "${ns}" in
            dev)     expected=1 ;;
            staging) expected=2 ;;
            prod)    expected=3 ;;
        esac
        local ready
        ready=$(kubectl get deployment kargo-demo -n "kargo-demo-${ns}" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
        printf "  kargo-demo-%-8s repliche pronte: %-3s (attese: %s)\n" \
            "${ns}" "${ready:-0}" "${expected}"
    done
    echo ""
    log_info "Il numero di repliche cambia per stage perche' cambia l'overlay kustomize,"
    log_info "non perche' qualcuno abbia toccato il cluster a mano."
}

# =============================================================================
# MAIN
# =============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --provider)   PROVIDER="${2:-}"; shift 2 ;;
        --provider=*) PROVIDER="${1#*=}"; shift ;;
        --from)       START_STEP="${2:-1}"; shift 2 ;;
        --from=*)     START_STEP="${1#*=}"; shift ;;
        --list)       LIST_ONLY=1; shift ;;
        --help|-h)    usage; exit 0 ;;
        *)            echo "Opzione sconosciuta: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ "${LIST_ONLY}" -eq 1 ]]; then
    list_steps
    exit 0
fi

if [[ "${PROVIDER}" != "kind" && "${PROVIDER}" != "gke" ]]; then
    log_error "Provider non valido: '${PROVIDER}'. Usa kind o gke."
    exit 1
fi

if [[ ! "${START_STEP}" =~ ^[0-9]+$ ]] || (( START_STEP < 1 || START_STEP > TOTAL_STEPS )); then
    log_error "--from accetta un numero da 1 a ${TOTAL_STEPS} (ricevuto: '${START_STEP}')"
    exit 1
fi

if [[ ! -t 0 ]]; then
    log_error "Serve un terminale interattivo. Per l'uso non interattivo usa ./deploy-k8s-bootstrap.sh."
    exit 1
fi

# gitlab_get_pod e gitlab_get_pat servono alla verifica del passo 4
source "${SCRIPT_DIR}/lib/gitlab.sh"

log_header "DEMO KARGO [${PROVIDER}]"
log_info "Nove passi, dal cluster vuoto alla promozione in prod."
log_info "A ogni passo: Invio per eseguire, s per saltare, q per uscire."
if (( START_STEP > 1 )); then
    log_info "Parto dal passo ${START_STEP}, i precedenti li considero gia' fatti."
fi

for (( step = START_STEP; step <= TOTAL_STEPS; step++ )); do
    print_step_header "${step}"
    cmd=$(step_field "$(( step - 1 ))" 3)

    if [[ -n "${cmd}" ]]; then
        log_info "Comando: ./deploy-k8s-bootstrap.sh --provider ${PROVIDER} ${cmd}"
        echo ""
    fi

    if ! ask_step "${step}" "Eseguo questo passo?"; then
        log_warn "Passo ${step} saltato."
        continue
    fi

    case "${step}" in
        1) run_deploy prereq ;;
        2) run_deploy cluster; verify_cluster ;;
        3) run_deploy gitlab;  verify_gitlab ;;
        4) run_deploy gitops;  verify_gitops ;;
        5) run_deploy argocd;  verify_argocd ;;
        6) run_deploy kargo;   verify_kargo ;;
        7) step_access ;;
        8) step_promotion ;;
        9) run_deploy teardown ;;
    esac
done

echo ""
log_success "Percorso completato."
