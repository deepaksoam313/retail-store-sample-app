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
            annotations:
              eks.amazonaws.com/role-arn: ${loki_iam_role_arn}
          config:
            auth_enabled: false
            schema_config:
              configs:
              - from: "2020-10-24"
                store: boltdb-shipper
                object_store: s3
                schema: v11
                index:
                  prefix: index_
                  period: 24h
            storage_config:
              aws:
                s3: s3://${region}/${s3_bucket_name}
                region: ${region}
              boltdb_shipper:
                active_index_directory: /data/loki/boltdb-shipper-active
                cache_location: /data/loki/boltdb-shipper-cache
                cache_ttl: 24h
                shared_store: s3
            compactor:
              working_directory: /data/loki/boltdb-shipper-compactor
              shared_store: s3
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