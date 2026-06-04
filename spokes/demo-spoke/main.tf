################################################################################
# Demo spoke EKS cluster
#
# A minimal, cheap EKS cluster whose only purpose is to demonstrate the
# hub-and-spoke story end-to-end. Grafana Alloy is installed on this cluster
# (via scripts/install-spoke-alloy.sh) and pushes metrics/logs/traces to the
# central observability cluster's NLB.
#
# Differences from the hub cluster:
#   - No observability stack (Prometheus, Loki, etc.) - this is a workload cluster.
#   - No Karpenter - one tiny managed node group is enough.
#   - Single small node, single AZ, spot, fck-nat.
#   - No EFS, no ACM, no Secrets Manager. The spoke uses the hub's URLs.
################################################################################

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = "eks-observability"
      Role      = "demo-spoke"
      Cluster   = var.cluster_name
      ManagedBy = "Terraform"
    }
  }
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.5"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 52)]

  enable_nat_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

module "fck_nat" {
  source  = "RaJiska/fck-nat/aws"
  version = "~> 1.3"

  name      = "${var.cluster_name}-fck-nat"
  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.public_subnets[0]

  instance_type      = "t4g.nano"
  use_spot_instances = true
  ha_mode            = true

  update_route_tables = true
  route_tables_ids = {
    for idx, rt_id in module.vpc.private_route_table_ids :
    "private-${local.azs[idx]}" => rt_id
  }
}

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

  endpoint_public_access                   = true
  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  enabled_log_types           = []
  create_cloudwatch_log_group = false

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  addons = {
    coredns                = { most_recent = true, before_compute = true }
    kube-proxy             = { most_recent = true, before_compute = true }
    vpc-cni                = { most_recent = true, before_compute = true }
    eks-pod-identity-agent = { most_recent = true }
  }

  eks_managed_node_groups = {
    workload = {
      name           = "workload-ng"
      instance_types = ["t3.medium"]
      capacity_type  = "SPOT"

      min_size     = 1
      max_size     = 2
      desired_size = 1

      subnet_ids = [local.single_az_subnet_id]
      ami_type   = "AL2023_x86_64_STANDARD"
    }
  }
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name} --profile ${var.aws_profile}"
}
