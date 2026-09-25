#!/usr/bin/env bash
# Purpose: banco di regia della demo (server locale, state.json, collector live.json) e
# helper per pilotare Kargo e GitLab dal terminale di chi presenta.

PALCO_DIR=""
PALCO_PORT=""
PALCO_PIDS=()

# Stato del banco: demo.sh aggiorna questi campi e palco_write li scrive in state.json.
# mode: prepare | ready | present | end
PALCO_MODE="present"
PALCO_CHAPTER=""
PALCO_PHASE="intro"
PALCO_QUESTION=0
PALCO_NOTE=""
PALCO_NEXT=""
PALCO_NOTES='[]'
PALCO_CREDS='{}'
PALCO_PREP='[]'
PALCO_APPS='{}'
PALCO_PROMPT_ID=0
PALCO_PROMPT_U=false
PALCO_TOKEN=""

# Server del banco: file statici più POST /cmd, con cui i pulsanti del banco premono Invio al
# posto del terminale. Ascolta solo su 127.0.0.1; il token e il controllo dell'Origin impediscono
# a un'altra pagina aperta nel browser di comandare la demo.
readonly PALCO_SERVER_PY='
import http.server, json, os, sys
root, port, token = sys.argv[1], int(sys.argv[2]), sys.argv[3]
allowed = {"http://127.0.0.1:%d" % port, "http://localhost:%d" % port}

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=root, **k)

    def log_message(self, *a):
        pass

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_POST(self):
        if self.path != "/cmd":
            return self.send_error(404)
        if self.headers.get("Origin", "") not in allowed:
            return self.send_error(403)
        size = int(self.headers.get("Content-Length") or 0)
        if size > 1024:
            return self.send_error(413)
        try:
            body = json.loads(self.rfile.read(size))
            prompt = int(body.get("prompt", 0))
        except Exception:
            return self.send_error(400)
        if body.get("token") != token:
            return self.send_error(403)
        if body.get("key") not in ("enter", "u", "q"):
            return self.send_error(403)
        tmp = os.path.join(root, "cmd.tmp")
        with open(tmp, "w") as f:
            f.write("%d %s\n" % (prompt, body["key"]))
        os.replace(tmp, os.path.join(root, "cmd"))
        self.send_response(204)
        self.end_headers()

http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
'

# ---------------------------------------------------------------------------
# Server e stato
# ---------------------------------------------------------------------------

# Cartella privata: state.json contiene le credenziali delle UI, e il server ascolta solo
# su 127.0.0.1.
palco_start() {
    local template="$1"
    PALCO_DIR=$(mktemp -d "${TMPDIR:-/tmp}/palco-XXXXXX")
    chmod 700 "${PALCO_DIR}"
    cp "${template}" "${PALCO_DIR}/index.html"
    palco_declared_replicas > "${PALCO_DIR}/declared.json"
    echo '{}' > "${PALCO_DIR}/live.json"
    echo '{}' > "${PALCO_DIR}/apps.json"

    PALCO_PORT=$(find_free_port "${PALCO_LOCAL_PORT:-8090}") || return 1
    PALCO_TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
    python3 -c "${PALCO_SERVER_PY}" "${PALCO_DIR}" "${PALCO_PORT}" "${PALCO_TOKEN}" \
        > "${PALCO_DIR}/server.log" 2>&1 &
    PALCO_PIDS+=($!)

    palco_collector_loop &
    PALCO_PIDS+=($!)
}

palco_stop() {
    local pid
    for pid in "${PALCO_PIDS[@]+"${PALCO_PIDS[@]}"}"; do
        kill "${pid}" 2>/dev/null || true
    done
    PALCO_PIDS=()
    [[ -n "${PALCO_DIR}" && -d "${PALCO_DIR}" ]] && rm -rf "${PALCO_DIR}"
}

palco_url() {
    echo "http://127.0.0.1:${PALCO_PORT}/"
}

# Scrittura atomica: il browser non deve mai leggere un JSON a metà.
palco_write() {
    [[ -n "${PALCO_DIR}" && -d "${PALCO_DIR}" ]] || return 0
    jq -n --arg mode "${PALCO_MODE}" --arg c "${PALCO_CHAPTER}" --arg p "${PALCO_PHASE}" \
        --argjson q "${PALCO_QUESTION}" --arg n "${PALCO_NOTE}" --arg next "${PALCO_NEXT}" \
        --argjson notes "${PALCO_NOTES}" --argjson creds "${PALCO_CREDS}" --argjson prep "${PALCO_PREP}" \
        --arg prov "${PROVIDER:-}" --argjson pid "${PALCO_PROMPT_ID}" --argjson pu "${PALCO_PROMPT_U}" \
        --arg tok "${PALCO_TOKEN}" --argjson apps "${PALCO_APPS}" \
        '{mode: $mode, chapter: $c, phase: $p, question: $q, note: $n, next: $next, notes: $notes,
          creds: $creds, urls: ($creds | map_values(.url)), prep: $prep, provider: $prov,
          prompt: {id: $pid, u: $pu}, token: $tok, apps: $apps, updated: now}' \
        > "${PALCO_DIR}/state.json.tmp" && mv "${PALCO_DIR}/state.json.tmp" "${PALCO_DIR}/state.json"
}

palco_mode() { PALCO_MODE="$1"; palco_write; }

# Uso: palco_state CAPITOLO FASE [INDICE_DOMANDA] [NOTA]
palco_state() {
    PALCO_MODE="present"
    PALCO_CHAPTER="$1"
    PALCO_PHASE="$2"
    PALCO_QUESTION="${3:-0}"
    PALCO_NOTE="${4:-}"
    palco_write
}

palco_note() { PALCO_NOTE="$1"; palco_write; }

# Il prossimo gesto di chi presenta, mostrato nella barra "Prossimo passo" del banco.
palco_next() { PALCO_NEXT="$1"; palco_write; }

# Apre un nuovo prompt: il banco può rispondere solo a questo id, così un doppio clic o
# un comando arrivato in ritardo non fa avanzare due passi.
palco_prompt_open() {
    PALCO_PROMPT_ID=$(( PALCO_PROMPT_ID + 1 ))
    [[ "$1" == *"scrivi u"* ]] && PALCO_PROMPT_U=true || PALCO_PROMPT_U=false
    rm -f "${PALCO_DIR}/cmd" 2>/dev/null
    PALCO_NEXT="$1"
    palco_write
}

palco_prompt_close() { PALCO_NEXT=""; PALCO_PROMPT_U=false; palco_write; }

# Stampa il tasto premuto dal banco per il prompt corrente (enter, u, q) e consuma il comando.
palco_take_cmd() {
    local f="${PALCO_DIR}/cmd" id key
    [[ -n "${PALCO_DIR}" && -f "${f}" ]] || return 1
    read -r id key < "${f}" || true
    rm -f "${f}"
    [[ "${id}" == "${PALCO_PROMPT_ID}" ]] || return 1
    echo "${key}"
}

palco_notes_reset() { PALCO_NOTES='[]'; }

palco_notes_add() {
    PALCO_NOTES=$(jq -c --arg l "$1" '. + [$l]' <<< "${PALCO_NOTES}")
    palco_write
}

# Uso: palco_set_creds NOME URL UTENTE PASSWORD  (una chiamata per UI)
palco_set_creds() {
    PALCO_CREDS=$(jq -c --arg k "$1" --arg u "$2" --arg user "$3" --arg pw "$4" \
        '. + {($k): {url: $u, user: $user, password: $pw}}' <<< "${PALCO_CREDS}")
    palco_write
}

# Porte locali delle app dei tre stage. Il collector gira in un processo già avviato, quindi
# le legge da file a ogni giro.
palco_set_apps() {
    [[ -n "${PALCO_DIR}" ]] || return 0
    jq -n --arg d "$1" --arg s "$2" --arg p "$3" '{dev: $d, staging: $s, prod: $p}' > "${PALCO_DIR}/apps.json"
    PALCO_APPS=$(jq -c 'map_values(if . == "" then "" else "http://localhost:" + . end)' "${PALCO_DIR}/apps.json")
    palco_write
}

# Uso: palco_set_prep JSON  (array di {title, minutes, status, started})
palco_set_prep() { PALCO_PREP="$1"; palco_write; }

# Repliche dichiarate negli overlay: servono alla dashboard per colorare quelle in eccesso
# quando qualcuno scala a mano.
palco_declared_replicas() {
    local stage count json='{}'
    for stage in dev staging prod; do
        count=$(awk '/count:/ {print $2; exit}' \
            "${SCRIPT_DIR}/repos/${KARGO_PROJECT}/app/stages/${stage}/kustomization.yaml" 2>/dev/null)
        json=$(jq -c --arg s "${stage}" --argjson n "${count:-0}" '. + {($s): $n}' <<< "${json}")
    done
    echo "${json}"
}

# ---------------------------------------------------------------------------
# Collector
# ---------------------------------------------------------------------------

# Namespace mostrati nella vista Cluster, nell'ordine in cui compaiono.
PALCO_NAMESPACES='["gitlab","argocd","kargo","cert-manager","kargo-demo","kargo-demo-dev","kargo-demo-staging","kargo-demo-prod","nginx"]'

readonly PALCO_JQ='
($k[0].items // []) as $all
| ($all | map(select(.kind == "Freight"))) as $fr
| ($fr | map({key: .metadata.name, value: .}) | from_entries) as $fm
| ($all | map(select(.kind == "Warehouse")) | .[0] // {}) as $wh
| ($all | map(select(.kind == "ProjectConfig")) | .[0].spec.promotionPolicies // []) as $pp
| ($a[0].items // [] | map({key: .metadata.name, value: .}) | from_entries) as $am
| ($d[0].items // [] | map({key: .metadata.namespace, value: .}) | from_entries) as $dm
| {
    ts: (now | todate),
    warehouse: {
      name: ($wh.metadata.name // ""),
      constraint: ($wh.spec.subscriptions[0].image.constraint // ""),
      freight: ($fr | sort_by(.metadata.creationTimestamp) | reverse
        | map({name: .metadata.name, alias: (.alias // ""), tag: (.images[0].tag // ""),
               commit: ((.commits[0].id // "")[0:7]), created: .metadata.creationTimestamp}))
    },
    stages: (["dev", "staging", "prod"] | map(. as $s
      | ($all | map(select(.kind == "Stage" and .metadata.name == $s)) | .[0] // {}) as $st
      | (($st.status.freightHistory // [])[0].items // {} | to_entries | .[0].value.name // "") as $fn
      | ($am["kargo-demo-" + $s] // {}) as $app
      | ($dm["kargo-demo-" + $s] // {}) as $dep
      | {
          name: $s,
          freight: ($fm[$fn].alias // ""),
          tag: ($fm[$fn].images[0].tag // ""),
          config: (($fm[$fn].commits[0].id // "")[0:7]),
          app: ($appv[0][$s] // null),
          health: ($st.status.health.status // ""),
          ready: ($dep.status.readyReplicas // 0),
          desired: ($dep.spec.replicas // 0),
          declared: ($decl[0][$s] // 0),
          sync: ($app.status.sync.status // ""),
          appHealth: ($app.status.health.status // ""),
          commit: (($app.status.sync.revision // "")[0:7]),
          auto: ([$pp[] | select(.stage == $s and .autoPromotionEnabled == true)] | length > 0),
          selfHeal: ($app.spec.syncPolicy.automated.selfHeal // false)
        })),
    promotions: ($all | map(select(.kind == "Promotion")) | sort_by(.metadata.creationTimestamp) | reverse | .[0:4]
      | map({name: .metadata.name, stage: .spec.stage,
             freight: ($fm[.spec.freight].alias // (.spec.freight // "")[0:7]),
             phase: (.status.phase // "Pending"), created: .metadata.creationTimestamp})),
    cluster: {
      nodes: ($n[0].items // [] | map({
        name: (.metadata.name | sub("^gk3-[^-]+-[^-]+-[0-9]+-"; "")),
        type: (.metadata.labels["node.kubernetes.io/instance-type"] // ""),
        spot: (.metadata.labels["cloud.google.com/gke-spot"] == "true"),
        ready: ([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length > 0)
      })),
      namespaces: ($nsl | map(. as $ns | {
        name: $ns,
        pods: ($p[0].items // [] | map(select(.metadata.namespace == $ns and .status.phase != "Succeeded")) | map({
          name: .metadata.name,
          workload: (.metadata.labels["app.kubernetes.io/name"] // .metadata.labels.app // (.metadata.name
            | sub("-[a-z0-9]{8,10}-[a-z0-9]{5}$"; "") | sub("-[a-z0-9]{5}$"; "") | sub("-[0-9]+$"; ""))),
          status: (if .metadata.deletionTimestamp then "deleting"
                   elif ([.status.containerStatuses[]?.state.waiting.reason // empty]
                         | any(test("CrashLoop|ImagePull|ErrImage|Error"))) or .status.phase == "Failed" then "failed"
                   elif .status.phase == "Running" and ([.status.containerStatuses[]? | .ready] | all) then "ready"
                   else "starting" end),
          restarts: ([.status.containerStatuses[]?.restartCount] | add // 0)
        }) | sort_by(.workload, .name))
      })),
      kargo: {
        warehouses: ($all | map(select(.kind == "Warehouse")) | length),
        stages: ($all | map(select(.kind == "Stage")) | length),
        freight: ($fr | length),
        promotions: ($all | map(select(.kind == "Promotion")) | length)
      },
      applications: ($a[0].items // [] | length)
    },
    events: ($e[0].items // [] | map(select(.metadata.namespace | startswith("kargo-demo-")))
      | sort_by(.lastTimestamp // .eventTime // "") | .[-5:]
      | map((((.lastTimestamp // .eventTime // "") | sub("\\.[0-9]+"; "") | try (fromdateiso8601 | strflocaltime("%H:%M:%S")) catch "")) + " "
            + (.metadata.namespace | ltrimstr("kargo-demo-")) + "  " + .message))
  }'

palco_collect_once() {
    local d="${PALCO_DIR}"
    kubectl get stages,freight,promotions,warehouses,projectconfigs -n "${KARGO_PROJECT}" -o json \
        > "${d}/k.json" 2>/dev/null || echo '{}' > "${d}/k.json"
    kubectl get applications -n "${ARGOCD_NAMESPACE}" -o json > "${d}/a.json" 2>/dev/null || echo '{}' > "${d}/a.json"
    kubectl get deployments -A -l kargo.akuity.io/stage -o json > "${d}/d.json" 2>/dev/null || echo '{}' > "${d}/d.json"
    kubectl get events -A --field-selector reason=ScalingReplicaSet -o json > "${d}/e.json" 2>/dev/null || echo '{}' > "${d}/e.json"
    kubectl get nodes -o json > "${d}/n.json" 2>/dev/null || echo '{}' > "${d}/n.json"
    kubectl get pods -A -o json > "${d}/p.json" 2>/dev/null || echo '{}' > "${d}/p.json"
    local s port av='{}' resp
    for s in dev staging prod; do
        port=$(jq -r --arg s "${s}" '.[$s] // ""' "${d}/apps.json" 2>/dev/null)
        [[ -n "${port}" ]] || continue
        resp=$(curl -s -m 2 "http://127.0.0.1:${port}/" 2>/dev/null | jq -c '{version, message}' 2>/dev/null) || resp=""
        [[ -n "${resp}" ]] && av=$(jq -c --arg s "${s}" --argjson r "${resp}" '. + {($s): $r}' <<< "${av}")
    done
    echo "${av}" > "${d}/appv.json"
    jq -n --slurpfile k "${d}/k.json" --slurpfile a "${d}/a.json" --slurpfile d "${d}/d.json" \
        --slurpfile e "${d}/e.json" --slurpfile decl "${d}/declared.json" \
        --slurpfile n "${d}/n.json" --slurpfile p "${d}/p.json" --slurpfile appv "${d}/appv.json" \
        --argjson nsl "${PALCO_NAMESPACES}" "${PALCO_JQ}" \
        > "${d}/live.json.tmp" 2>/dev/null && mv "${d}/live.json.tmp" "${d}/live.json"
}

# Termina da solo se demo.sh muore senza passare dal trap (kill -9, terminale chiuso).
palco_collector_loop() {
    local parent=$$
    while kill -0 "${parent}" 2>/dev/null && [[ -d "${PALCO_DIR}" ]]; do
        palco_collect_once
        sleep 3
    done
}

# ---------------------------------------------------------------------------
# Port-forward sorvegliati
# ---------------------------------------------------------------------------

PF_PIDS=()

# kubectl port-forward verso il DNS endpoint di GKE si blocca dopo qualche minuto senza
# uscire ("error creating error stream ... Timeout occurred"): il processo resta vivo e la
# porta smette di rispondere. Il supervisore prova la porta ogni 5s e lo riavvia.
pf_supervise() {
    local namespace="$1" service="$2" remote_port="$3" local_port="$4" scheme="$5"
    local parent=$$ pid="" fails
    local log="${PF_LOG_DIR:-${TMPDIR:-/tmp}}/pf-${service}.log"
    trap '[[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null; exit 0' TERM INT
    while kill -0 "${parent}" 2>/dev/null; do
        kubectl port-forward -n "${namespace}" "svc/${service}" "${local_port}:${remote_port}" >> "${log}" 2>&1 &
        pid=$!
        sleep 3
        fails=0
        while kill -0 "${pid}" 2>/dev/null && kill -0 "${parent}" 2>/dev/null; do
            if curl -sk -m 4 -o /dev/null "${scheme}://127.0.0.1:${local_port}/"; then
                fails=0
            else
                fails=$(( fails + 1 ))
            fi
            (( fails >= 2 )) && break
            sleep 5
        done
        kill "${pid}" 2>/dev/null
        wait "${pid}" 2>/dev/null
        echo "$(date '+%H:%M:%S') supervisore: riavvio port-forward ${service}" >> "${log}"
    done
}

# Uso: pf_start NAMESPACE SERVIZIO PORTA_REMOTA PORTA_PREFERITA SCHEMA
# Stampa la porta locale scelta; il supervisore resta in background fino all'uscita di demo.sh.
pf_start() {
    local port
    port=$(find_free_port "$4") || return 1
    pf_supervise "$1" "$2" "$3" "${port}" "$5" &
    PF_PIDS+=($!)
    PF_LAST_PORT="${port}"
}

pf_wait_ready() {
    local url="$1" i
    for i in $(seq 1 20); do
        curl -sk -m 3 -o /dev/null "${url}" && return 0
        sleep 1
    done
    return 1
}

pf_stop() {
    local pid
    for pid in "${PF_PIDS[@]+"${PF_PIDS[@]}"}"; do
        kill "${pid}" 2>/dev/null || true
    done
    PF_PIDS=()
}

# ---------------------------------------------------------------------------
# Kargo via API
# ---------------------------------------------------------------------------

# La CLI kargo chiede la password admin solo in modo interattivo: sul palco si usa l'API
# Connect che sta dietro alla UI, con lo stesso login admin.
KARGO_API_URL=""
KARGO_TOKEN=""

kargo_api_login() {
    KARGO_API_URL="$1/akuity.io.kargo.service.v1alpha1.KargoService"
    KARGO_TOKEN=$(curl -sk -m 15 -X POST "${KARGO_API_URL}/AdminLogin" -H 'Content-Type: application/json' \
        -d "$(jq -cn --arg p "${KARGO_ADMIN_PASSWORD}" '{password: $p}')" | jq -r '.idToken // empty')
    [[ -n "${KARGO_TOKEN}" ]]
}

# Stampa il nome della Promotion creata, oppure il messaggio d'errore dell'API e rende 1.
kargo_promote() {
    local stage="$1" freight="$2" resp
    resp=$(curl -sk -m 20 --retry 2 --retry-all-errors -X POST "${KARGO_API_URL}/PromoteToStage" \
        -H "Authorization: Bearer ${KARGO_TOKEN}" -H 'Content-Type: application/json' \
        -d "$(jq -cn --arg p "${KARGO_PROJECT}" --arg s "${stage}" --arg f "${freight}" \
            '{project: $p, stage: $s, freight: $f}')")
    if jq -e '.promotion.metadata.name' <<< "${resp}" >/dev/null 2>&1; then
        jq -r '.promotion.metadata.name' <<< "${resp}"
        return 0
    fi
    jq -r '.message // "risposta vuota dall API di Kargo"' <<< "${resp}" 2>/dev/null || echo "${resp}"
    return 1
}

kargo_stage_freight() {
    kubectl get stage "$1" -n "${KARGO_PROJECT}" -o json 2>/dev/null |
        jq -r '(.status.freightHistory // [])[0].items // {} | to_entries | .[0].value.name // empty'
}

kargo_freight_alias() {
    kubectl get freight "$1" -n "${KARGO_PROJECT}" -o jsonpath='{.alias}' 2>/dev/null
}

kargo_freight_tag() {
    kubectl get freight "$1" -n "${KARGO_PROJECT}" -o jsonpath='{.images[0].tag}' 2>/dev/null
}

# Freight dal più recente al più vecchio, un nome per riga.
kargo_freight_by_age() {
    kubectl get freight -n "${KARGO_PROJECT}" -o json 2>/dev/null |
        jq -r '.items | sort_by(.metadata.creationTimestamp) | reverse | .[].metadata.name'
}

# Attende che lo Stage abbia il Freight indicato e sia Healthy. Timeout in secondi.
# Subito dopo il sync chiesto da Kargo, ArgoCD confronta il cluster con la HEAD del branch
# che ha in cache, ancora quella di prima: senza refresh l'app resta OutOfSync fino al
# polling successivo (3 minuti) e sul palco sembra un errore.
kargo_wait_stage() {
    local stage="$1" freight="$2" timeout="${3:-180}" elapsed=0 health
    while (( elapsed < timeout )); do
        health=$(kubectl get stage "${stage}" -n "${KARGO_PROJECT}" -o jsonpath='{.status.health.status}' 2>/dev/null)
        if [[ "$(kargo_stage_freight "${stage}")" == "${freight}" && "${health}" == "Healthy" ]]; then
            kubectl annotate application "kargo-demo-${stage}" -n "${ARGOCD_NAMESPACE}" \
                argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1
            sleep 3
            return 0
        fi
        sleep 3
        elapsed=$(( elapsed + 3 ))
    done
    return 1
}
