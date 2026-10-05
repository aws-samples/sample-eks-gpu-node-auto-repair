variable "region" {
  type = string
}

variable "availability_zone" {
  type = string
}

variable "cluster_name" {
  type    = string
  default = "eks-gpu-mng-efa"
}

variable "tags" {
  type = map(string)
  default = {
    Project   = "sample-eks-gpu-node-auto-repair-mng"
    ManagedBy = "efa-demo"
    Ephemeral = "true"
  }
}
