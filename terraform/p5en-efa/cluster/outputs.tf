output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.region
}

output "availability_zone" {
  value = var.availability_zone
}

output "node_role_name" {
  description = "EKS Auto Mode node IAM role name (for the NodeClass role field)."
  value       = module.eks.node_iam_role_name
}

output "placement_group_name" {
  value = aws_placement_group.efa.name
}

output "efa_security_group_id" {
  value = aws_security_group.efa.id
}

output "cluster_security_group_id" {
  description = "EKS-created cluster security group (nodes)."
  value       = module.eks.cluster_primary_security_group_id
}

output "update_kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}
