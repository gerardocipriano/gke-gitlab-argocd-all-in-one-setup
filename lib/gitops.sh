#!/usr/bin/env bash
# Purpose: initialize gitops repository in GitLab with all manifests for App of Apps pattern
# Automatically discovers all files under manifests/ and gitops-inventory/inventory/

gitops_create_repository() {
    log_step "GITOPS: Creating gitops repository in GitLab..."

    local gitlab_pod
    gitlab_pod=$(gitlab_get_pod)
    if [[ -z "${gitlab_pod}" ]]; then
        log_error "GitLab pod not found"
        return 1
    fi

    local pat
    pat=$(gitlab_get_pat)
    if [[ -z "${pat}" ]]; then
        log_error "GitLab PAT not found. Run 'gitlab' command first."
        return 1
    fi

    gitlab_wait_for_api "${pat}" || return 1
    gitops_create_project "${gitlab_pod}" "${pat}"
    gitops_create_content_configmap
    gitops_push_via_job

    log_success "GITOPS: Repository initialized with all manifests"
}

gitops_create_project() {
    local gitlab_pod="$1"
    local pat="$2"

    log_info "Creating 'gitops' project via API..."
    local resp
    resp=$(kubectl exec -n "${GITLAB_NAMESPACE}" "${gitlab_pod}" -- \
        curl -sf -X POST \
            -H "PRIVATE-TOKEN: ${pat}" \
            -H "Content-Type: application/json" \
            "http://localhost:80/api/v4/projects" \
            -d '{"name": "gitops", "visibility": "private", "initialize_with_readme": false}' \
            2>/dev/null || echo "")

    if echo "${resp}" | grep -q '"path":"gitops"'; then
        log_success "GitOps project created"
    elif echo "${resp}" | grep -q "already been taken\|already exists"; then
        log_info "GitOps project already exists"
    else
        log_warn "Project creation response: ${resp:-empty}"
    fi
}

gitops_create_content_configmap() {
    log_info "Packing gitops content into ConfigMap..."

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local repo_root="${tmp_dir}/repo"
    mkdir -p "${repo_root}/inventory"

    # Purpose: auto-discover all manifest dirs under manifests/ (gitlab, argocd, nginx, etc.)
    local manifests_dir="${SCRIPT_DIR}/manifests"
    for app_dir in "${manifests_dir}"/*/; do
        local app_name
        app_name=$(basename "${app_dir}")
        # Skip gitops-inventory: it's handled separately
        [[ "${app_name}" == "gitops-inventory" ]] && continue

        log_debug "Packing manifests/${app_name}/"
        mkdir -p "${repo_root}/manifests/${app_name}"
        # Ricorsivo: kargo-demo ha base/ e stages/<stage>/, l'albero va conservato
        find "${app_dir}" -type f \( -name '*.yaml' -o -name '*.yml' \) | while read -r f; do
            local rel_path="${f#"${app_dir}"}"
            mkdir -p "${repo_root}/manifests/${app_name}/$(dirname "${rel_path}")"
            cp "${f}" "${repo_root}/manifests/${app_name}/${rel_path}"
        done
    done

    # Purpose: auto-discover all inventory files (ArgoCD Application manifests)
    local inventory_dir="${SCRIPT_DIR}/manifests/gitops-inventory/inventory"
    if [[ -d "${inventory_dir}" ]]; then
        log_debug "Packing inventory/"
        find "${inventory_dir}" -type f \( -name '*.yaml' -o -name '*.yml' \) | while read -r f; do
            local rel_path="${f#"${inventory_dir}"}"
            local dir_part
            dir_part=$(dirname "${rel_path}")
            mkdir -p "${repo_root}/inventory${dir_part}"
            cp "$f" "${repo_root}/inventory${dir_part}/"
        done
    fi

    # Create tar.gz
    tar -czf "${tmp_dir}/content.tar.gz" -C "${repo_root}" .

    local file_count
    file_count=$(find "${repo_root}" -type f | wc -l)
    log_info "Packed ${file_count} files into content archive"
    find "${repo_root}" -type f | sed "s|${repo_root}/|  |" | sort >&2

    # Store as ConfigMap (binary data)
    kubectl create configmap gitops-content \
        --namespace="${GITLAB_NAMESPACE}" \
        --from-file=content.tar.gz="${tmp_dir}/content.tar.gz" \
        --dry-run=client -o yaml | kubectl apply -f -

    rm -rf "${tmp_dir}"
    log_success "ConfigMap gitops-content created"
}

gitops_push_via_job() {
    log_info "Pushing content to GitLab via K8s Job..."
    kubectl delete job gitops-init -n "${GITLAB_NAMESPACE}" 2>/dev/null || true

    cat << EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: gitops-init
  namespace: ${GITLAB_NAMESPACE}
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: OnFailure
      volumes:
      - name: content
        configMap:
          name: gitops-content
      containers:
      - name: git
        image: alpine:3.20
        resources:
          requests:
            cpu: 250m
            memory: 256Mi
        env:
        - name: GITLAB_PAT
          valueFrom:
            secretKeyRef:
              name: ${GITLAB_PAT_SECRET_NAME}
              key: token
        - name: GITLAB_HOST
          value: "gitlab.${GITLAB_NAMESPACE}.svc.cluster.local"
        - name: GIT_TERMINAL_PROMPT
          value: "0"
        volumeMounts:
        - name: content
          mountPath: /content
          readOnly: true
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -e
          apk add --no-cache git curl

          echo "Waiting for GitLab API..."
          attempt=0
          status="000"
          while [ \$attempt -lt 60 ]; do
            status=\$(curl -sf -o /dev/null -w "%{http_code}" \
              -H "PRIVATE-TOKEN: \$GITLAB_PAT" \
              "http://\$GITLAB_HOST/api/v4/version" 2>/dev/null || echo "000")
            if [ "\$status" = "200" ]; then
              echo "GitLab API ready"
              break
            fi
            attempt=\$((attempt + 1))
            echo "Attempt \$attempt/60 (HTTP \$status)..."
            sleep 5
          done
          [ "\$status" != "200" ] && { echo "ERROR: GitLab API timeout"; exit 1; }

          sleep 5

          # Extract content to a staging area first
          mkdir -p /tmp/staging
          tar -xzf /content/content.tar.gz -C /tmp/staging/

          echo "Cloning gitops repository..."
          if git clone "http://oauth2:\$GITLAB_PAT@\$GITLAB_HOST/root/gitops.git" /tmp/gitops; then
            echo "Clone OK"
          else
            echo "Clone failed, initializing new repo..."
            mkdir -p /tmp/gitops
            cd /tmp/gitops
            git init
            git remote add origin "http://oauth2:\$GITLAB_PAT@\$GITLAB_HOST/root/gitops.git"
          fi

          # Copy staged content into the git repo (preserving .git dir)
          cd /tmp/gitops
          cp -r /tmp/staging/inventory ./
          cp -r /tmp/staging/manifests ./

          echo "Files in repo:"
          find . -type f -not -path './.git/*' | sort

          git config user.email "bootstrap@local"
          git config user.name "Bootstrap"
          git add -A
          if git diff --cached --quiet; then
            echo "No changes to commit"
            pushed=1
          else
            git commit -m "Bootstrap: sync manifests from local"
            pushed=0
          fi

          attempt=0
          while [ \$pushed != "1" ] && [ \$attempt -lt 10 ]; do
            if git push origin HEAD:main 2>&1 || git push origin HEAD:master 2>&1; then
              echo "Push successful"
              pushed=1
              break
            fi
            attempt=\$((attempt + 1))
            echo "Push retry \$attempt/10..."
            sleep 10
          done
          if [ "\$pushed" != "1" ]; then
            echo "Failed to push"
            exit 1
          fi

          # Branch di output delle promozioni Kargo: devono esistere prima che ArgoCD
          # provi a sincronizzare le Application degli stage, altrimenti restano in errore.
          base_branch=\$(git rev-parse --abbrev-ref HEAD)
          for stage in dev staging prod; do
            if ! git ls-remote --exit-code --heads origin "stage/\${stage}" >/dev/null 2>&1; then
              echo "Creating branch stage/\${stage}..."
              git checkout --orphan "stage/\${stage}"
              git rm -rf . 2>/dev/null || true
              echo "Content generated by Kargo promotions" > README.md
              git add README.md
              git commit -m "Init stage/\${stage}"
              git push origin "stage/\${stage}"
              git checkout "\$base_branch"
            else
              echo "Branch stage/\${stage} already exists on remote"
            fi
          done
EOF

    log_info "Waiting for gitops-init job..."
    kubectl wait --for=condition=complete job/gitops-init \
        -n "${GITLAB_NAMESPACE}" --timeout=600s 2>/dev/null || {
        log_warn "Job may have failed. Check: kubectl logs -n ${GITLAB_NAMESPACE} -l job-name=gitops-init"
        return 1
    }
    kubectl delete job gitops-init -n "${GITLAB_NAMESPACE}" 2>/dev/null || true
    kubectl delete configmap gitops-content -n "${GITLAB_NAMESPACE}" 2>/dev/null || true
}

gitops_delete_repository() {
    log_step "GITOPS: Deleting gitops repository..."

    local gitlab_pod
    gitlab_pod=$(gitlab_get_pod)
    if [[ -z "${gitlab_pod}" ]]; then
        log_warn "GitLab pod not found, skipping repository deletion"
        return 0
    fi

    local pat
    pat=$(gitlab_get_pat)
    if [[ -z "${pat}" ]]; then
        log_warn "GitLab PAT not found, skipping repository deletion"
        return 0
    fi

    log_info "Deleting gitops project via GitLab API..."
    kubectl exec -n "${GITLAB_NAMESPACE}" "${gitlab_pod}" -- \
        curl -sf -X DELETE \
            -H "PRIVATE-TOKEN: ${pat}" \
            "http://localhost:80/api/v4/projects/root%2Fgitops" \
            2>/dev/null || log_warn "Failed to delete gitops project (may not exist)"

    log_info "Deleting residual gitops-init Job and ConfigMap..."
    kubectl delete job gitops-init -n "${GITLAB_NAMESPACE}" --ignore-not-found 2>/dev/null || true
    kubectl delete configmap gitops-content -n "${GITLAB_NAMESPACE}" --ignore-not-found 2>/dev/null || true

    log_success "GITOPS: Repository deleted"
}
