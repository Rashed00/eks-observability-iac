################################################################################
# VPC
#
# Three AZs of public + private + intra subnets (intra subnets are used by the
# EKS control plane ENIs). Node groups and Karpenter pin workloads to a single
# AZ (see var.single_az) to eliminate cross-AZ data transfer charges.
#
# The default AWS NAT Gateway is NOT used. We rely on fck-nat (a t4g.nano spot
# instance) which is ~3 USD/month versus ~100 USD/month for a managed NAT GW.
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.5"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 52)]

  # NAT Gateway disabled - fck-nat provides egress instead.
  enable_nat_gateway = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "karpenter.sh/discovery"                    = var.cluster_name
  }
}

################################################################################
# fck-nat - cost-optimized NAT instance
# https://github.com/RaJiska/terraform-aws-fck-nat
################################################################################

module "fck_nat" {
  source  = "RaJiska/fck-nat/aws"
  version = "~> 1.3"

  name      = "${var.cluster_name}-fck-nat"
  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.public_subnets[0]

  # ARM t4g.nano spot - ~3 USD/month
  instance_type      = "t4g.nano"
  use_spot_instances = false

  # ASG with size 1 so the instance auto-recovers if it dies.
  ha_mode = true

  # Replace the default 0.0.0.0/0 route in every private route table.
  update_route_tables = true
  route_tables_ids = {
    for idx, rt_id in module.vpc.private_route_table_ids :
    "private-${local.azs[idx]}" => rt_id
  }
}
