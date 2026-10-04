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
  description = "GPU instance types for the managed node group."
  type        = list(string)
  default     = ["g6e.4xlarge"]
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
