variable "region" {
  type    = string
  default = "us-west-2"
}

variable "cluster_name" {
  type    = string
  default = "eks-gpu-node-auto-repair"
}

variable "tags" {
  type = map(string)
  default = {
    Project = "sample-eks-gpu-node-auto-repair"
    Owner   = "demo"
  }
}
