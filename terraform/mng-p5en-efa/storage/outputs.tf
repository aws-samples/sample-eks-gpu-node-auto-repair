output "fsx_security_group_id" {
  value = aws_security_group.fsx.id
}

output "fsx_subnet_id" {
  description = "Private subnet in the reservation AZ for FSx."
  value       = sort(data.aws_subnets.private_az.ids)[0]
}
