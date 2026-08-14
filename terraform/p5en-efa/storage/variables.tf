variable "region" {
  type    = string
}

variable "availability_zone" {
  type    = string
}

variable "cluster_name" {
  type    = string
  default = "eks-gpu-efa"
}

variable "tags" {
  type = map(string)
  default = {
    Project   = "sample-eks-gpu-node-auto-repair-efa"
    ManagedBy = "efa-demo"
    Ephemeral = "true"
  }
}
