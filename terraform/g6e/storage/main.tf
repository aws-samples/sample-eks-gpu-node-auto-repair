# Look up the VPC created by the cluster layer via its name tag.
data "aws_vpc" "cluster" {
  filter {
    name   = "tag:Name"
    values = ["${var.cluster_name}-vpc"]
  }
}

# Private subnets tagged for Karpenter discovery in the cluster layer.
data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.cluster.id]
  }
  filter {
    name   = "tag:karpenter.sh/discovery"
    values = [var.cluster_name]
  }
}

# The EKS cluster security group (created/managed by EKS) — nodes use it.
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

locals {
  cluster_sg_id = data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

# Security group for the FSx for Lustre filesystem ENIs. Lustre uses TCP 988-1023.
resource "aws_security_group" "fsx" {
  name        = "${var.cluster_name}-fsx"
  description = "FSx for Lustre access from EKS nodes"
  vpc_id      = data.aws_vpc.cluster.id
  tags        = var.tags
}

resource "aws_security_group_rule" "fsx_from_nodes" {
  type                     = "ingress"
  from_port                = 988
  to_port                  = 1023
  protocol                 = "tcp"
  security_group_id        = aws_security_group.fsx.id
  source_security_group_id = local.cluster_sg_id
  description              = "Lustre traffic from EKS nodes"
}

# Allow the FSx SG to talk to itself (client mount + intra-fs traffic).
resource "aws_security_group_rule" "fsx_self" {
  type              = "ingress"
  from_port         = 988
  to_port           = 1023
  protocol          = "tcp"
  security_group_id = aws_security_group.fsx.id
  self              = true
  description       = "Lustre intra-SG traffic"
}

# Allow nodes to receive Lustre traffic back from FSx (egress path).
resource "aws_security_group_rule" "nodes_from_fsx" {
  type                     = "ingress"
  from_port                = 988
  to_port                  = 1023
  protocol                 = "tcp"
  security_group_id        = local.cluster_sg_id
  source_security_group_id = aws_security_group.fsx.id
  description              = "Lustre traffic from FSx to nodes"
}

# Egress: FSx server-initiated Lustre connections back to the nodes.
resource "aws_security_group_rule" "fsx_egress_to_nodes" {
  type                     = "egress"
  from_port                = 988
  to_port                  = 1023
  protocol                 = "tcp"
  security_group_id        = aws_security_group.fsx.id
  source_security_group_id = local.cluster_sg_id
  description              = "Lustre traffic from FSx back to nodes"
}

# Egress: intra-SG Lustre traffic.
resource "aws_security_group_rule" "fsx_egress_self" {
  type              = "egress"
  from_port         = 988
  to_port           = 1023
  protocol          = "tcp"
  security_group_id = aws_security_group.fsx.id
  self              = true
  description       = "Lustre intra-SG egress"
}
