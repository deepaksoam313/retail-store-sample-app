# =============================================================================
# INPUT VARIABLES
# =============================================================================

variable "aws_region" {
  description = "AWS region where resources will be created"
  type        = string
  default     = "ap-south-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "retail-store"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "kubernetes_version" {
  description = "Kubernetes version for EKS cluster"
  type        = string
  default     = "1.33"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "argocd_namespace" {
  description = "Namespace to install ArgoCD"
  type        = string
  default     = "argocd"
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm chart version"
  type        = string
  default     = "5.51.6"
}

variable "enable_single_nat_gateway" {
  description = "Use single NAT gateway to reduce costs (not recommended for production)"
  type        = bool
  default     = true
}

variable "enable_monitoring" {
  description = "Enable monitoring stack (Prometheus, Grafana)"
  type        = bool
  default     = true
}

# =============================================================================
# RBAC TEAM VARIABLES — read from AWS SSM Parameter Store
# No tfvars needed — values stored securely in SSM
# =============================================================================

# SSM data sources — fetch user lists from SSM
data "aws_ssm_parameter" "developer_users" {
  name = "/retail-store/rbac/developer_users"
}

data "aws_ssm_parameter" "devops_users" {
  name = "/retail-store/rbac/devops_users"
}

data "aws_ssm_parameter" "sre_users" {
  name = "/retail-store/rbac/sre_users"
}

# Local values — parse JSON string from SSM into list
locals {
  developer_users = jsondecode(data.aws_ssm_parameter.developer_users.value)
  devops_users    = jsondecode(data.aws_ssm_parameter.devops_users.value)
  sre_users       = jsondecode(data.aws_ssm_parameter.sre_users.value)
}
