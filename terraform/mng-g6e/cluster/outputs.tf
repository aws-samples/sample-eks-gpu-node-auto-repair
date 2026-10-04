output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "region" {
  description = "AWS region."
  value       = var.region
}

output "cluster_security_group_id" {
  description = "EKS cluster primary security group id."
  value       = module.eks.cluster_primary_security_group_id
}

output "node_group_label" {
  description = "Node label GPU pods select on."
  value       = "gpu"
}

output "update_kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}
