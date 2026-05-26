variable "aws_region" {
  description = "AWS region where the state bucket will live."
  type        = string
  default     = "eu-central-1"
}

variable "aws_profile" {
  description = "AWS profile to use for the bootstrap."
  type        = string
  default     = "default"
}

variable "bucket_name" {
  description = "Name of the S3 bucket that will hold all Terraform state files. Must be globally unique. Suggested form: eks-observability-tfstate-<aws-account-id>."
  type        = string
}
