#!/usr/bin/env bash
# demo.sh - Demo GitOps dal vivo: GitLab, ArgoCD e Kargo, con banco di regia nel browser.
# Uso: ./demo.sh [prepare|present|teardown] [--provider kind|gke] [--from N] [--list] [--no-dashboard]
# prepare prima della sessione (circa 30 minuti su GKE), present davanti al pubblico.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEPLOY="${SCRIPT_DIR}/bootstrap.sh"

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/gitlab.sh"
source "${SCRIPT_DIR}/lib/presenter.sh"

MODE="present"
PROVIDER="${CLUSTER_PROVIDER:-gke}"
START=1
LIST_ONLY=0
DASHBOARD_ENABLED=1
readonly RELEASE_CONSTRAINT="${RELEASE_CONSTRAINT:-~6.10.0}"
readonly DIM='\033[2m'

usage() {
    cat <<EOF

Uso: $0 [prepare|present|teardown] [opzioni]

Modalità:
  prepare    Crea cluster, GitLab, repo GitOps, ArgoCD e Kargo. Da lanciare prima della
             sessione: su GKE richiede circa 30 minuti.
  present    La demo davanti al pubblico, nove capitoli (default). Circa 35 minuti.
  teardown   Smonta tutto, con una conferma per blocco e una per il cluster.

Opzioni:
  --provider kind|gke   Provider del cluster (default: gke)
  --from N              Riparte dal passo N di prepare o dal capitolo N di present
  --list                Elenca passi e capitoli ed esce
  --no-dashboard        Non avviare il banco di regia
  --help                Questo messaggio

Esempi:
  $0 prepare              prepara l'ambiente su GKE
  $0                      presenta
  $0 --from 5             riprende la presentazione dal capitolo 5

EOF
}

# =============================================================================
# OUTPUT PER CHI PRESENTA
# =============================================================================

title() {
    echo ""
    printf "${BOLD}${CYAN}━━ %s ${NC}\n" "$1"
}

# Punti da dire al pubblico: li legge solo chi presenta.
say() {
    local line
    for line in "$@"; do
        fold -s -w 92 <<< "${line}" | sed -e "1s/^/  $(printf "${MAGENTA}")»$(printf "${NC}") /" -e '2,$s/^/    /'
        palco_notes_add "${line}"
    done
}

info() { printf "  %s\n" "$1"; }
ok()   { printf "  ${GREEN}✔${NC} %s\n" "$1"; }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$1"; }

# Mostra il comando prima di eseguirlo: il pubblico deve vedere cosa succede davvero.
run() {
    printf "  ${DIM}\$ %s${NC}\n" "$*"
    "$@" 2>&1 | sed 's/^/    /'
    local rc=${PIPESTATUS[0]}
    (( rc == 0 )) || warn "il comando è uscito con ${rc}"
    return 0
}

# Aspetta Invio dal terminale oppure un comando dal banco, quale arriva prima.
pause() {
    local prompt="$1" choice="" part="" key=""
    echo ""
    palco_prompt_open "${prompt}"
    printf "  [Invio] %s  (q esce) " "${prompt}"
    while true; do
        # read -t salva l'input parziale in caso di timeout: si accumula, così una lettera
        # digitata a cavallo del secondo non va persa.
        if read -r -t 1 part; then
            choice+="${part}"
            break
        fi
        choice+="${part}"
        part=""
        if key=$(palco_take_cmd); then
            case "${key}" in
                u) choice="u" ;;
                q) choice="q" ;;
                *) choice="" ;;
            esac
            printf "${DIM}(dal banco: %s)${NC}\n" "${key/enter/avanti}"
            break
        fi
    done
    palco_prompt_close
    if [[ "${choice}" =~ ^[qQ]$ ]]; then
        echo ""
        [[ "${MODE}" == "present" ]] &&
            info "Per riprendere da qui: $0 present --provider ${PROVIDER} --from ${CURRENT_CHAPTER}"
        exit 0
    fi
    REPLY_CHOICE="${choice}"
}

REPLY_CHOICE=""
CURRENT_CHAPTER=1

# Mostra la domanda sul palco. La lettera giusta la vede solo chi presenta.
ask() {
    local chapter="$1" index="$2" answer="$3" note="${4:-}"
    palco_state "${chapter}" ask "${index}" "${note}"
    echo ""
    printf "  ${BOLD}Prevedi${NC}: domanda sul palco, fai votare A-D per alzata di mano. ${DIM}(risposta: %s)${NC}\n" "${answer}"
}

reveal() {
    palco_state "$1" reveal "$2" "${3:-}"
    ok "Risposta mostrata sul palco."
}

# =============================================================================
# PREPARE
# =============================================================================

# titolo|comando di bootstrap.sh|minuti su GKE
PREP_STEPS=(
"Prerequisiti: gcloud, kubectl, helm, jq, python3|prereq|1"
"Cluster GKE Autopilot regionale|cluster|8"
"GitLab CE nel cluster, utente root e token|gitlab|16"
"Repository: platform, kargo-demo con i branch stage/*, nginx|gitops|2"
"ArgoCD e la root Application 'apps'|argocd|2"
"cert-manager, Kargo e credenziali git del progetto|kargo|6"
)

# Stato dei passi per il banco: done fino a START-1, poi running/todo/failed.
PREP_STATUS=()

prep_publish() {
    local i t cmd m json='[]'
    for (( i = 0; i < ${#PREP_STEPS[@]}; i++ )); do
        IFS='|' read -r t cmd m <<< "${PREP_STEPS[${i}]}"
        json=$(jq -c --arg t "${t}" --argjson m "${m}" --arg s "${PREP_STATUS[${i}]}" \
            --argjson started "${PREP_STARTED[${i}]:-0}" \
            '. + [{title: $t, minutes: $m, status: $s, started: $started}]' <<< "${json}")
    done
    palco_set_prep "${json}"
}

PREP_STARTED=()

prepare() {
    local total=${#PREP_STEPS[@]} i t0 t_step step_title cmd minutes
    t0=$(date +%s)
    for (( i = 0; i < total; i++ )); do
        PREP_STATUS[i]=$( (( i + 1 < START )) && echo done || echo todo )
    done
    if (( DASHBOARD_ENABLED == 1 )); then
        trap palco_stop EXIT
        PALCO_MODE="prepare"
        palco_start "${SCRIPT_DIR}/docs/banco-regia.html"
        prep_publish
        browser_open "$(palco_url)" || true
        info "Banco di regia: $(palco_url) (segue i passi da solo)"
    fi
    title "PREPARAZIONE [${PROVIDER}]"
    info "Sei passi, circa 33 minuti su GKE. Non serve guardarli: alla fine c'è il riepilogo."
    for (( i = START; i <= total; i++ )); do
        IFS='|' read -r step_title cmd minutes <<< "${PREP_STEPS[$(( i - 1 ))]}"
        title "Passo ${i} di ${total}: ${step_title} (circa ${minutes} min)"
        PREP_STATUS[i - 1]=running
        PREP_STARTED[i - 1]=$(date +%s)
        prep_publish
        t_step=$(date +%s)
        if ! "${DEPLOY}" --provider "${PROVIDER}" "${cmd}"; then
            PREP_STATUS[i - 1]=failed
            prep_publish
            palco_next "Passo ${i} fallito: leggi l'errore nel terminale, correggi e rilancia $0 prepare --provider ${PROVIDER} --from ${i}"
            echo ""
            log_error "Passo ${i} fallito. Dopo aver corretto la causa: $0 prepare --provider ${PROVIDER} --from ${i}"
            exit 1
        fi
        PREP_STATUS[i - 1]=done
        prep_publish
        ok "Passo ${i} completato in $(( ($(date +%s) - t_step) / 60 )) min"
    done
    title "PRONTO in $(( ($(date +%s) - t0) / 60 )) minuti"
    preflight || true
    info "Quando il pubblico è in sala: $0 present --provider ${PROVIDER}"
    palco_next "Ambiente pronto. Quando il pubblico è in sala lancia: $0 present --provider ${PROVIDER}"
    # Il banco resta acceso finché chi presenta non chiude: la scheda aperta si ricollega
    # da sola quando parte present, se la porta è la stessa.
    if (( DASHBOARD_ENABLED == 1 )); then
        pause "chiudo il banco (lo riapre present)"
    fi
}

# =============================================================================
# PRESENT: infrastruttura della sessione
# =============================================================================

preflight() {
    local problems=0
    if ! kubectl get stage dev -n "${KARGO_PROJECT}" &>/dev/null; then
        log_error "Stage Kargo assenti: lancia prima $0 prepare --provider ${PROVIDER}"
        return 1
    fi
    [[ -n "$(kargo_stage_freight dev)" ]] || { warn "dev non ha ancora un Freight: il Warehouse potrebbe non raggiungere il registry"; problems=1; }
    [[ -n "$(gitlab_get_pat)" ]] || { warn "PAT GitLab assente"; problems=1; }
    (( problems == 0 )) && ok "Ambiente pronto: Stage presenti, dev ha un Freight, GitLab raggiungibile."
    return 0
}

GITLAB_URL="" ARGOCD_URL="" KARGO_URL="" ARGOCD_PASSWORD=""
declare -A APP_PORTS=()

start_access() {
    local gp="${GITLAB_LOCAL_PORT}" ap="${ARGOCD_LOCAL_PORT}" kp="${KARGO_LOCAL_PORT}"
    if [[ "${PROVIDER}" == "gke" ]]; then
        pf_start "${GITLAB_NAMESPACE}" gitlab 80 "${GITLAB_LOCAL_PORT}" http;             gp="${PF_LAST_PORT}"
        pf_start "${ARGOCD_NAMESPACE}" argocd-server 443 "${ARGOCD_LOCAL_PORT}" https;   ap="${PF_LAST_PORT}"
        pf_start "${KARGO_NAMESPACE}" kargo-api 443 "${KARGO_LOCAL_PORT}" https;         kp="${PF_LAST_PORT}"
        pf_wait_ready "https://127.0.0.1:${kp}/" || warn "La porta di Kargo non risponde ancora"
        # Le app degli stage: staging e prod non esistono prima della loro prima promozione,
        # il supervisore riprova finché il Service non compare.
        local s port=18091
        for s in dev staging prod; do
            pf_start "kargo-demo-${s}" kargo-demo 80 "${port}" http
            APP_PORTS[${s}]="${PF_LAST_PORT}"
            port=$(( PF_LAST_PORT + 1 ))
        done
    fi
    GITLAB_URL="http://localhost:${gp}"
    ARGOCD_URL="https://localhost:${ap}"
    KARGO_URL="https://localhost:${kp}"
    ARGOCD_PASSWORD=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "N/A")

    local attempt
    for attempt in 1 2 3 4 5; do
        kargo_api_login "${KARGO_URL}" && break
        sleep 2
    done
    [[ -n "${KARGO_TOKEN}" ]] || { log_error "Login admin su Kargo fallito (${KARGO_URL})"; exit 1; }
}

cleanup() {
    palco_stop
    pf_stop
}

print_access() {
    print_summary_box "ACCESSI (solo per chi presenta)" \
        "Banco:   $( (( DASHBOARD_ENABLED == 1 )) && palco_url || echo disattivato)" \
        "GitLab:  ${GITLAB_URL}  root / ${GITLAB_ROOT_PASSWORD}" \
        "ArgoCD:  ${ARGOCD_URL} admin / ${ARGOCD_PASSWORD}" \
        "Kargo:   ${KARGO_URL}  admin / ${KARGO_ADMIN_PASSWORD}"
    info "Il banco si comanda da solo: Avanti (o Invio, spazio, PagGiu') vale come Invio qui."
    info "Fai login nelle tre UI adesso: nel pannello Accessi del banco (tasto a) un clic copia URL, utente e password."
}

browser_open() {
    local opener
    for opener in "${BROWSER:-}" xdg-open open; do
        [[ -n "${opener}" ]] && command -v "${opener}" >/dev/null 2>&1 || continue
        "${opener}" "$1" >/dev/null 2>&1 &
        return 0
    done
    return 1
}

# =============================================================================
# PRESENT: capitoli
# =============================================================================

# id|titolo|minuti
CHAPTERS=(
"mappa|La mappa|3"
"appofapps|Il git comanda|3"
"freight|Warehouse e Freight|3"
"promote|Promozione con cancello|6"
"release|Arriva una nuova versione|4"
"config|Anche la configurazione viaggia|4"
"drift|Drift: chi vince|5"
"rollback|Rollback|3"
"debrief|Debriefing|5"
)

chapter_header() {
    local n="$1" id t m
    IFS='|' read -r id t m <<< "${CHAPTERS[$(( n - 1 ))]}"
    CURRENT_CHAPTER="${n}"
    palco_notes_reset
    palco_state "${id}" intro
    title "Capitolo ${n} di ${#CHAPTERS[@]}: ${t}  (circa ${m} min)"
}

# Versione e messaggio dichiarati da podinfo stesso, attraverso il port-forward dello stage:
# è la prova che gira davvero, non solo che il manifest lo dice.
app_info() {
    local port="${APP_PORTS[$1]:-}"
    [[ -n "${port}" ]] || { echo "-"; return; }
    curl -s -m 3 "http://127.0.0.1:${port}/" 2>/dev/null | jq -r '"\(.version) \(.message)"' 2>/dev/null || echo "-"
}

stage_table() {
    local s tag ready desired sync
    printf "    ${DIM}%-9s %-9s %-9s %-10s %s${NC}\n" "stage" "podinfo" "repliche" "argocd" "l'app risponde"
    for s in dev staging prod; do
        tag=$(kubectl get deploy kargo-demo -n "kargo-demo-${s}" \
            -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://')
        ready=$(kubectl get deploy kargo-demo -n "kargo-demo-${s}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
        desired=$(kubectl get deploy kargo-demo -n "kargo-demo-${s}" -o jsonpath='{.spec.replicas}' 2>/dev/null)
        sync=$(kubectl get application "kargo-demo-${s}" -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.status.sync.status}' 2>/dev/null)
        printf "    %-9s %-9s %-9s %-10s %s\n" "${s}" "${tag:--}" "${ready:-0}/${desired:-0}" "${sync:--}" "$(app_info "${s}")"
    done
}

# Promuove da API oppure, se chi presenta sceglie u, aspetta che qualcuno lo faccia dalla UI.
promote_step() {
    local stage="$1" freight="$2" alias
    alias=$(kargo_freight_alias "${freight}")
    pause "promuovo ${alias} in ${stage} da qui, oppure scrivi u e lo fa qualcuno del pubblico dalla UI"
    if [[ "${REPLY_CHOICE}" =~ ^[uU]$ ]]; then
        palco_note "Tocca a voi: nella UI di Kargo trascinate ${alias} sullo stage ${stage}, oppure Promote"
        info "In attesa della promozione di ${alias} su ${stage} dalla UI..."
    else
        palco_note "Promozione di ${alias} su ${stage}"
        printf "  ${DIM}\$ POST PromoteToStage {stage: %s, freight: %s}${NC}\n" "${stage}" "${alias}"
        kargo_promote "${stage}" "${freight}" | sed 's/^/    promotion /'
    fi
    if kargo_wait_stage "${stage}" "${freight}" 600; then
        ok "${stage} ha ${alias} ed è Healthy"
    else
        warn "${stage} non è Healthy dopo 10 minuti: guarda la Promotion nella UI di Kargo"
    fi
    palco_note ""
}

ch_mappa() {
    chapter_header 1
    say "Tre attori. GitLab tiene i repository: sono l'unica fonte di verità." \
        "Un repo per la piattaforma e uno per ogni app: chi gestisce il cluster e chi sviluppa non si pestano i piedi." \
        "ArgoCD confronta il cluster con i repo e lo riallinea. Non scrive mai nei repo." \
        "Kargo decide quale versione va in quale ambiente, e lo fa con un commit." \
        "Tutto gira dentro un cluster GKE Autopilot: niente nodi da gestire, si paga per pod."
    pause "domanda al pubblico"
    ask mappa 0 C
    pause "mostro chi ha fatto i commit"
    run kubectl get applications -n "${ARGOCD_NAMESPACE}"
    echo ""
    info "Ultimo commit per repo e branch (autore e messaggio):"
    local ref repo
    for repo in platform nginx; do
        printf "    %-27s %s\n" "${repo}:main" "$(gitlab_last_commit main "${repo}")"
    done
    for ref in main stage/dev stage/staging stage/prod; do
        printf "    %-27s %s\n" "${KARGO_PROJECT}:${ref}" "$(gitlab_last_commit "${ref}")"
    done
    reveal mappa 0
    say "main lo scrive una persona. I branch stage/* li scrive solo Kargo, e ogni app promossa ha i suoi nel proprio repo." \
        "nginx non ha promozione: ArgoCD lo sincronizza direttamente dal main del suo repo."
    pause "capitolo successivo"
}

ch_appofapps() {
    chapter_header 2
    say "Le otto Application non le ha create nessuno a mano: la root 'apps' legge la cartella inventory." \
        "Quindi anche la configurazione di ArgoCD sta nel git. Proviamo a romperla."
    pause "domanda al pubblico"
    ask appofapps 0 B
    pause "cancello la Application nginx"
    local t0 created before
    before=$(kubectl get deploy nginx -n nginx -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
    run kubectl delete application nginx -n "${ARGOCD_NAMESPACE}"
    t0=$(date +%s)
    # Di solito la root la ricrea in pochi secondi, ma dipende da quando riconcilia: visto
    # fino a circa 90s. Si aspetta la condizione e si dice quanto ci ha messo.
    palco_note "La root 'apps' confronta la cartella inventory con il cluster"
    for _ in $(seq 1 150); do
        created=$(kubectl get application nginx -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)
        [[ -n "${created}" ]] && break
        sleep 1
    done
    palco_note ""
    if [[ -n "${created}" ]]; then
        ok "Application nginx ricreata dalla root dopo $(( $(date +%s) - t0 ))s"
    else
        warn "Application non ancora ricreata: controlla la root 'apps' nella UI"
    fi
    info "Deployment nginx creato alle ${before:-?}: è lo stesso di prima, i pod non si sono mossi."
    reveal appofapps 0
    say "Per togliere un'applicazione si cancella il suo file in inventory, con un commit. kubectl da solo non basta."
    pause "capitolo successivo"
}

ch_freight() {
    chapter_header 3
    say "Il Warehouse osserva due cose: l'immagine ghcr.io/stefanprodan/podinfo con un vincolo semver," \
        "e il repo ${KARGO_PROJECT}, solo la cartella app/." \
        "Ogni Freight è la coppia tag più commit, con un nome leggibile. dev l'ha già ricevuto: nessuno ha cliccato."
    info "Freight disponibili (alias, tag di podinfo, commit di configurazione):"
    kubectl get freight -n "${KARGO_PROJECT}" -o json 2>/dev/null |
        jq -r '.items | sort_by(.metadata.creationTimestamp) | reverse | .[] | "    \(.alias)  podinfo \(.images[0].tag)  config \(.commits[0].id[0:8])"' 
    pause "domanda al pubblico"
    ask freight 0 A
    pause "mostro la configurazione e il branch stage/dev"
    run kubectl get projectconfig "${KARGO_PROJECT}" -n "${KARGO_PROJECT}" -o jsonpath='{.spec}'
    echo ""
    run kubectl get promotions -n "${KARGO_PROJECT}"
    echo ""
    info "Il manifest renderizzato nel branch stage/dev (estratto):"
    gitlab_file_raw manifests.yaml stage/dev | grep -E '^kind:|^  replicas:|image:' | sed 's/^/    /'
    reveal freight 0
    say "Nel branch non c'è kustomize da interpretare: c'è YAML finito, con l'immagine e le repliche in chiaro."
    pause "seconda domanda al pubblico"
    ask freight 1 B
    pause "risposta"
    run kubectl get warehouse kargo-demo -n "${KARGO_PROJECT}" -o jsonpath='{range .spec.subscriptions[*]}{.image.repoURL}{.git.repoURL} {.git.includePaths}{"\n"}{end}'
    reveal freight 1
    pause "capitolo successivo"
}

ch_promote() {
    chapter_header 4
    local freight alias
    freight=$(kargo_stage_freight dev)
    alias=$(kargo_freight_alias "${freight}")
    say "In dev c'è ${alias} (podinfo $(kargo_freight_tag "${freight}")). staging e prod si promuovono a mano." \
        "Primo tentativo: saltare staging e andare dritti in prod."
    pause "domanda al pubblico"
    ask promote 0 B
    pause "provo a promuovere ${alias} direttamente in prod"
    printf "  ${DIM}\$ POST PromoteToStage {stage: prod, freight: %s}${NC}\n" "${alias}"
    local out
    if out=$(kargo_promote prod "${freight}"); then
        warn "prod ha accettato: ${alias} era già passato da staging in un giro precedente"
    else
        printf "    ${RED}rifiutata${NC}: %s\n" "${out}"
    fi
    reveal promote 0
    say "La catena è nello Stage prod: requestedFreight con sources.stages [staging]. Non è una convenzione, è un vincolo."

    promote_step staging "${freight}"
    promote_step prod "${freight}"
    stage_table

    pause "seconda domanda al pubblico"
    ask promote 1 A
    pause "mostro da dove arrivano le repliche"
    local s
    for s in dev staging prod; do
        printf "    %-8s overlay: %-3s  branch stage/%s: %s\n" "${s}" \
            "$(awk '/count:/ {print $2; exit}' "${SCRIPT_DIR}/repos/${KARGO_PROJECT}/app/stages/${s}/kustomization.yaml")" \
            "${s}" "$(gitlab_file_raw manifests.yaml "stage/${s}" | awk '/replicas:/ {print $2; exit}')"
    done
    info "Ultimo commit su stage/prod: $(gitlab_last_commit stage/prod)"
    reveal promote 1
    say "Nella UI di GitLab, il diff di quel commit è esattamente ciò che ArgoCD ha applicato in prod."
    pause "capitolo successivo"
}

ch_release() {
    chapter_header 5
    local current
    current=$(kubectl get warehouse kargo-demo -n "${KARGO_PROJECT}" -o jsonpath='{.spec.subscriptions[0].image.constraint}')
    say "Esce una nuova serie di podinfo. Invece di aspettare, cambiamo cosa osserva il Warehouse." \
        "È un commit su main, come lo farebbe un developer: niente kubectl."
    pause "domanda al pubblico"
    ask release 0 B
    pause "committo il nuovo vincolo ${RELEASE_CONSTRAINT} su main"

    if [[ "${current}" == "${RELEASE_CONSTRAINT}" ]]; then
        warn "Il Warehouse osserva già ${RELEASE_CONSTRAINT}: salto il commit"
    else
        local content new sha
        content=$(gitlab_file_raw kargo/warehouse.yaml main)
        new=$(sed "s/constraint: \"${current}\"/constraint: \"${RELEASE_CONSTRAINT}\"/" <<< "${content}")
        diff <(echo "${content}") <(echo "${new}") | sed 's/^/    /' || true
        sha=$(gitlab_commit_file kargo/warehouse.yaml "${new}" \
            "feat(warehouse): osserva la serie ${RELEASE_CONSTRAINT} di podinfo")
        ok "Commit ${sha} su main"
    fi

    # ArgoCD interroga il repo ogni 3 minuti e il Warehouse il registry ogni 5: sul palco
    # si chiede il refresh subito. In produzione lo fanno i webhook di GitLab e del registry.
    palco_note "ArgoCD applica il nuovo Warehouse, Kargo interroga il registry"
    info "Chiedo il refresh invece di aspettare il polling (in produzione: webhook)."
    run kubectl annotate application kargo-project -n "${ARGOCD_NAMESPACE}" argocd.argoproj.io/refresh=normal --overwrite
    local i freight=""
    for i in $(seq 1 60); do
        [[ "$(kubectl get warehouse kargo-demo -n "${KARGO_PROJECT}" -o jsonpath='{.spec.subscriptions[0].image.constraint}')" == "${RELEASE_CONSTRAINT}" ]] && break
        sleep 2
    done
    run kubectl annotate warehouse kargo-demo -n "${KARGO_PROJECT}" "kargo.akuity.io/refresh=$(date +%s)" --overwrite
    local series
    series=$(cut -d. -f1-2 <<< "${RELEASE_CONSTRAINT#\~}")
    for i in $(seq 1 60); do
        freight=$(kargo_freight_by_age | sed -n 1p)
        [[ "$(kargo_freight_tag "${freight}")" == "${series}".* ]] && break
        sleep 2
    done
    ok "Nuovo Freight: $(kargo_freight_alias "${freight}") (podinfo $(kargo_freight_tag "${freight}"))"
    palco_note "dev si promuove da solo"
    if kargo_wait_stage dev "${freight}" 300; then
        ok "dev ha già la nuova versione"
    else
        warn "dev non ha ancora la nuova versione: guarda la Promotion nella UI di Kargo"
    fi
    palco_note ""
    stage_table
    reveal release 0
    say "Due versioni in tre ambienti, e il perché è scritto in git: il commit su main e i commit di Kargo sui branch."
    pause "capitolo successivo"
}

ch_config() {
    chapter_header 6
    local old_msg="GitOps dal vivo" new_msg="GitOps dal vivo, configurazione v2"
    say "Il Freight non è solo un'immagine. Cambiamo la configurazione dell'app senza toccare l'immagine:" \
        "il messaggio che podinfo mostra nella sua pagina."
    stage_table
    pause "domanda al pubblico"
    ask config 0 B
    pause "committo il nuovo messaggio su main"
    local content new sha="" i freight="" before
    before=$(kargo_freight_by_age | sed -n 1p)
    content=$(gitlab_file_raw app/base/deployment.yaml main)
    if grep -q "${new_msg}" <<< "${content}"; then
        warn "Il messaggio è già quello nuovo: salto il commit"
    else
        new=$(sed "s/value: \"${old_msg}\"/value: \"${new_msg}\"/" <<< "${content}")
        diff <(echo "${content}") <(echo "${new}") | sed 's/^/    /' || true
        sha=$(gitlab_commit_file app/base/deployment.yaml "${new}" "feat(app): nuovo messaggio della UI")
        ok "Commit ${sha} su main"
    fi
    palco_note "Il Warehouse vede il commit sotto app/"
    run kubectl annotate warehouse kargo-demo -n "${KARGO_PROJECT}" "kargo.akuity.io/refresh=$(date +%s)" --overwrite
    for i in $(seq 1 60); do
        freight=$(kargo_freight_by_age | sed -n 1p)
        [[ -n "${freight}" && "${freight}" != "${before}" ]] && break
        sleep 2
    done
    if [[ "${freight}" == "${before}" ]]; then
        warn "Nessun Freight nuovo dopo 2 minuti: guarda il Warehouse nella UI di Kargo"
    else
        ok "Nuovo Freight: $(kargo_freight_alias "${freight}") (podinfo $(kargo_freight_tag "${freight}"), config $(kubectl get freight "${freight}" -n "${KARGO_PROJECT}" -o jsonpath='{.commits[0].id}' | cut -c1-8))"
        palco_note "dev si promuove da solo"
        kargo_wait_stage dev "${freight}" 300 && ok "dev ha la nuova configurazione" ||
            warn "dev non ha ancora la nuova configurazione: guarda la Promotion nella UI di Kargo"
    fi
    palco_note ""
    stage_table
    reveal config 0
    say "Stessa immagine, configurazione nuova: per Kargo è una release come le altre, con la stessa catena." \
        "ArgoCD non ha applicato main da nessuna parte: staging e prod leggono i loro branch, fermi al Freight di prima."
    pause "capitolo successivo"
}

ch_drift() {
    chapter_header 7
    say "Ora facciamo ciò che in GitOps non si fa: modifichiamo il cluster a mano." \
        "dev ha selfHeal attivo, staging no. Guardate i pallini delle repliche sul banco."
    pause "domanda al pubblico"
    ask drift 0 B
    pause "scalo dev a 4 e staging a 5"
    run kubectl scale deployment kargo-demo -n kargo-demo-dev --replicas=4
    run kubectl scale deployment kargo-demo -n kargo-demo-staging --replicas=5
    # Il rientro di dev non è sempre immediato: ArgoCD applica un backoff esponenziale ai
    # self-heal ripetuti (2s, x3, fino a 300s). Si aspetta la condizione, non un tempo fisso.
    local i t0 dev_r stg_s healed_after=0
    t0=$(date +%s)
    for i in $(seq 1 40); do
        sleep 3
        dev_r=$(kubectl get deploy kargo-demo -n kargo-demo-dev -o jsonpath='{.spec.replicas}' 2>/dev/null)
        stg_s=$(kubectl get application kargo-demo-staging -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.status.sync.status}' 2>/dev/null)
        (( healed_after == 0 )) && [[ "${dev_r}" == "1" ]] && healed_after=$(( $(date +%s) - t0 ))
        echo ""
        info "dopo $(( $(date +%s) - t0 ))s:"
        stage_table
        [[ "${dev_r}" == "1" && "${stg_s}" == "OutOfSync" ]] && break
    done
    if (( healed_after > 15 )); then
        say "dev ci ha messo più di qualche secondo: ArgoCD rallenta i self-heal ripetuti con un backoff," \
            "per non entrare in una lotta infinita con un altro controller che riscrive lo stesso campo."
    fi
    echo ""
    info "Gli eventi del Deployment in dev raccontano il rientro:"
    kubectl get events -n kargo-demo-dev --field-selector reason=ScalingReplicaSet \
        --sort-by=.lastTimestamp 2>/dev/null | tail -2 | sed 's/^/    /'
    reveal drift 0
    say "In dev il drift è durato un secondo: troppo poco per vedere OutOfSync, per questo mostriamo gli eventi." \
        "In staging ArgoCD vede il drift e lo segnala, ma non tocca niente: rientrare è una decisione."
    pause "riallineo staging con un Sync, come da UI"
    run kubectl patch application kargo-demo-staging -n "${ARGOCD_NAMESPACE}" --type merge \
        -p '{"operation":{"initiatedBy":{"username":"demo.sh"},"sync":{}}}'
    for i in $(seq 1 30); do
        sleep 2
        [[ "$(kubectl get deploy kargo-demo -n kargo-demo-staging -o jsonpath='{.spec.replicas}')" == "2" ]] || continue
        # Stesso motivo di kargo_wait_stage: dopo il sync lo stato va ricalcolato.
        kubectl annotate application kargo-demo-staging -n "${ARGOCD_NAMESPACE}" \
            argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1
        sleep 3
        [[ "$(kubectl get application kargo-demo-staging -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.status.sync.status}')" == "Synced" ]] && break
    done
    stage_table
    pause "seconda domanda al pubblico"
    ask drift 1 B
    pause "risposta"
    run kubectl get application kargo-demo-dev -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.spec.syncPolicy.automated}'
    echo ""
    reveal drift 1
    pause "capitolo successivo"
}

ch_rollback() {
    chapter_header 8
    local newest previous
    newest=$(kargo_freight_by_age | sed -n 1p)
    # Il rollback torna a ciò che staging aveva davvero prima, non al penultimo Freight creato.
    previous=$(kargo_stage_freight staging)
    if [[ -z "${previous}" || "${previous}" == "${newest}" ]]; then
        previous=$(kargo_freight_by_age | sed -n 2p)
    fi
    if [[ -z "${previous}" ]]; then
        warn "C'è un solo Freight: il rollback richiede i capitoli 5 e 6. Salto."
        return 0
    fi
    say "Portiamo la nuova versione in staging, poi facciamo finta che abbia un bug."
    if [[ "$(kargo_stage_freight staging)" != "${newest}" ]]; then
        promote_step staging "${newest}"
    fi
    stage_table
    say "Il bug è in staging, adesso. Come si torna indietro?"
    pause "domanda al pubblico"
    ask rollback 0 B
    pause "ripromuovo in staging $(kargo_freight_alias "${previous}")"
    printf "  ${DIM}\$ POST PromoteToStage {stage: staging, freight: %s}${NC}\n" "$(kargo_freight_alias "${previous}")"
    kargo_promote staging "${previous}" | sed 's/^/    promotion /'
    if kargo_wait_stage staging "${previous}" 300; then
        ok "staging è tornato a $(kargo_freight_alias "${previous}") (podinfo $(kargo_freight_tag "${previous}"))"
    else
        warn "staging non è ancora Healthy: guarda la Promotion nella UI di Kargo"
    fi
    stage_table
    info "Ultimo commit su stage/staging: $(gitlab_last_commit stage/staging)"
    reveal rollback 0
    say "Il rollback è un commit nuovo, non una riscrittura della storia: l'audit resta completo."
    pause "capitolo successivo"
}

ch_debrief() {
    chapter_header 9
    say "Quattro domande per chiudere. La terza è il limite da dichiarare, prima che lo chieda qualcuno."
    local answers=(B B B B) i
    for i in 0 1 2 3; do
        pause "domanda $(( i + 1 )) di 4"
        ask debrief "${i}" "${answers[${i}]}"
        pause "risposta"
        reveal debrief "${i}"
    done
    say "In produzione: GitLab fuori dal cluster, TLS ovunque, webhook al posto del polling," \
        "verifiche automatiche sugli Stage (AnalysisTemplate) prima di lasciar passare un Freight."
}

present() {
    # Sul palco un errore transitorio di kubectl o dell'API non deve chiudere la demo: ogni
    # capitolo controlla gli esiti che contano e avvisa, il resto prosegue.
    set +e
    trap cleanup EXIT
    title "GITOPS DAL VIVO [${PROVIDER}]"
    preflight
    start_access
    if (( DASHBOARD_ENABLED == 1 )); then
        palco_start "${SCRIPT_DIR}/docs/banco-regia.html"
        palco_set_creds gitlab "${GITLAB_URL}" root "${GITLAB_ROOT_PASSWORD}"
        palco_set_creds argocd "${ARGOCD_URL}" admin "${ARGOCD_PASSWORD}"
        palco_set_creds kargo "${KARGO_URL}" admin "${KARGO_ADMIN_PASSWORD}"
        palco_set_apps "${APP_PORTS[dev]:-}" "${APP_PORTS[staging]:-}" "${APP_PORTS[prod]:-}"
        palco_mode ready
        browser_open "$(palco_url)" || warn "Apri a mano il banco: $(palco_url)"
    fi
    print_access
    pause "si parte"

    local n
    local fns=(ch_mappa ch_appofapps ch_freight ch_promote ch_release ch_config ch_drift ch_rollback ch_debrief)
    for (( n = START; n <= ${#fns[@]}; n++ )); do
        "${fns[$(( n - 1 ))]}"
    done
    title "FINE"
    palco_mode end
    info "Per smontare tutto: $0 teardown --provider ${PROVIDER}"
    pause "chiudo banco e port-forward"
}

list_all() {
    local i id t m cmd
    echo ""
    echo "prepare (prima della sessione):"
    for (( i = 0; i < ${#PREP_STEPS[@]}; i++ )); do
        IFS='|' read -r t cmd m <<< "${PREP_STEPS[${i}]}"
        printf "  %d. %-55s %2s min\n" "$(( i + 1 ))" "${t}" "${m}"
    done
    echo ""
    echo "present (davanti al pubblico):"
    for (( i = 0; i < ${#CHAPTERS[@]}; i++ )); do
        IFS='|' read -r id t m <<< "${CHAPTERS[${i}]}"
        printf "  %d. %-55s %2s min\n" "$(( i + 1 ))" "${t}" "${m}"
    done
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        prepare|present|teardown) MODE="$1"; shift ;;
        --provider)     PROVIDER="${2:-}"; shift 2 ;;
        --provider=*)   PROVIDER="${1#*=}"; shift ;;
        --from)         START="${2:-1}"; shift 2 ;;
        --from=*)       START="${1#*=}"; shift ;;
        --list)         LIST_ONLY=1; shift ;;
        --no-dashboard) DASHBOARD_ENABLED=0; shift ;;
        --help|-h)      usage; exit 0 ;;
        *)              echo "Opzione sconosciuta: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if (( LIST_ONLY == 1 )); then
    list_all
    exit 0
fi

if [[ "${PROVIDER}" != "kind" && "${PROVIDER}" != "gke" ]]; then
    log_error "Provider non valido: '${PROVIDER}'. Usa kind o gke."
    exit 1
fi
export CLUSTER_PROVIDER="${PROVIDER}"

max=${#CHAPTERS[@]}
[[ "${MODE}" == "prepare" ]] && max=${#PREP_STEPS[@]}
if [[ ! "${START}" =~ ^[0-9]+$ ]] || (( START < 1 || START > max )); then
    log_error "--from accetta un numero da 1 a ${max} per ${MODE} (ricevuto: '${START}')"
    exit 1
fi

if [[ ! -t 0 ]]; then
    log_error "Serve un terminale interattivo."
    exit 1
fi

case "${MODE}" in
    prepare)  prepare ;;
    present)  present ;;
    teardown) "${DEPLOY}" --provider "${PROVIDER}" teardown ;;
esac
