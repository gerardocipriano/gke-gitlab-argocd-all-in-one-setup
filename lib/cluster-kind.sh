#!/usr/bin/env bash
# Purpose: kind cluster create/delete/verify

cluster_exists() {
    kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"
}

cluster_status() {
    if cluster_exists; then echo "RUNNING"; else echo "NOT_FOUND"; fi
}

cluster_create() {
    log_step "CLUSTER: Creating kind cluster '${KIND_CLUSTER_NAME}'..."

    if cluster_exists; then
        log_warn "Cluster '${KIND_CLUSTER_NAME}' already exists"
        read -r -p "Delete and recreate? [y/N]: " response
        if [[ "${response}" =~ ^[Yy]$ ]]; then
            cluster_delete
        else
            log_info "Using existing cluster"
            cluster_label_spot
            return 0
        fi
    fi

    cat << EOF | kind create cluster --name "${KIND_CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: ${GITLAB_LOCAL_PORT}
    protocol: TCP
  - containerPort: 30443
    hostPort: ${ARGOCD_LOCAL_PORT}
    protocol: TCP
  - containerPort: 30081
    hostPort: ${KARGO_LOCAL_PORT}
    protocol: TCP
EOF

    log_success "kind cluster '${KIND_CLUSTER_NAME}' created"
    cluster_label_spot
}

# I manifest della demo chiedono nodi Spot con il nodeSelector di GKE: su kind si mette la
# stessa etichetta ai nodi, cosi' gli stessi manifest girano su entrambi i provider.
cluster_label_spot() {
    kubectl label nodes --all cloud.google.com/gke-spot=true --overwrite >/dev/null
}

cluster_delete() {
    log_step "CLUSTER: Deleting kind cluster '${KIND_CLUSTER_NAME}'..."
    if cluster_exists; then
        kind delete cluster --name "${KIND_CLUSTER_NAME}"
        log_success "kind cluster deleted"
    else
        log_warn "kind cluster does not exist"
    fi
}

cluster_verify() {
    log_step "VERIFY: Checking cluster health..."
    kubectl cluster-info --context "kind-${KIND_CLUSTER_NAME}"
    kubectl get nodes -o wide
    log_success "VERIFY: Cluster is healthy"
}

cluster_info_label() {
    echo "kind (${KIND_CLUSTER_NAME})"
}

# Su kind non serve spostare niente: i nodi hanno gia' l'etichetta Spot.
cluster_schedule_spot() {
    :
}
