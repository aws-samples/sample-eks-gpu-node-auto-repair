output "fsx_security_group_id" {
  description = "Security group ID to attach to the FSx filesystem."
  value       = aws_security_group.fsx.id
}

output "fsx_subnet_id" {
  description = "One private subnet ID for FSx (single-AZ scratch/persistent)."
  value       = sort(data.aws_subnets.private.ids)[0]
}
