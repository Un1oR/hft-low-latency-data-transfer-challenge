output "permissions_boundary_arn" {
  value       = aws_iam_policy.workload_boundary.arn
  description = "Permissions boundary для всех служебных ролей Spectral."
}

output "delegated_user" {
  value       = var.target_user_name
  description = "IAM user с ограниченным управлением ролями spectral-* через Terraform."
}

output "requested_standard_on_demand_vcpu_quota" {
  value       = aws_servicequotas_service_quota.standard_on_demand_vcpus.value
  description = "Запрошенная EC2 Standard On-Demand quota в us-east-1."
}
