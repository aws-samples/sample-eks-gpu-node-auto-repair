variable "region" {
  description = "AWS region (must match the capacity reservation)."
  type        = string
}

variable "availability_zone" {
  description = "Single AZ for the GPU nodes and placement group (must match the reservation AZ)."
  type        = string
}

variable "cluster_name" {
  description = "Name of the standard EKS cluster (NOT Auto Mode)."
  type        = string
  default     = "eks-gpu-mng-efa"
}

variable "kubernetes_version" {
  description = "Kubernetes control plane version."
  type        = string
  default     = "1.37"
}

variable "vpc_cidr" {
  description = "CIDR for the isolated VPC (isolation makes overlap irrelevant)."
  type        = string
  default     = "10.42.0.0/16"
}

variable "capacity_reservation_id" {
  description = "ID of the On-Demand Capacity Reservation (or Capacity Block) the p5en node group launches into."
  type        = string
}

variable "capacity_type" {
  description = <<-EOT
    EKS managed node group capacity type for the reservation. Use "CAPACITY_BLOCK" when the
    reservation is a Capacity Block (the common case for p5en ML capacity — the
    `createdBy: EC2 CBR Management Service` tag on describe-capacity-reservations marks one), or
    "ON_DEMAND" for a plain ODCR (the node group targets the reservation on-demand). With
    CAPACITY_BLOCK the node group also sets the capacity-block market option automatically; an
    ON_DEMAND launch against a Capacity Block is silently ignored and ICEs. Confirm with
    `aws ec2 describe-capacity-reservations --capacity-reservation-ids $CR_ID` and set without
    editing HCL.
  EOT
  type        = string
  default     = "CAPACITY_BLOCK"
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Whether to create a NAT gateway for node egress (needs 1 Elastic IP). Most training
    customers want this (general internet egress for model/dataset/pip downloads and
    third-party registries like nvcr.io/docker.io), so it defaults to true.
  EOT
  type        = bool
  default     = true
}

variable "enable_vpc_endpoints" {
  description = <<-EOT
    Whether to create VPC endpoints (S3 gateway + ECR/STS/EC2/EKS/Logs interface endpoints)
    so AWS-service traffic stays on the AWS backbone (cheaper/faster/more secure, and off the
    NAT path). Independent of enable_nat_gateway: enable both for the enterprise best-practice
    combo, or set enable_nat_gateway=false + enable_vpc_endpoints=true for an EIP-free cluster
    (note: that no-NAT path cannot reach non-AWS registries like nvcr.io/docker.io).
  EOT
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to ALL resources (used for scoped teardown)."
  type        = map(string)
  default = {
    Project   = "sample-eks-gpu-node-auto-repair-mng"
    ManagedBy = "efa-demo"
    Ephemeral = "true"
  }
}
