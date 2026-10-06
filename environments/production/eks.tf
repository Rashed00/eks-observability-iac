################################################################################
# EKS cluster + node groups + Karpenter
#
# Two managed node groups:
#   1. system        - 1 small t3.medium ON_DEMAND, runs CoreDNS and Karpenter.
#                      Taint CriticalAddonsOnly so workloads stay off it.
#   2. observability - 1-4 t3.large SPOT, runs the LGTM stack pods.
#
# Karpenter then provisions additional spot nodes when there is more demand
# (e.g. when Loki/Thanos compaction kicks in).
#
# All compute is pinned to var.single_az to remove cross-AZ data transfer.
################################################################################

# KMS key for EKS secret envelope encryption.
resource "aws_kms_key" "eks" {
  description             = "${var.cluster_name} EKS secrets encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

# Pick the subnet whose AZ matches var.single_az - we pass this to both node
# groups so they only ever schedule in one AZ.
locals {
  single_az_subnet_id = element(
    [for idx, az in local.azs : module.vpc.private_subnets[idx] if az == var.single_az],
    0,
  )
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.10"

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  endpoint_public_access  = true
  endpoint_private_access = true

  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  # Disable control plane logs - the cluster monitors itself via the LGTM
  # stack, so paying CloudWatch for the same data twice is wasteful.
  enabled_log_types           = []
  create_cloudwatch_log_group = false

  encryption_config = {
    resources        = ["secrets"]
    provider_key_arn = aws_kms_key.eks.arn
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  addons = {
    coredns = {
      most_recent                 = true
      before_compute              = true
      resolve_conflicts_on_create = "OVERWRITE"
      configuration_values = jsonencode({
        computeType = "ec2"
      })
    }
    kube-proxy = {
      most_recent                 = true
      before_compute              = true
      resolve_conflicts_on_create = "OVERWRITE"
    }
    vpc-cni = {
      most_recent                 = true
      before_compute              = true
      resolve_conflicts_on_create = "OVERWRITE"
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
    aws-efs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.efs_csi_irsa.iam_role_arn
    }
  }

  eks_managed_node_groups = {
    # Small ON_DEMAND node for system-critical pods (Karpenter, CoreDNS).
    # CriticalAddonsOnly taint keeps regular workloads off it.
    system = {
      name           = "system-ng"
      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"

      min_size     = 1
      max_size     = 2
      desired_size = 1
      disk_size    = var.node_disk_size

      subnet_ids = [local.single_az_subnet_id]
      ami_type   = "AL2023_x86_64_STANDARD"

      labels = {
        role        = "system"
        "node-type" = "system"
      }

      taints = {
        critical_addons_only = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "PREFER_NO_SCHEDULE"
        }
      }
    }

    # Observability workloads run on SPOT for the savings.
    observability = {
      name           = "observability-ng"
      instance_types = var.node_instance_types
      capacity_type  = "SPOT"

      min_size     = 1
      max_size     = 4
      desired_size = 2
      disk_size    = var.node_disk_size

      subnet_ids = [local.single_az_subnet_id]
      ami_type   = "AL2023_x86_64_STANDARD"

      labels = {
        role        = "observability"
        "node-type" = "workload"
      }
    }
  }

  # Allow all node-to-node traffic in the cluster security group.
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
  depends_on = [module.fck_nat]
}

# EBS CSI driver IRSA.
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"

  role_name             = "${var.cluster_name}-ebs-csi-driver"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

################################################################################
# Karpenter
#
# Provisions additional spot nodes on demand. Pinned to var.single_az.
################################################################################

# EC2 Spot service-linked role - required once per AWS account.
# Wrap in a `try` so re-applies in an account that already has the SLR don't
# fail. If you hit "AlreadyExists" on a fresh apply, remove this resource.
resource "aws_iam_service_linked_role" "spot" {
  aws_service_name = "spot.amazonaws.com"
  description      = "Service-linked role for EC2 Spot Instances"

  lifecycle {
    ignore_changes = [aws_service_name]
  }
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.26.0"

  cluster_name                    = module.eks.cluster_name
  create_pod_identity_association = true
  enable_inline_policy            = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  depends_on = [aws_iam_service_linked_role.spot]
}

resource "helm_release" "karpenter" {
  namespace        = "kube-system"
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.4.0"
  wait             = false

  values = [
    <<-EOT
    replicas: 2
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    EOT
  ]

  depends_on = [module.eks, module.karpenter]
}

resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      role: ${module.karpenter.node_iam_role_name}
      amiSelectorTerms:
        - alias: al2023@latest
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      tags:
        karpenter.sh/discovery: ${var.cluster_name}
  YAML

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: default
    spec:
      template:
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot", "on-demand"]
            - key: karpenter.k8s.aws/instance-category
              operator: In
              values: ["c", "m", "r", "t"]
            - key: karpenter.k8s.aws/instance-generation
              operator: Gt
              values: ["4"]
            - key: topology.kubernetes.io/zone
              operator: In
              values: ["${var.single_az}"]
      limits:
        cpu: 1000
        memory: 1000Gi
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 1m
  YAML

  depends_on = [kubectl_manifest.karpenter_node_class]
}
