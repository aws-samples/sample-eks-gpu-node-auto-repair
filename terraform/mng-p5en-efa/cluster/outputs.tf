output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "region" {
  description = "AWS region."
  value       = var.region
}

output "availability_zone" {
  description = "AZ the GPU node group and placement group are pinned to."
  value       = var.availability_zone
}

output "placement_group_name" {
  value = aws_placement_group.efa.name
}

output "efa_security_group_id" {
  value = aws_security_group.efa.id
}

output "cluster_security_group_id" {
  description = "EKS cluster primary security group id (nodes)."
  value       = module.eks.cluster_primary_security_group_id
}

output "node_group_label" {
  description = "Node label GPU pods select on."
  value       = "efa-gpu"
}

output "update_kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}
