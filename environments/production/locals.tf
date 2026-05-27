################################################################################
# Locals and data sources used across the module
################################################################################

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  # Use the first three AZs for VPC subnets (so EFS and the EKS control plane
  # have multi-AZ ENI placement) but pin node groups + Karpenter to a single AZ.
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  account_id = data.aws_caller_identity.current.account_id

  observability_domain = "${var.observability_subdomain}.${var.root_domain}"
  wildcard_domain      = "*.${local.observability_domain}"

  tags = {
    Project     = "eks-observability"
    Cluster     = var.cluster_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
