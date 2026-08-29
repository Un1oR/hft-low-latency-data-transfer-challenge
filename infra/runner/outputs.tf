output "runner_instance_ids" {
  value       = aws_instance.runner[*].id
  description = "ID приватных EC2 benchmark nodes: первый source, остальные receivers."
}

output "nat_instance_id" {
  value       = aws_instance.nat.id
  description = "ID временного NAT instance, который стартует раньше приватных runner-узлов."
}

output "runner_private_ips" {
  value       = aws_instance.runner[*].private_ip
  description = "Приватные IPv4-адреса benchmark nodes в одной подсети."
}

output "runner_data_private_ips" {
  value       = aws_network_interface.runner_data[*].private_ip
  description = "Приватные IPv4-адреса отдельных data ENI для DPDK."
}

output "runner_data_mac_addresses" {
  value       = aws_network_interface.runner_data[*].mac_address
  description = "MAC-адреса отдельных data ENI в порядке benchmark nodes."
}

output "runner_data_network_interface_ids" {
  value       = aws_network_interface.runner_data[*].id
  description = "ID отдельных data ENI, которые можно передавать DPDK без потери SSM."
}

output "availability_zone" {
  value       = local.availability_zone
  description = "Availability Zone, общая для benchmark nodes и временного NAT."
}

output "runner_has_public_ip" {
  value       = anytrue([for instance in aws_instance.runner : instance.public_ip != ""])
  description = "Должно оставаться false для всех benchmark nodes."
}

output "expires_at" {
  value       = time_offset.expires.rfc3339
  description = "Время UTC, когда все benchmark nodes и NAT-инстанс будут автоматически завершены."
}

output "runtime_minutes" {
  value       = var.max_runtime_minutes
  description = "Интервал, использованный для текущего абсолютного TTL."
}

output "cluster_paused" {
  value       = var.cluster_paused
  description = "True, когда внешний Scheduler и локальные TTL отключены."
}

output "cluster_power_state" {
  value       = var.cluster_power_state
  description = "Желаемое состояние всех EC2, которым управляют ресурсы aws_ec2_instance_state."
}

output "bootstrap_association_enabled" {
  value       = var.bootstrap_association_enabled
  description = "True, когда package bootstrap association присутствует в Terraform state."
}

output "ttl_association_enabled" {
  value       = var.ttl_association_enabled
  description = "True, когда общий TTL association присутствует в Terraform state."
}

output "ssm_start_session_commands" {
  value = [for instance in aws_instance.runner :
    "aws ssm start-session --region ${var.aws_region} --target ${instance.id}"
  ]
  description = "Подключение к каждому узлу без SSH и публичных IP."
}

output "bootstrap_log_commands" {
  value = [for instance in aws_instance.runner :
    "aws ssm send-command --region ${var.aws_region} --instance-ids ${instance.id} --document-name AWS-RunShellScript --parameters commands='[\"sudo tail -n 200 /var/log/cloud-init-output.log\"]'"
  ]
  description = "Проверка bootstrap каждого узла через SSM Run Command."
}

output "required_standard_on_demand_vcpus" {
  value       = local.required_standard_vcpus
  description = "Минимальная EC2 Standard On-Demand quota для benchmark nodes и временного NAT."
}

output "benchmark_node_count" {
  value       = local.benchmark_node_count
  description = "Количество одинаковых benchmark nodes."
}

output "runner_instance_type" {
  value       = var.runner_instance_type
  description = "Instance type benchmark nodes для расчёта публичной On-Demand цены."
}

output "precision_time_placement_group" {
  value       = aws_placement_group.precision_time.name
  description = "Placement group со стратегией precision-time для всех benchmark nodes."
}

output "nat_instance_type" {
  value       = var.nat_instance_type
  description = "Instance type временного NAT для расчёта публичной On-Demand цены."
}

output "total_ebs_gib" {
  value       = local.benchmark_node_count * local.runner_root_gib + local.nat_root_gib
  description = "Суммарный размер gp3, который продолжает тарифицироваться у stopped-кластера."
}

output "current_standard_on_demand_vcpu_quota" {
  value       = data.aws_servicequotas_service_quota.standard_on_demand_vcpus.value
  description = "Текущая quota аккаунта; apply блокируется, если она ниже required_standard_on_demand_vcpus."
}

output "package_sha256" {
  value       = local.package_sha256
  description = "SHA-256 готового .deb, загруженного в приватный S3."
}

output "artifact_bucket" {
  value       = aws_s3_bucket.package.id
  description = "Приватный временный bucket для SSM-вывода и benchmark-артефактов; скачайте результаты до destroy."
}

output "bootstrap_association_id" {
  value       = try(aws_ssm_association.runner_bootstrap[0].association_id, null)
  description = "SSM association установки пакета и первичной настройки runner-узлов."
}

output "ttl_association_id" {
  value       = try(aws_ssm_association.cluster_ttl[0].association_id, null)
  description = "SSM association единого абсолютного TTL для runner-узлов и NAT."
}
