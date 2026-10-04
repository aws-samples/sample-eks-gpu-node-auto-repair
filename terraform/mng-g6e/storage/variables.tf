variable "region" {
  type    = string
  default = "us-west-2"
}

variable "cluster_name" {
  type    = string
  default = "eks-gpu-mng-node-repair"
}

variable "tags" {
  type = map(string)
  default = {
    Project = "sample-eks-gpu-node-auto-repair-mng"
    Owner   = "demo"
  }
}
