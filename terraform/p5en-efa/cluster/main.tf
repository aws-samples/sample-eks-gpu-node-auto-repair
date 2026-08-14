locals {
  # Three AZs for control-plane ENIs; nodes are pinned to var.availability_zone.
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [cidrsubnet(var.vpc_cidr, 4, 0), cidrsubnet(var.vpc_cidr, 4, 1), cidrsubnet(var.vpc_cidr, 4, 2)]
  public_subnets  = [cidrsubnet(var.vpc_cidr, 4, 3), cidrsubnet(var.vpc_cidr, 4, 4), cidrsubnet(var.vpc_cidr, 4, 5)]

  enable_nat_gateway   = var.enable_nat_gateway
  single_nat_gateway   = var.enable_nat_gateway
  enable_dns_hostnames = true

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = var.cluster_name
  }
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  # Control-plane logging to CloudWatch. 'audit' is the key one for debugging the
  # uninitialized-taint issue: it records every Node patch with the requesting identity, so we
  # can see WHO adds/removes node.cloudprovider.kubernetes.io/uninitialized (cloud-node-controller
  # vs karpenter) and WHEN. (These are the module defaults; set explicitly for reproducibility.)
  enabled_log_types                      = ["audit", "api", "authenticator"]
  cloudwatch_log_group_retention_in_days = 7

  # Auto Mode with the built-in general-purpose pool (for small control components like the
  # MPI operator / device plugins) PLUS our custom p5en/EFA/reserved NodePool applied via kubectl.
  create_auto_mode_iam_resources = true
  compute_config = {
    enabled    = true
    node_pools = ["general-purpose"]
  }

  # Extra permissions on the Auto Mode NODE role for capacity-reservation + placement-group
  # discovery/launch. Whether native Auto Mode strictly requires these is validated in the
  # spike (Task 9); attaching them is harmless and de-risks the reserved-capacity launch.
  node_iam_role_additional_policies = {
    efa_reservations = aws_iam_policy.efa_reservations.arn
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  tags = var.tags
}

# NOTE: When the built-in `general-purpose` node pool is enabled (compute_config.node_pools),
# EKS AUTO-CREATES the EC2 access entry + AmazonEKSAutoNodePolicy association for the Auto Mode
# node role. We therefore do NOT create one here (doing so causes ResourceInUseException).
# (If you switch to custom-node-pools-ONLY — no built-in pools — you must add an
# aws_eks_access_entry of type EC2 for module.eks.node_iam_role_arn, since EKS won't.)

# IAM policy granting capacity-reservation + placement-group describe/launch.
resource "aws_iam_policy" "efa_reservations" {
  name        = "${var.cluster_name}-efa-reservations"
  description = "Allow describing/launching into capacity reservations and placement groups for the EFA demo"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DescribeReservationsAndPlacementGroups"
        Effect   = "Allow"
        Action   = ["ec2:DescribeCapacityReservations", "ec2:DescribePlacementGroups"]
        Resource = "*"
      }
    ]
  })
  tags = var.tags
}

# Standalone cluster-strategy placement group (the EKS module does not create one for Auto Mode).
resource "aws_placement_group" "efa" {
  name     = "${var.cluster_name}-pg"
  strategy = "cluster"
  tags     = var.tags
}

# Dedicated EFA security group: allow all traffic within the group (RDMA/EFA requires
# all-protocol self-ingress/egress) plus egress to the internet for pulls.
resource "aws_security_group" "efa" {
  name        = "${var.cluster_name}-efa"
  description = "EFA/RDMA all-traffic within group for distributed training"
  vpc_id      = module.vpc.vpc_id
  tags        = merge(var.tags, { "karpenter.sh/discovery" = var.cluster_name })
}

resource "aws_security_group_rule" "efa_self_ingress" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.efa.id
  self              = true
  description       = "All traffic within the EFA security group (RDMA)"
}

resource "aws_security_group_rule" "efa_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.efa.id
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow all egress"
}

# ---------------------------------------------------------------------------
# VPC endpoints — provisioned when enable_vpc_endpoints = true (independent of
# the NAT gateway). Gives nodes AWS-service access over the AWS backbone
# (ECR/S3/STS/EC2/EKS/Logs). Enable alongside NAT for the enterprise best-practice
# combo, or on its own (with NAT disabled) for an EIP-free cluster.
# ---------------------------------------------------------------------------
locals {
  create_vpc_endpoints = var.enable_vpc_endpoints
  interface_endpoints = [
    "ecr.api",
    "ecr.dkr",
    "sts",
    "ec2",
    "eks",
    "logs",
  ]
}

# Security group for interface endpoints: allow HTTPS from within the VPC.
resource "aws_security_group" "vpce" {
  count       = local.create_vpc_endpoints ? 1 : 0
  name        = "${var.cluster_name}-vpce"
  description = "HTTPS to interface VPC endpoints from within the VPC"
  vpc_id      = module.vpc.vpc_id
  tags        = var.tags
}

resource "aws_security_group_rule" "vpce_ingress_https" {
  count             = local.create_vpc_endpoints ? 1 : 0
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.vpce[0].id
  cidr_blocks       = [var.vpc_cidr]
  description       = "HTTPS from within the VPC"
}

# S3 gateway endpoint (free; needed for ECR image layers and EKS artifacts).
resource "aws_vpc_endpoint" "s3" {
  count             = local.create_vpc_endpoints ? 1 : 0
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
  tags              = merge(var.tags, { Name = "${var.cluster_name}-s3" })
}

# Interface endpoints for the AWS APIs nodes/kubelet/EFA need.
resource "aws_vpc_endpoint" "interface" {
  for_each            = local.create_vpc_endpoints ? toset(local.interface_endpoints) : []
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpce[0].id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.cluster_name}-${each.value}" })
}
