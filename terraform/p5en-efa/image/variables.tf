variable "region" {
  description = "AWS region (must match the capacity reservation / rest of the p5en-efa stack)."
  type        = string
}

variable "dlc_source_region" {
  description = "Region to pull the AWS Deep Learning Container base image from (DLC is not replicated to every region)."
  type        = string
  default     = "us-west-2"
}

variable "ecr_repo_name" {
  type    = string
  default = "eks-gpu-efa/train-fsdp"
}

variable "project_name" {
  type    = string
  default = "eks-gpu-efa-image-build"
}

variable "tags" {
  type = map(string)
  default = {
    Project = "sample-eks-gpu-node-auto-repair-efa"
    Owner   = "demo"
  }
}
