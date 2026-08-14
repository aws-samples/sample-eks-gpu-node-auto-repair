data "aws_vpc" "cluster" {
  filter {
    name   = "tag:Name"
    values = ["${var.cluster_name}-vpc"]
  }
}

# The private subnet in the reservation AZ (FSx must be in the same AZ as the p5en nodes).
data "aws_subnets" "private_az" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.cluster.id]
  }
  filter {
    name   = "tag:karpenter.sh/discovery"
    values = [var.cluster_name]
  }
  filter {
    name   = "availability-zone"
    values = [var.availability_zone]
  }
}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

locals {
  cluster_sg_id = data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

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

resource "aws_security_group_rule" "fsx_self" {
  type              = "ingress"
  from_port         = 988
  to_port           = 1023
  protocol          = "tcp"
  security_group_id = aws_security_group.fsx.id
  self              = true
  description       = "Lustre intra-SG traffic"
}

resource "aws_security_group_rule" "fsx_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.fsx.id
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow all egress"
}

resource "aws_security_group_rule" "nodes_from_fsx" {
  type                     = "ingress"
  from_port                = 988
  to_port                  = 1023
  protocol                 = "tcp"
  security_group_id        = local.cluster_sg_id
  source_security_group_id = aws_security_group.fsx.id
  description              = "Lustre traffic from FSx to nodes"
}
