variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "Name of the EKS MNG cluster."
  type        = string
  default     = "eks-gpu-mng-node-repair"
}

variable "kubernetes_version" {
  description = "Kubernetes control plane version."
  type        = string
  default     = "1.37"
}

variable "gpu_instance_types" {
  description = <<-EOT
    GPU instance types for the managed node group. All listed sizes carry a single NVIDIA L40S
    GPU (one GPU per node), so the node group stays "1 GPU per node" regardless of which the ASG
    launches. Listing several sizes gives the ASG multiple capacity pools per AZ, which makes
    node provisioning resilient to InsufficientInstanceCapacity on any one size.
  EOT
  type        = list(string)
  default     = ["g6e.4xlarge", "g6e.8xlarge", "g6e.12xlarge", "g6e.16xlarge"]
}

variable "gpu_desired_size" {
  description = "Number of GPU nodes."
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    Project = "sample-eks-gpu-node-auto-repair-mng"
    Owner   = "demo"
  }
}
