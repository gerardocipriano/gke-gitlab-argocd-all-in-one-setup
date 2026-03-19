---
# Template Application - Copy and modify for new applications
# Usage:
#   1. Copy this file to inventory/myapp-application.yaml
#   2. Replace all <PLACEHOLDER> values
#   3. Create the manifest directory manifests/<myapp>/
#   4. Commit and push to gitops repository
#   5. ArgoCD will automatically sync and deploy

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
    repoURL: http://gitlab.gitlab.svc.cluster.local/root/gitops.git
    targetRevision: HEAD
    path: manifests/<APP_NAME>
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
