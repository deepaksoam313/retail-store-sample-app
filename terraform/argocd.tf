# =============================================================================
# ARGOCD INSTALLATION AND CONFIGURATION
# =============================================================================

# Wait for the cluster and add-ons to be ready
resource "time_sleep" "wait_for_cluster" {
  create_duration = "30s"
  depends_on = [
    module.retail_app_eks,
    module.eks_addons
  ]
}

# =============================================================================
# ARGOCD HELM INSTALLATION
# =============================================================================

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = var.argocd_namespace
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  # ArgoCD configuration values
  values = [
    yamlencode({
      # Server configuration
      server = {
        service = {
          type = "ClusterIP"
        }
        ingress = {
          enabled = false  # We'll use port-forward for access
        }
        # Enable insecure mode for easier local access
        extraArgs = [
          "--insecure"
        ]
      }
      
      # Controller configuration
      controller = {
        resources = {
          requests = {
            cpu    = "100m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }
      }
      
      # Repo server configuration
      repoServer = {
        resources = {
          requests = {
            cpu    = "50m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "200m"
            memory = "256Mi"
          }
        }
      }
      
      # Redis configuration
      redis = {
        resources = {
          requests = {
            cpu    = "50m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "200m"
            memory = "128Mi"
          }
        }
      }
    })
  ]

  depends_on = [time_sleep.wait_for_cluster]
}

# =============================================================================
# ARGOCD CONFIGURATION
# =============================================================================

# resource "kubectl_manifest" "argocd_projects" {
#   for_each   = fileset("${path.module}/../argocd/projects", "*.yaml")
#   yaml_body  = file("${path.module}/../argocd/projects/${each.value}")
#   depends_on = [helm_release.argocd]
# }
#
# resource "kubectl_manifest" "argocd_apps" {
#   for_each   = fileset("${path.module}/../argocd/applications", "*.yaml")
#   yaml_body  = file("${path.module}/../argocd/applications/${each.value}")
#   depends_on = [kubectl_manifest.argocd_projects]
# }

# A. Deploy ArgoCD Projects (Security & Logical Boundaries)
resource "kubectl_manifest" "argocd_projects" {
  for_each   = fileset("${path.module}/../argocd/projects", "*.yaml")
  yaml_body  = file("${path.module}/../argocd/projects/${each.value}")
  depends_on = [helm_release.argocd]
}

# B. Handle all STATIC apps (catalog, ui, checkout, orders)
# cart is excluded here - managed by secrets_automation.tf with IRSA injection
resource "kubectl_manifest" "argocd_apps_static" {
  for_each = {
    for f in fileset("${path.module}/../argocd/applications", "*.yaml") :
    f => f if f != "loki-stack.yaml" && f != "retail-store-cart.yaml"
  }

  yaml_body  = file("${path.module}/../argocd/applications/${each.value}")
  depends_on = [kubectl_manifest.argocd_projects]
}

# C. Handle LOKI specifically (Dynamic Identity Injection)
# This auto-configures the S3 Bucket and IAM Role ARN every time
resource "kubectl_manifest" "argocd_app_loki" {
  yaml_body = templatefile("${path.module}/../argocd/applications/loki-stack.yaml.tpl", {
    loki_iam_role_arn = module.loki_irsa.iam_role_arn
    s3_bucket_name    = aws_s3_bucket.loki_storage.id
    # Use your region variable
    region            = var.aws_region
  })

  depends_on = [kubectl_manifest.argocd_projects]
}
