apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: loki-stack
  namespace: argocd
spec:
  project: retail-store
  source:
    repoURL: 'https://grafana.github.io/helm-charts'
    targetRevision: 2.10.2
    chart: loki-stack
    helm:
      values: |
        loki:
          serviceAccount:
            create: true
            name: loki-stack
            annotations: ${loki_iam_role_arn}
              eks.amazonaws.com/role-arn:
          config:
            storage_config:
              aws:
                s3: s3://${region}/${s3_bucket_name}
                region: ${region}
          persistence:
            enabled: false
        promtail:
          enabled: true
          config:
            clients:
              - url: http://loki-stack.monitoring:3100/loki/api/v1/push
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true