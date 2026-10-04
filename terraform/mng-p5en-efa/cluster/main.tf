locals {
  # Three AZs for control-plane ENIs; nodes are pinned to var.availability_zone.
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # Index of the reservation AZ within local.azs. module.vpc.azs == local.azs and
  # private_subnets are index-aligned, so this picks the private subnet in var.availability_zone
  # for the EFA node group (so it lands in the reservation's AZ).
  az_index = index(local.azs, var.availability_zone)
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
  # can see WHO adds/removes node.cloudprovider.kubernetes.io/uninitialized and WHEN.
  enabled_log_types                      = ["audit", "api", "authenticator"]
  cloudwatch_log_group_retention_in_days = 7

  # Standard EKS (NOT Auto Mode): no Auto Mode compute block / Auto Mode IAM resources. GPU
  # capacity is an explicit EFA-enabled managed node group so node auto repair can be tuned
  # with nodeRepairConfigOverrides and the node group launches into the ODCR.
  eks_managed_node_groups = {
    efa-gpu = {
      instance_types = ["p5en.48xlarge"]
      ami_type       = "AL2023_x86_64_NVIDIA"
      min_size       = 2
      max_size       = 2
      desired_size   = 2

      # Pin to the reservation's AZ (single private subnet) + the ODCR.
      subnet_ids = [module.vpc.private_subnets[local.az_index]]

      # capacity_type depends on the live reservation: "ON_DEMAND" for a plain ODCR (targeting
      # the reservation on-demand) or "CAPACITY_BLOCK" for a Capacity Block. Confirmed against
      # `aws ec2 describe-capacity-reservations --capacity-reservation-ids $CR_ID` at deploy time.
      capacity_type = var.capacity_type
      capacity_reservation_specification = {
        capacity_reservation_target = {
          capacity_reservation_id = var.capacity_reservation_id
        }
      }

      # EFA: let the module build the launch template with all EFA interfaces + a cluster
      # placement group (this replaces the Auto Mode NodeClass advancedNetworking block).
      enable_efa_support     = true
      create_placement_group = true

      labels = { nodegroup = "efa-gpu" }

      taints = {
        gpu = {
          key    = "nvidia.com/gpu"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

      # Node auto repair with per-XID overrides. The monitoring condition and repair action
      # use the EKS API enums (not the eksctl aliases) — confirmed live (plan Task 14).
      node_repair_config = {
        enabled = true
        node_repair_config_overrides = [
          {
            node_monitoring_condition = "AcceleratedHardwareReady"
            node_unhealthy_reason     = "NvidiaXID79Error"
            min_repair_wait_time_mins = 5
            repair_action             = "Replace"
          },
          {
            node_monitoring_condition = "AcceleratedHardwareReady"
            node_unhealthy_reason     = "NvidiaXID64Error"
            min_repair_wait_time_mins = 10
            repair_action             = "Replace"
          },
          {
            node_monitoring_condition = "AcceleratedHardwareReady"
            node_unhealthy_reason     = "NvidiaXID63Error"
            min_repair_wait_time_mins = 10
            repair_action             = "NoAction"
          },
        ]
      }

      # The node role needs ec2:DescribeCapacityReservations + ec2:DescribePlacementGroups
      # to discover/launch into the reservation and placement group.
      iam_role_additional_policies = {
        efa_reservations = aws_iam_policy.efa_reservations.arn
      }
    }
  }

  # EKS add-ons that Auto Mode otherwise bundles. The node monitoring agent add-on provides
  # the NMA DaemonSet + NodeDiagnostic CRD; Pod Identity agent is required for FSx CSI
  # (storage layer creates the association).
  addons = {
    coredns                   = {}
    kube-proxy                = {}
    vpc-cni                   = {}
    eks-pod-identity-agent    = {}
    eks-node-monitoring-agent = {}
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  tags = var.tags
}

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

# Standalone cluster-strategy placement group, mirrored verbatim from the Auto Mode p5en
# layer. The EFA managed node group creates its own placement group (create_placement_group =
# true above); this one is kept for parity + as a named handle for downstream consumers.
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
