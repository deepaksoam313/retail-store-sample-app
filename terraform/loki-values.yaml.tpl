loki:
  serviceAccount:
    create: true
    name: loki-stack
    annotations:
      eks.amazonaws.com/role-arn: ${loki_iam_role_arn}
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