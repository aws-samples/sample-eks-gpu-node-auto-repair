variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "Name of the EKS Auto Mode cluster."
  type        = string
  default     = "eks-gpu-node-auto-repair"
}

variable "kubernetes_version" {
  description = "Kubernetes control plane version."
  type        = string
  default     = "1.36"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    Project = "sample-eks-gpu-node-auto-repair"
    Owner   = "demo"
  }
}
