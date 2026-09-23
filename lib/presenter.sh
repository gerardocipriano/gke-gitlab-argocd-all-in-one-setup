#!/usr/bin/env bash
# Purpose: banco di regia della demo (server locale, state.json, collector live.json) e
# helper per pilotare Kargo e GitLab dal terminale di chi presenta.

PALCO_DIR=""
PALCO_PORT=""
PALCO_PIDS=()
PALCO_URLS='{}'

# ---------------------------------------------------------------------------
# Server e stato
# ---------------------------------------------------------------------------

# Cartella privata: state.json contiene gli URL locali, e l'HTML resta servito solo su
# 127.0.0.1.
palco_start() {
    local template="$1"
    PALCO_DIR=$(mktemp -d "${TMPDIR:-/tmp}/palco-XXXXXX")
    chmod 700 "${PALCO_DIR}"
    cp "${template}" "${PALCO_DIR}/index.html"
    palco_declared_replicas > "${PALCO_DIR}/declared.json"
    echo '{}' > "${PALCO_DIR}/live.json"

    PALCO_PORT=$(find_free_port "${PALCO_LOCAL_PORT:-8090}") || return 1
    python3 -m http.server "${PALCO_PORT}" --bind 127.0.0.1 --directory "${PALCO_DIR}" \
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

palco_set_urls() {
    PALCO_URLS=$(jq -cn --arg g "$1" --arg a "$2" --arg k "$3" '{gitlab: $g, argocd: $a, kargo: $k}')
}

# Uso: palco_state CAPITOLO FASE [INDICE_DOMANDA] [NOTA]
# Scrittura atomica: il browser non deve mai leggere un JSON a meta'.
palco_state() {
    [[ -n "${PALCO_DIR}" ]] || return 0
    local chapter="$1" phase="$2" question="${3:-0}" note="${4:-}"
    jq -n --arg c "${chapter}" --arg p "${phase}" --argjson q "${question}" --arg n "${note}" \
        --arg prov "${PROVIDER:-}" --argjson urls "${PALCO_URLS}" \
        '{chapter: $c, phase: $p, question: $q, note: $n, provider: $prov, urls: $urls, updated: now}' \
        > "${PALCO_DIR}/state.json.tmp" && mv "${PALCO_DIR}/state.json.tmp" "${PALCO_DIR}/state.json"
}

palco_note() {
    [[ -n "${PALCO_DIR}" && -f "${PALCO_DIR}/state.json" ]] || return 0
    jq --arg n "$1" '.note = $n | .updated = now' "${PALCO_DIR}/state.json" \
        > "${PALCO_DIR}/state.json.tmp" && mv "${PALCO_DIR}/state.json.tmp" "${PALCO_DIR}/state.json"
}

# Repliche dichiarate negli overlay: servono alla dashboard per colorare quelle in eccesso
# quando qualcuno scala a mano.
palco_declared_replicas() {
    local stage count json='{}'
    for stage in dev staging prod; do
        count=$(awk '/count:/ {print $2; exit}' \
            "${SCRIPT_DIR}/manifests/kargo-demo/stages/${stage}/kustomization.yaml" 2>/dev/null)
        json=$(jq -c --arg s "${stage}" --argjson n "${count:-0}" '. + {($s): $n}' <<< "${json}")
    done
    echo "${json}"
}

# ---------------------------------------------------------------------------
# Collector
# ---------------------------------------------------------------------------

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
        | map({name: .metadata.name, alias: (.alias // ""), tag: (.images[0].tag // ""), created: .metadata.creationTimestamp}))
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
    jq -n --slurpfile k "${d}/k.json" --slurpfile a "${d}/a.json" --slurpfile d "${d}/d.json" \
        --slurpfile e "${d}/e.json" --slurpfile decl "${d}/declared.json" "${PALCO_JQ}" \
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

# Freight dal piu' recente al piu' vecchio, un nome per riga.
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

# ---------------------------------------------------------------------------
# GitLab via API, dall'interno del pod
# ---------------------------------------------------------------------------

gitlab_api() {
    local method="$1" path="$2" data="${3:-}"
    local pod pat
    pod=$(gitlab_get_pod)
    pat=$(gitlab_get_pat)
    if [[ -n "${data}" ]]; then
        printf '%s' "${data}" | kubectl exec -i -n "${GITLAB_NAMESPACE}" "${pod}" -- \
            curl -sf -X "${method}" -H "PRIVATE-TOKEN: ${pat}" -H 'Content-Type: application/json' \
            --data @- "http://localhost:80/api/v4${path}"
    else
        kubectl exec -n "${GITLAB_NAMESPACE}" "${pod}" -- \
            curl -sf -X "${method}" -H "PRIVATE-TOKEN: ${pat}" "http://localhost:80/api/v4${path}"
    fi
}

gitlab_file_raw() {
    local file="$1" ref="$2"
    gitlab_api GET "/projects/root%2Fgitops/repository/files/$(jq -rn --arg f "${file}" '$f|@uri')/raw?ref=$(jq -rn --arg r "${ref}" '$r|@uri')"
}

# Uso: gitlab_commit_file FILE CONTENUTO MESSAGGIO  (su main). Stampa lo short id.
gitlab_commit_file() {
    local file="$1" content="$2" message="$3"
    gitlab_api POST "/projects/root%2Fgitops/repository/commits" \
        "$(jq -cn --arg f "${file}" --arg c "${content}" --arg m "${message}" \
            '{branch: "main", commit_message: $m, actions: [{action: "update", file_path: $f, content: $c}]}')" |
        jq -r '.short_id // empty'
}

gitlab_last_commit() {
    gitlab_api GET "/projects/root%2Fgitops/repository/commits?ref_name=$(jq -rn --arg r "$1" '$r|@uri')&per_page=1" |
        jq -r '.[0] | "\(.short_id)  \(.author_name) <\(.author_email)>  \(.title)"'
}
