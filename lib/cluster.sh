#!/usr/bin/env bash
# Purpose: GKE cluster create/delete/verify/credentials

cluster_exists() {
    gcloud container clusters describe "${GKE_CLUSTER_NAME}" \
        --project="${GKE_PROJECT_ID}" --zone="${GKE_ZONE}" &> /dev/null
}

cluster_status() {
    if cluster_exists; then
        gcloud container clusters describe "${GKE_CLUSTER_NAME}" \
            --project="${GKE_PROJECT_ID}" --zone="${GKE_ZONE}" --format='value(status)'
    else
        echo "NOT_FOUND"
    fi
}

cluster_get_credentials() {
    log_info "Getting GKE cluster credentials..."
    gcloud container clusters get-credentials "${GKE_CLUSTER_NAME}" \
        --project="${GKE_PROJECT_ID}" --zone="${GKE_ZONE}"
    log_success "GKE credentials configured"
}

cluster_create() {
    log_step "CLUSTER: Creating GKE cluster '${GKE_CLUSTER_NAME}'..."
    log_info "Project: ${GKE_PROJECT_ID} | Zone: ${GKE_ZONE} | Nodes: ${GKE_NUM_NODES}"

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

    log_info "Creating GKE cluster (10-15 minutes)..."
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

    log_success "GKE cluster created"
    cluster_get_credentials
}

cluster_delete() {
    log_step "CLUSTER: Deleting GKE cluster '${GKE_CLUSTER_NAME}'..."
    if cluster_exists; then
        gcloud container clusters delete "${GKE_CLUSTER_NAME}" \
            --project="${GKE_PROJECT_ID}" --zone="${GKE_ZONE}" --quiet
        log_success "GKE cluster deleted"
    else
        log_warn "GKE cluster does not exist"
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
    kubectl get nodes -o wide
    log_success "VERIFY: Cluster is healthy"
}
