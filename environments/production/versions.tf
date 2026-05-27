################################################################################
# Terraform and provider version constraints
#
# We require Terraform >= 1.10 because we use native S3 state locking
# (use_lockfile = true) which removes the need for a DynamoDB lock table.
################################################################################

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # S3 backend with native state locking (Terraform >= 1.10).
  # The bucket is created out-of-band by bootstrap/state-backend.sh.
  # Fill in `key` and `bucket` here, or pass them via `terraform init -backend-config=...`.
  backend "s3" {
    # bucket = "eks-observability-tfstate-<account-id>"
    # key    = "observability-cluster/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
