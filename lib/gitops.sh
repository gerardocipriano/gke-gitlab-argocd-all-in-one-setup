#!/usr/bin/env bash
# Purpose: crea in GitLab un repo per ogni cartella di repos/ e ci pusha il contenuto.
# repos/platform -> root/platform (root app, GitLab, ArgoCD), repos/<app> -> root/<app>.
# I repo con una cartella kargo/ ricevono anche i branch stage/* che scrive Kargo.

readonly GITOPS_REPOS_DIR="${SCRIPT_DIR}/repos"

gitops_repo_names() {
    local d
    for d in "${GITOPS_REPOS_DIR}"/*/; do
        basename "${d}"
    done
}

gitops_create_repository() {
    log_step "GITOPS: Creating repositories in GitLab..."

    local gitlab_pod pat
    gitlab_pod=$(gitlab_get_pod)
    if [[ -z "${gitlab_pod}" ]]; then
        log_error "GitLab pod not found"
        return 1
    fi
    pat=$(gitlab_get_pat)
    if [[ -z "${pat}" ]]; then
        log_error "GitLab PAT not found. Run 'gitlab' command first."
        return 1
    fi

    gitlab_wait_for_api "${pat}" || return 1
    local repo
    for repo in $(gitops_repo_names); do
        gitops_create_project "${repo}" "${pat}"
    done
    gitops_create_content_configmap
    gitops_push_via_job

    log_success "GITOPS: $(gitops_repo_names | wc -l) repositories pushed: $(gitops_repo_names | tr '\n' ' ')"
}

gitops_create_project() {
    local name="$1" pat="$2" resp gitlab_pod
    gitlab_pod=$(gitlab_get_pod)
    resp=$(kubectl exec -n "${GITLAB_NAMESPACE}" "${gitlab_pod}" -- \
        curl -s -X POST \
            -H "PRIVATE-TOKEN: ${pat}" \
            -H "Content-Type: application/json" \
            "http://localhost:80/api/v4/projects" \
            -d "{\"name\": \"${name}\", \"visibility\": \"private\", \"initialize_with_readme\": false}" \
            2>/dev/null || echo "")

    if grep -q "\"path\":\"${name}\"" <<< "${resp}"; then
        log_success "Project root/${name} created"
    elif grep -q "already been taken\|already exists" <<< "${resp}"; then
        log_info "Project root/${name} already exists"
    else
        log_warn "Project root/${name}, unexpected response: ${resp:-empty}"
    fi
}

gitops_create_content_configmap() {
    log_info "Packing repos/ into a ConfigMap..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    tar -czf "${tmp_dir}/content.tar.gz" -C "${GITOPS_REPOS_DIR}" .
    log_info "Packed $(find "${GITOPS_REPOS_DIR}" -type f | wc -l) files"
    kubectl create configmap gitops-content \
        --namespace="${GITLAB_NAMESPACE}" \
        --from-file=content.tar.gz="${tmp_dir}/content.tar.gz" \
        --dry-run=client -o yaml | kubectl apply -f -
    rm -rf "${tmp_dir}"
}

gitops_push_via_job() {
    log_info "Pushing content to GitLab via K8s Job..."
    kubectl delete job gitops-init -n "${GITLAB_NAMESPACE}" --ignore-not-found 2>/dev/null || true

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
      nodeSelector:
        cloud.google.com/gke-spot: "true"
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
          apk add --no-cache git curl >/dev/null

          attempt=0
          until [ "\$(curl -s -o /dev/null -w '%{http_code}' -H "PRIVATE-TOKEN: \$GITLAB_PAT" "http://\$GITLAB_HOST/api/v4/version")" = "200" ]; do
            attempt=\$((attempt + 1))
            [ \$attempt -ge 60 ] && { echo "ERROR: GitLab API timeout"; exit 1; }
            sleep 5
          done

          mkdir -p /tmp/staging
          tar -xzf /content/content.tar.gz -C /tmp/staging/
          git config --global user.email "bootstrap@local"
          git config --global user.name "Bootstrap"
          git config --global init.defaultBranch main

          for dir in /tmp/staging/*/; do
            repo=\$(basename "\$dir")
            url="http://oauth2:\$GITLAB_PAT@\$GITLAB_HOST/root/\$repo.git"
            work="/tmp/work/\$repo"
            echo "== root/\$repo"
            if ! git clone -q "\$url" "\$work" 2>/dev/null; then
              mkdir -p "\$work" && cd "\$work" && git init -q && git remote add origin "\$url"
            fi
            cd "\$work"
            # Specchio esatto di repos/<nome>: i file tolti in locale spariscono anche da main.
            find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
            cp -r "\$dir". ./
            git add -A
            if git diff --cached --quiet; then
              echo "no changes"
            else
              git commit -q -m "bootstrap: sync da repos/\$repo"
            fi
            n=0
            until git push -q origin HEAD:main; do
              n=\$((n + 1)); [ \$n -ge 10 ] && { echo "push failed"; exit 1; }; sleep 10
            done

            # I branch stage/* li scrive Kargo; devono esistere prima che ArgoCD sincronizzi
            # le Application degli stage, altrimenti restano in errore.
            if [ -d "\$dir/kargo" ]; then
              for stage in dev staging prod; do
                if ! git ls-remote --exit-code --heads origin "stage/\$stage" >/dev/null 2>&1; then
                  git checkout -q --orphan "stage/\$stage"
                  git rm -rq . 2>/dev/null || true
                  echo "Content generated by Kargo promotions" > README.md
                  git add README.md
                  git commit -q -m "init stage/\$stage"
                  git push -q origin "stage/\$stage"
                  git checkout -q main
                  echo "created stage/\$stage"
                fi
              done
            fi
          done
EOF

    log_info "Waiting for gitops-init job..."
    if ! kubectl wait --for=condition=complete job/gitops-init -n "${GITLAB_NAMESPACE}" --timeout=600s 2>/dev/null; then
        log_error "Job gitops-init non completato: kubectl logs -n ${GITLAB_NAMESPACE} job/gitops-init"
        return 1
    fi
    kubectl logs -n "${GITLAB_NAMESPACE}" job/gitops-init 2>/dev/null | grep -E "^== |created|no changes" | sed 's/^/  /' >&2
    kubectl delete job gitops-init -n "${GITLAB_NAMESPACE}" 2>/dev/null || true
    kubectl delete configmap gitops-content -n "${GITLAB_NAMESPACE}" 2>/dev/null || true
}

gitops_delete_repository() {
    log_step "GITOPS: Deleting repositories..."

    local gitlab_pod pat repo
    gitlab_pod=$(gitlab_get_pod)
    pat=$(gitlab_get_pat)
    if [[ -z "${gitlab_pod}" || -z "${pat}" ]]; then
        log_warn "GitLab pod or PAT not found, skipping repository deletion"
        return 0
    fi

    for repo in $(gitops_repo_names); do
        local code
        code=$(kubectl exec -n "${GITLAB_NAMESPACE}" "${gitlab_pod}" -- \
            curl -s -o /dev/null -w "%{http_code}" -X DELETE -H "PRIVATE-TOKEN: ${pat}" \
            "http://localhost:80/api/v4/projects/root%2F${repo}" 2>/dev/null || echo "000")
        case "${code}" in
            202|204) log_info "root/${repo}: deletion requested" ;;
            404)     log_info "root/${repo}: not found" ;;
            *)       log_warn "root/${repo}: deletion failed (HTTP ${code})" ;;
        esac
    done

    kubectl delete job gitops-init -n "${GITLAB_NAMESPACE}" --ignore-not-found 2>/dev/null || true
    kubectl delete configmap gitops-content -n "${GITLAB_NAMESPACE}" --ignore-not-found 2>/dev/null || true
    log_success "GITOPS: Repositories deleted"
}
