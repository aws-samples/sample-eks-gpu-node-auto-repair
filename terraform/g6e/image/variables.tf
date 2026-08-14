variable "region" {
  type    = string
  default = "us-west-2"
}

variable "ecr_repo_name" {
  type    = string
  default = "eks-gpu-node-auto-repair/train"
}

variable "project_name" {
  type    = string
  default = "eks-gpu-node-auto-repair-image-build"
}

variable "tags" {
  type = map(string)
  default = {
    Project = "sample-eks-gpu-node-auto-repair"
    Owner   = "demo"
  }
}
