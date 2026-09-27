# =============================================================================
# EKS ACCESS ENTRIES — AWS Native Bridge (IAM → K8s)
# =============================================================================

# Developer Access Entries
resource "aws_eks_access_entry" "developers" {
  for_each = aws_iam_user.developers

  cluster_name      = module.retail_app_eks.cluster_name
  principal_arn     = each.value.arn
  type              = "STANDARD"
  user_name         = each.value.name
  kubernetes_groups = ["retail-store-developers"]

  depends_on = [module.retail_app_eks]
}

# DevOps Access Entries
resource "aws_eks_access_entry" "devops" {
  for_each = aws_iam_user.devops

  cluster_name      = module.retail_app_eks.cluster_name
  principal_arn     = each.value.arn
  type              = "STANDARD"
  user_name         = each.value.name
  kubernetes_groups = ["retail-store-devops"]

  depends_on = [module.retail_app_eks]
}

# SRE Access Entries
resource "aws_eks_access_entry" "sre" {
  for_each = aws_iam_user.sre

  cluster_name      = module.retail_app_eks.cluster_name
  principal_arn     = each.value.arn
  type              = "STANDARD"
  user_name         = each.value.name
  kubernetes_groups = ["retail-store-sre"]

  depends_on = [module.retail_app_eks]
}

# =============================================================================
# KUBERNETES ROLES — What each team can do
# =============================================================================

# Developer Role — view only in retail-store namespace
resource "kubectl_manifest" "developer_role" {
  yaml_body = <<-YAML
    apiVersion: rbac.authorization.k8s.io/v1
    kind: Role
    metadata:
      name: developer-role
      namespace: retail-store
    rules:
    - apiGroups: [""]
      resources: ["pods", "pods/log", "pods/status", "events", "services", "configmaps"]
      verbs: ["get", "list", "watch"]
    - apiGroups: ["apps"]
      resources: ["deployments", "replicasets"]
      verbs: ["get", "list", "watch"]
  YAML

  depends_on = [kubectl_manifest.retail_store_namespace]
}

# DevOps Role — deploy and manage in retail-store namespace
resource "kubectl_manifest" "devops_role" {
  yaml_body = <<-YAML
    apiVersion: rbac.authorization.k8s.io/v1
    kind: Role
    metadata:
      name: devops-role
      namespace: retail-store
    rules:
    - apiGroups: [""]
      resources: ["pods", "pods/log", "pods/status", "events", "services", "configmaps"]
      verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
    - apiGroups: ["apps"]
      resources: ["deployments", "replicasets", "statefulsets"]
      verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
    - apiGroups: [""]
      resources: ["pods/exec"]
      verbs: ["create"]
  YAML

  depends_on = [kubectl_manifest.retail_store_namespace]
}

# SRE ClusterRole — read everything across all namespaces + exec into pods
resource "kubectl_manifest" "sre_clusterrole" {
  yaml_body = <<-YAML
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: sre-clusterrole
    rules:
    - apiGroups: [""]
      resources: ["pods", "pods/log", "pods/status", "pods/exec", "nodes", "namespaces", "events", "services", "configmaps"]
      verbs: ["get", "list", "watch", "create"]
    - apiGroups: ["apps"]
      resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
      verbs: ["get", "list", "watch"]
    - apiGroups: ["metrics.k8s.io"]
      resources: ["pods", "nodes"]
      verbs: ["get", "list"]
  YAML

  depends_on = [module.retail_app_eks]
}

# =============================================================================
# KUBERNETES ROLEBINDINGS — Connect groups to roles
# =============================================================================

# Developer RoleBinding — retail-store namespace only
resource "kubectl_manifest" "developer_rolebinding" {
  yaml_body = <<-YAML
    apiVersion: rbac.authorization.k8s.io/v1
    kind: RoleBinding
    metadata:
      name: developer-rolebinding
      namespace: retail-store
    subjects:
    - kind: Group
      name: retail-store-developers
      apiGroup: rbac.authorization.k8s.io
    roleRef:
      kind: Role
      name: developer-role
      apiGroup: rbac.authorization.k8s.io
  YAML

  depends_on = [kubectl_manifest.developer_role]
}

# DevOps RoleBinding — retail-store namespace only
resource "kubectl_manifest" "devops_rolebinding" {
  yaml_body = <<-YAML
    apiVersion: rbac.authorization.k8s.io/v1
    kind: RoleBinding
    metadata:
      name: devops-rolebinding
      namespace: retail-store
    subjects:
    - kind: Group
      name: retail-store-devops
      apiGroup: rbac.authorization.k8s.io
    roleRef:
      kind: Role
      name: devops-role
      apiGroup: rbac.authorization.k8s.io
  YAML

  depends_on = [kubectl_manifest.devops_role]
}

# SRE ClusterRoleBinding — all namespaces
resource "kubectl_manifest" "sre_clusterrolebinding" {
  yaml_body = <<-YAML
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: sre-clusterrolebinding
    subjects:
    - kind: Group
      name: retail-store-sre
      apiGroup: rbac.authorization.k8s.io
    roleRef:
      kind: ClusterRole
      name: sre-clusterrole
      apiGroup: rbac.authorization.k8s.io
  YAML

  depends_on = [kubectl_manifest.sre_clusterrole]
}
