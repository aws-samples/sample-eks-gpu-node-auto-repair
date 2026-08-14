variable "region" {
  description = "AWS region (must match the capacity reservation)."
  type        = string
}

variable "availability_zone" {
  description = "Single AZ for the GPU nodes, placement group, and FSx (must match the reservation AZ)."
  type        = string
}

variable "cluster_name" {
  description = "Name of the temporary EKS Auto Mode cluster."
  type        = string
  default     = "eks-gpu-efa"
}

variable "kubernetes_version" {
  description = "Kubernetes control plane version."
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR for the isolated VPC (isolation makes overlap irrelevant)."
  type        = string
  default     = "10.42.0.0/16"
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
    Project   = "sample-eks-gpu-node-auto-repair-efa"
    ManagedBy = "efa-demo"
    Ephemeral = "true"
  }
}
