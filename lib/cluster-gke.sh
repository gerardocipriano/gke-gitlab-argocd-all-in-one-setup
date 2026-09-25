#!/usr/bin/env bash
# Purpose: GKE Autopilot cluster create/delete/verify

cluster_exists() {
    gcloud container clusters describe "${GKE_CLUSTER_NAME}" \
        --project="${GKE_PROJECT_ID}" --region="${GKE_REGION}" &> /dev/null
}

cluster_status() {
    if cluster_exists; then
        gcloud container clusters describe "${GKE_CLUSTER_NAME}" \
            --project="${GKE_PROJECT_ID}" --region="${GKE_REGION}" --format='value(status)'
    else
        echo "NOT_FOUND"
    fi
}

cluster_get_credentials() {
    log_info "Getting GKE cluster credentials..."
    # Il control plane è raggiungibile solo via DNS endpoint: niente IP pubblico da
    # autorizzare, l'accesso passa da IAM (ruolo container.developer o superiore).
    gcloud container clusters get-credentials "${GKE_CLUSTER_NAME}" \
        --project="${GKE_PROJECT_ID}" --region="${GKE_REGION}" --dns-endpoint
    log_success "GKE credentials configured"
}

cluster_create() {
    log_step "CLUSTER: Creating GKE Autopilot cluster '${GKE_CLUSTER_NAME}'..."
    log_info "Project: ${GKE_PROJECT_ID} | Region: ${GKE_REGION}"

    if cluster_exists; then
        local status
        status=$(cluster_status)
        log_warn "Cluster already exists | status=${status}"
        read -r -p "Delete and recreate? [y/N]: " response
        if [[ "${response}" =~ ^[Yy]$ ]]; then
            cluster_delete
        else
            log_info "Using existing cluster"
            cluster_get_credentials
            return 0
        fi
    fi

    local private_nodes_flag="--no-enable-private-nodes"
    [[ "${GKE_PRIVATE_NODES}" == "true" ]] && private_nodes_flag="--enable-private-nodes"

    log_info "Creating GKE Autopilot cluster (10-15 minutes)..."
    # monitoring/logging ridotti a SYSTEM: taglia i sample kube-state, cAdvisor e
    # kubelet e i log dei workload. Managed Prometheus e Dataplane V2 observability
    # non sono disabilitabili su Autopilot e restano ai default.
    gcloud container clusters create-auto "${GKE_CLUSTER_NAME}" \
        --project "${GKE_PROJECT_ID}" \
        --region "${GKE_REGION}" \
        --release-channel "regular" \
        --service-account "${GKE_SERVICE_ACCOUNT}" \
        --network "projects/${GKE_PROJECT_ID}/global/networks/${GKE_NETWORK}" \
        --subnetwork "projects/${GKE_PROJECT_ID}/regions/${GKE_REGION}/subnetworks/${GKE_SUBNETWORK}" \
        --cluster-secondary-range-name "pods" \
        --services-secondary-range-name "svc" \
        --logging=SYSTEM \
        --monitoring=SYSTEM \
        "${private_nodes_flag}" \
        --enable-dns-access \
        --no-enable-google-cloud-access \
        --quiet

    log_success "GKE Autopilot cluster created"
    cluster_get_credentials
}

# Su Autopilot lo Spot non è un'opzione di cluster: va chiesto dai singoli pod.
# I workload arrivano da manifest upstream e chart Helm che non espongono un
# nodeSelector, quindi si patcha il pod template dopo l'installazione.
cluster_schedule_spot() {
    local namespace="$1"
    local patch='{"spec":{"template":{"spec":{"nodeSelector":{"cloud.google.com/gke-spot":"true"}}}}}'

    log_info "Moving workloads in namespace '${namespace}' to Spot nodes..."
    local kind
    for kind in deployment statefulset daemonset cronjob; do
        local names
        names=$(kubectl get "${kind}" -n "${namespace}" -o name 2>/dev/null) || continue
        [[ -z "${names}" ]] && continue
        local obj
        while IFS= read -r obj; do
            local p="${patch}"
            # Nei CronJob il pod template sta sotto jobTemplate.
            [[ "${obj}" == cronjob* ]] && p='{"spec":{"jobTemplate":{"spec":{"template":{"spec":{"nodeSelector":{"cloud.google.com/gke-spot":"true"}}}}}}}'
            kubectl patch "${obj}" -n "${namespace}" --type=strategic -p "${p}" &> /dev/null \
                || log_warn "Spot patch failed: ${namespace}/${obj}"
        done <<< "${names}"
    done
    log_success "Spot scheduling applied to '${namespace}'"
}

# Il PD di un PVC viene cancellato dal driver CSI, che smette di esistere con il cluster:
# senza questa attesa i dischi di GitLab restano orfani e a pagamento.
cluster_release_disks() {
    kubectl get pvc -A --no-headers 2>/dev/null | grep -q . || return 0
    log_info "Releasing persistent disks before deleting the cluster..."
    kubectl delete pvc --all -A --wait=false >/dev/null 2>&1 || true
    local elapsed=0
    while (( elapsed < 240 )); do
        [[ -z "$(kubectl get pv --no-headers 2>/dev/null)" ]] && { log_success "Persistent disks released"; return 0; }
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done
    log_warn "Some PVs are still present: check the disks after deletion"
}

cluster_delete() {
    log_step "CLUSTER: Deleting GKE cluster '${GKE_CLUSTER_NAME}'..."
    if cluster_exists; then
        cluster_get_credentials >/dev/null 2>&1 && cluster_release_disks
        gcloud container clusters delete "${GKE_CLUSTER_NAME}" \
            --project="${GKE_PROJECT_ID}" --region="${GKE_REGION}" --quiet
        log_success "GKE cluster deleted"
        cluster_report_orphan_disks
    else
        log_warn "GKE cluster does not exist"
    fi
}

# I PD dei PVC sopravvivono al cluster se il namespace non è stato cancellato prima.
# Si elencano e basta: cancellarli è una scelta di chi li vede.
cluster_report_orphan_disks() {
    local disks
    disks=$(gcloud compute disks list --project="${GKE_PROJECT_ID}" \
        --filter="name~^pvc- AND -users:*" --format="value(name,zone.basename())" 2>/dev/null || true)
    if [[ -n "${disks}" ]]; then
        log_warn "Dischi PVC non più agganciati (costano finché esistono):"
        printf '  %s\n' "${disks}" >&2
        log_warn "Per cancellarli: gcloud compute disks delete NOME --zone ZONA --project ${GKE_PROJECT_ID}"
    else
        log_success "Nessun disco PVC orfano nel progetto"
    fi
}

cluster_verify() {
    log_step "VERIFY: Checking cluster health..."
    local max_attempts=30
    local attempt=0
    while [[ ${attempt} -lt ${max_attempts} ]]; do
        local status
        status=$(cluster_status)
        if [[ "${status}" == "RUNNING" ]]; then
            log_success "Cluster is RUNNING"
            break
        fi
        attempt=$((attempt + 1))
        log_info "Waiting... (${attempt}/${max_attempts}, status: ${status})"
        sleep 10
    done
    if [[ ${attempt} -eq ${max_attempts} ]]; then
        log_error "Cluster did not become ready"
        return 1
    fi
    kubectl cluster-info
    # Autopilot provisiona i nodi on demand: a cluster vuoto la lista è vuota.
    kubectl get nodes -o wide
    log_success "VERIFY: Cluster is healthy"
}

cluster_info_label() {
    echo "GKE Autopilot (${GKE_PROJECT_ID}/${GKE_CLUSTER_NAME})"
}
