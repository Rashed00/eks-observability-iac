################################################################################
# Outputs - consumed by the gitops repo and operator scripts.
################################################################################

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version."
  value       = module.eks.cluster_version
}

output "oidc_provider_arn" {
  description = "EKS OIDC provider ARN (used to create additional IRSA roles)."
  value       = module.eks.oidc_provider_arn
}

output "configure_kubectl" {
  description = "Command to configure kubectl for this cluster."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name} --profile ${var.aws_profile}"
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnets" {
  value = module.vpc.private_subnets
}

output "public_subnets" {
  value = module.vpc.public_subnets
}

# ---------------------------------------------------------------------------
# Storage / S3 / EFS
# ---------------------------------------------------------------------------

output "loki_chunks_bucket" {
  value = aws_s3_bucket.observability["loki_chunks"].id
}

output "loki_ruler_bucket" {
  value = aws_s3_bucket.observability["loki_ruler"].id
}

output "tempo_bucket" {
  value = aws_s3_bucket.observability["tempo"].id
}

output "thanos_bucket" {
  value = aws_s3_bucket.observability["thanos"].id
}

output "logs_bucket" {
  value = aws_s3_bucket.logs.id
}

output "efs_id" {
  value = aws_efs_file_system.observability.id
}

# ---------------------------------------------------------------------------
# IRSA role ARNs - referenced in gitops repo helm values
# ---------------------------------------------------------------------------

output "loki_irsa_role_arn" {
  value = module.loki_irsa.iam_role_arn
}

output "tempo_irsa_role_arn" {
  value = module.tempo_irsa.iam_role_arn
}

output "thanos_irsa_role_arn" {
  value = module.thanos_irsa.iam_role_arn
}

output "external_secrets_irsa_role_arn" {
  value = module.external_secrets_irsa.iam_role_arn
}

# ---------------------------------------------------------------------------
# ACM
# ---------------------------------------------------------------------------

output "acm_certificate_arn" {
  description = "ACM cert ARN to put on the Envoy Gateway NLB."
  value       = aws_acm_certificate.observability.arn
}

output "observability_domain" {
  description = "Domain root for all observability services."
  value       = local.observability_domain
}

# ---------------------------------------------------------------------------
# Route53 - used by scripts/update-dns.sh after the NLB is provisioned
# ---------------------------------------------------------------------------

output "route53_zone_id" {
  description = "Route53 hosted zone ID for the root domain."
  value       = data.aws_route53_zone.root.zone_id
}
