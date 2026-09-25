---
# Template Application - Copy and modify for new applications
# Usage:
#   1. Crea repos/<APP_NAME>/ con i manifest: diventa il repo root/<APP_NAME> in GitLab
#   2. Copia questo file in repos/platform/inventory/<APP_NAME>-application.yaml
#   3. Sostituisci i segnaposto e rilancia ./bootstrap.sh gitops

apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <APP_NAME>
  namespace: argocd
  labels:
    app.kubernetes.io/name: <APP_NAME>
    app.kubernetes.io/component: application
spec:
  project: gitops
  source:
    repoURL: http://gitlab.gitlab.svc.cluster.local/root/<APP_NAME>.git
    targetRevision: HEAD
    path: .
  destination:
    server: https://kubernetes.default.svc
    namespace: <APP_NAMESPACE>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
