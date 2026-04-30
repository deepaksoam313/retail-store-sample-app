# =============================================================================
# AUTOMATE KMS SECRETS SETUP - No manual steps required
# =============================================================================

# 1. Auto-create retail-store namespace
resource "kubectl_manifest" "retail_store_namespace" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: retail-store
  YAML

  depends_on = [module.retail_app_eks]
}

# 2. Auto-create SecretProviderClass for cart service
resource "kubectl_manifest" "cart_secret_provider_class" {
  yaml_body = <<-YAML
    apiVersion: secrets-store.csi.x-k8s.io/v1
    kind: SecretProviderClass
    metadata:
      name: cart-secrets
      namespace: retail-store
    spec:
      provider: aws
      parameters:
        objects: |
          - objectName: "${local.cluster_name}/cart"
            objectType: "secretsmanager"
            jmesPath:
              - path: RETAIL_CART_PERSISTENCE_PROVIDER
                objectAlias: RETAIL_CART_PERSISTENCE_PROVIDER
              - path: RETAIL_CART_PERSISTENCE_DYNAMODB_TABLE_NAME
                objectAlias: RETAIL_CART_PERSISTENCE_DYNAMODB_TABLE_NAME
              - path: RETAIL_CART_PERSISTENCE_DYNAMODB_CREATE_TABLE
                objectAlias: RETAIL_CART_PERSISTENCE_DYNAMODB_CREATE_TABLE
              - path: POSTGRES_PASSWORD
                objectAlias: POSTGRES_PASSWORD
              - path: POSTGRES_USERNAME
                objectAlias: POSTGRES_USERNAME
              - path: POSTGRES_DB
                objectAlias: POSTGRES_DB
      secretObjects:
      - secretName: cart-secrets
        type: Opaque
        data:
        - objectName: RETAIL_CART_PERSISTENCE_PROVIDER
          key: RETAIL_CART_PERSISTENCE_PROVIDER
        - objectName: RETAIL_CART_PERSISTENCE_DYNAMODB_TABLE_NAME
          key: RETAIL_CART_PERSISTENCE_DYNAMODB_TABLE_NAME
        - objectName: RETAIL_CART_PERSISTENCE_DYNAMODB_CREATE_TABLE
          key: RETAIL_CART_PERSISTENCE_DYNAMODB_CREATE_TABLE
        - objectName: POSTGRES_PASSWORD
          key: POSTGRES_PASSWORD
        - objectName: POSTGRES_USERNAME
          key: POSTGRES_USERNAME
        - objectName: POSTGRES_DB
          key: POSTGRES_DB
  YAML

  depends_on = [
    kubectl_manifest.retail_store_namespace,
    module.eks_addons,
    aws_secretsmanager_secret.cart
  ]
}

# 3. Auto-create SecretProviderClass for orders service
resource "kubectl_manifest" "orders_secret_provider_class" {
  yaml_body = <<-YAML
    apiVersion: secrets-store.csi.x-k8s.io/v1
    kind: SecretProviderClass
    metadata:
      name: orders-secrets
      namespace: retail-store
    spec:
      provider: aws
      parameters:
        objects: |
          - objectName: "${local.cluster_name}/orders"
            objectType: "secretsmanager"
            jmesPath:
              - path: RETAIL_CHECKOUT_PERSISTENCE_PROVIDER
                objectAlias: RETAIL_CHECKOUT_PERSISTENCE_PROVIDER
              - path: RETAIL_ORDERS_PERSISTENCE_POSTGRES_ENDPOINT
                objectAlias: RETAIL_ORDERS_PERSISTENCE_POSTGRES_ENDPOINT
              - path: RETAIL_ORDERS_PERSISTENCE_POSTGRES_NAME
                objectAlias: RETAIL_ORDERS_PERSISTENCE_POSTGRES_NAME
              - path: RETAIL_ORDERS_PERSISTENCE_POSTGRES_USERNAME
                objectAlias: RETAIL_ORDERS_PERSISTENCE_POSTGRES_USERNAME
              - path: RETAIL_ORDERS_PERSISTENCE_POSTGRES_PASSWORD
                objectAlias: RETAIL_ORDERS_PERSISTENCE_POSTGRES_PASSWORD
      secretObjects:
      - secretName: orders-secrets
        type: Opaque
        data:
        - objectName: RETAIL_CHECKOUT_PERSISTENCE_PROVIDER
          key: RETAIL_CHECKOUT_PERSISTENCE_PROVIDER
        - objectName: RETAIL_ORDERS_PERSISTENCE_POSTGRES_ENDPOINT
          key: RETAIL_ORDERS_PERSISTENCE_POSTGRES_ENDPOINT
        - objectName: RETAIL_ORDERS_PERSISTENCE_POSTGRES_NAME
          key: RETAIL_ORDERS_PERSISTENCE_POSTGRES_NAME
        - objectName: RETAIL_ORDERS_PERSISTENCE_POSTGRES_USERNAME
          key: RETAIL_ORDERS_PERSISTENCE_POSTGRES_USERNAME
        - objectName: RETAIL_ORDERS_PERSISTENCE_POSTGRES_PASSWORD
          key: RETAIL_ORDERS_PERSISTENCE_POSTGRES_PASSWORD
  YAML

  depends_on = [
    kubectl_manifest.retail_store_namespace,
    module.eks_addons,
    aws_secretsmanager_secret_version.orders
  ]
}

# 4. Auto-patch ArgoCD cart application to inject IRSA role ARN into Helm values
#    This tells ArgoCD to pass secrets.irsaRoleArn when deploying the cart chart
#    so the ServiceAccount gets the IRSA annotation automatically
resource "kubectl_manifest" "argocd_cart_app_with_irsa" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: retail-store-cart
      namespace: argocd
      annotations:
        argocd.argoproj.io/sync-wave: "1"
    spec:
      project: retail-store
      source:
        repoURL: https://github.com/deepaksoam313/retail-store-sample-app
        targetRevision: gitops
        path: src/cart/chart
        helm:
          valueFiles:
            - values.yaml
          parameters:
            - name: secrets.irsaRoleArn
              value: "${module.secrets_irsa.iam_role_arn}"
      destination:
        server: https://kubernetes.default.svc
        namespace: retail-store
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
  YAML

  depends_on = [
    kubectl_manifest.argocd_projects,
    module.secrets_irsa
  ]
}
