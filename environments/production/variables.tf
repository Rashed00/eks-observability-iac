################################################################################
# Input variables
#
# All names/domains/regions are inputs. Every default below can be overridden
# in terraform.tfvars without editing any .tf file.
################################################################################

# ---------------------------------------------------------------------------
# AWS
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "eu-central-1"
}

variable "aws_profile" {
  description = "Local AWS CLI profile name used by Terraform and exec-credential plugins."
  type        = string
  default     = "default"
}

variable "single_az" {
  description = "Pin EKS node groups and Karpenter to the first AZ of the region. Saves on cross-AZ data transfer for the observability cluster."
  type        = string
  default     = "eu-central-1a"
}

# ---------------------------------------------------------------------------
# Naming
# ---------------------------------------------------------------------------

variable "cluster_name" {
  description = "EKS cluster name. Also used as a prefix for IRSA roles, S3 buckets, etc."
  type        = string
  default     = "observability-cluster"
}

variable "environment" {
  description = "Environment tag (e.g. production, staging)."
  type        = string
  default     = "production"
}

# ---------------------------------------------------------------------------
# DNS / TLS
# ---------------------------------------------------------------------------

variable "root_domain" {
  description = "Public DNS zone you already own in Route53 (e.g. example.com). A wildcard A/AAAA record for *.monitoring.<root_domain> will be created."
  type        = string
}

variable "observability_subdomain" {
  description = "Subdomain under root_domain for all observability services."
  type        = string
  default     = "monitoring"
}

# ---------------------------------------------------------------------------
# EKS
# ---------------------------------------------------------------------------

variable "cluster_version" {
  description = "Kubernetes version for the EKS control plane."
  type        = string
  default     = "1.34"
}

variable "vpc_cidr" {
  description = "VPC CIDR block."
  type        = string
  default     = "10.0.0.0/16"
}

variable "node_instance_types" {
  description = "Instance types for the SPOT observability node group."
  type        = list(string)
  default     = ["t3.large", "t3a.large"]
}

variable "node_disk_size" {
  description = "Root volume size (GiB) for managed node groups."
  type        = number
  default     = 100
}

# ---------------------------------------------------------------------------
# Observability secrets (stored in AWS Secrets Manager)
# ---------------------------------------------------------------------------

variable "grafana_admin_user" {
  description = "Initial Grafana admin username."
  type        = string
  default     = "admin"
  sensitive   = true
}

variable "grafana_admin_password" {
  description = "Initial Grafana admin password. Change this immediately after first login."
  type        = string
  sensitive   = true
}

variable "remote_write_basic_auth_user" {
  description = "Username spoke clusters use when pushing telemetry to this cluster (basic auth at the Envoy SecurityPolicy)."
  type        = string
  default     = "alloy"
  sensitive   = true
}

variable "remote_write_basic_auth_password" {
  description = "Password spoke clusters use when pushing telemetry to this cluster."
  type        = string
  sensitive   = true
}

variable "alertmanager_slack_webhook_url" {
  description = "Optional Slack webhook URL for Alertmanager. Leave empty to skip Slack integration."
  type        = string
  default     = ""
  sensitive   = true
}
