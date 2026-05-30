################################################################################
# Storage
#
# S3 buckets for long-term observability data:
#   - loki-chunks   - Loki log chunks
#   - loki-ruler    - Loki alerting rules
#   - tempo         - Tempo trace blocks
#   - thanos        - Thanos metric blocks
#   - logs          - S3 access logs for the above buckets
#
# Plus EFS for Grafana's dashboard storage (needs ReadWriteMany).
#
# Lifecycle rules: hot in Standard for 30d, IA for 90d, Glacier for 365d
# (Thanos uses a longer schedule because metrics are smaller and queried longer).
################################################################################

# ---------------------------------------------------------------------------
# S3 buckets
# ---------------------------------------------------------------------------

locals {
  s3_buckets = {
    loki_chunks = { name = "loki-chunks", purpose = "Loki log storage" }
    loki_ruler  = { name = "loki-ruler", purpose = "Loki alert rules" }
    tempo       = { name = "tempo", purpose = "Tempo trace storage" }
    thanos      = { name = "thanos", purpose = "Thanos long-term metrics" }
  }
}

resource "aws_s3_bucket" "logs" {
  bucket        = "${var.cluster_name}-logs-${local.account_id}"
  force_destroy = false

  tags = {
    Name    = "${var.cluster_name}-logs"
    Purpose = "S3 access logs"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "observability" {
  for_each = local.s3_buckets

  bucket        = "${var.cluster_name}-${each.value.name}-${local.account_id}"
  force_destroy = false

  tags = {
    Name    = "${var.cluster_name}-${each.value.name}"
    Purpose = each.value.purpose
  }
}

resource "aws_s3_bucket_versioning" "observability" {
  for_each = local.s3_buckets

  bucket = aws_s3_bucket.observability[each.key].id
  versioning_configuration {
    status = each.key == "loki_chunks" ? "Enabled" : "Disabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "observability" {
  for_each = local.s3_buckets

  bucket = aws_s3_bucket.observability[each.key].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "observability" {
  for_each = local.s3_buckets

  bucket                  = aws_s3_bucket.observability[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "observability" {
  for_each = local.s3_buckets

  bucket        = aws_s3_bucket.observability[each.key].id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "${each.value.name}/"
}

# Lifecycle: logs/traces tier down quickly; metrics keep raw data longer.
resource "aws_s3_bucket_lifecycle_configuration" "logs_traces" {
  for_each = toset(["loki_chunks", "tempo"])

  bucket = aws_s3_bucket.observability[each.key].id

  rule {
    id     = "tier-down"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 90
      storage_class = "GLACIER"
    }
    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "thanos" {
  bucket = aws_s3_bucket.observability["thanos"].id

  rule {
    id     = "tier-down"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 180
      storage_class = "GLACIER"
    }
    expiration {
      days = 730
    }
  }
}

# ---------------------------------------------------------------------------
# IRSA for Loki / Tempo / Thanos
# ---------------------------------------------------------------------------

module "loki_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"

  role_name = "${var.cluster_name}-loki"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["observability:loki"]
    }
  }

  role_policy_arns = {
    loki_s3 = aws_iam_policy.loki_s3.arn
  }
}

resource "aws_iam_policy" "loki_s3" {
  name        = "${var.cluster_name}-loki-s3"
  description = "Allow Loki to read/write its S3 buckets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [
          aws_s3_bucket.observability["loki_chunks"].arn,
          aws_s3_bucket.observability["loki_ruler"].arn,
        ]
      },
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = [
          "${aws_s3_bucket.observability["loki_chunks"].arn}/*",
          "${aws_s3_bucket.observability["loki_ruler"].arn}/*",
        ]
      },
    ]
  })
}

module "tempo_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"

  role_name = "${var.cluster_name}-tempo"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["observability:tempo"]
    }
  }

  role_policy_arns = {
    tempo_s3 = aws_iam_policy.tempo_s3.arn
  }
}

resource "aws_iam_policy" "tempo_s3" {
  name        = "${var.cluster_name}-tempo-s3"
  description = "Allow Tempo to read/write its S3 bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.observability["tempo"].arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = ["${aws_s3_bucket.observability["tempo"].arn}/*"]
      },
    ]
  })
}

module "thanos_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"

  role_name = "${var.cluster_name}-thanos"

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      # Prometheus sidecar + every Thanos component shares this role.
      namespace_service_accounts = [
        "observability:prometheus-prometheus",
        "observability:thanos-query",
        "observability:thanos-storegateway",
        "observability:thanos-compactor",
        "observability:thanos-bucketweb",
      ]
    }
  }

  role_policy_arns = {
    thanos_s3 = aws_iam_policy.thanos_s3.arn
  }
}

resource "aws_iam_policy" "thanos_s3" {
  name        = "${var.cluster_name}-thanos-s3"
  description = "Allow Thanos components and the Prometheus sidecar to read/write the Thanos S3 bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.observability["thanos"].arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = ["${aws_s3_bucket.observability["thanos"].arn}/*"]
      },
    ]
  })
}

################################################################################
# EFS for Grafana (ReadWriteMany)
################################################################################

resource "aws_efs_file_system" "observability" {
  creation_token = "${var.cluster_name}-observability"
  encrypted      = true

  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = {
    Name = "${var.cluster_name}-observability-efs"
  }
}

# Mount targets in every AZ - even though our pods run in one AZ, having
# multi-AZ ENIs means we can recover the volume quickly if we move pods later.
resource "aws_efs_mount_target" "observability" {
  count = length(module.vpc.private_subnets)

  file_system_id  = aws_efs_file_system.observability.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs.id]
}

resource "aws_security_group" "efs" {
  name        = "${var.cluster_name}-efs-sg"
  description = "Allow EKS nodes to NFS-mount the Grafana EFS"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "NFS from EKS cluster nodes"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [module.eks.cluster_primary_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EFS CSI driver IRSA.
module "efs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"

  role_name             = "${var.cluster_name}-efs-csi-driver"
  attach_efs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:efs-csi-controller-sa"]
    }
  }
}

resource "kubernetes_storage_class" "efs" {
  metadata {
    name = "efs-sc"
  }

  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Retain"
  volume_binding_mode = "Immediate"

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.observability.id
    directoryPerms   = "700"
  }

  depends_on = [aws_efs_mount_target.observability]
}
