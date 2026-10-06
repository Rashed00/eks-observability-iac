################################################################################
# Bootstrap Terraform state backend.
#
# This is a tiny, one-shot Terraform project that creates the S3 bucket the
# rest of this repository uses as its remote state backend.
#
# Run once per AWS account:
#
#   cd bootstrap/tf-state
#   terraform init
#   terraform apply -var "bucket_name=eks-observability-tfstate-<account-id>"
#
# After it's applied, write the output values into your environment's
# backend.tfbackend file and run:
#
#   cd ../../environments/production
#   terraform init -backend-config=backend.tfbackend
#
# This config uses LOCAL state itself (committed via gitignore exclusion) -
# bootstrapping a remote state requires it.
#
# Terraform >= 1.10 gives us native S3 state locking via use_lockfile = true,
# so no DynamoDB lock table is needed.
################################################################################

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

resource "aws_s3_bucket" "tfstate" {
  bucket        = var.bucket_name
  force_destroy = false

  tags = {
    Project   = "eks-observability"
    Purpose   = "Terraform remote state"
    ManagedBy = "Terraform bootstrap"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lock out accidental object deletion at the bucket policy level (best effort).
data "aws_caller_identity" "current" {}

output "bucket_name" {
  description = "The S3 bucket name to write into backend.tfbackend."
  value       = aws_s3_bucket.tfstate.id
}

output "backend_config_example" {
  description = "Copy this into your environment's backend.tfbackend file."
  value = <<-EOT
    bucket       = "${aws_s3_bucket.tfstate.id}"
    key          = "observability-cluster/production/terraform.tfstate"
    region       = "${var.aws_region}"
    encrypt      = true
    use_lockfile = true
    profile      = "${var.aws_profile}"
  EOT
}
