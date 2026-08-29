data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_ec2_instance_type" "runner" {
  instance_type = var.runner_instance_type
}

data "aws_ec2_instance_type" "nat" {
  instance_type = var.nat_instance_type
}

data "aws_ec2_instance_type_offerings" "runner" {
  filter {
    name   = "instance-type"
    values = [var.runner_instance_type]
  }

  location_type = "availability-zone"
}

data "aws_ec2_instance_type_offerings" "nat" {
  filter {
    name   = "instance-type"
    values = [var.nat_instance_type]
  }

  location_type = "availability-zone"
}

data "aws_servicequotas_service_quota" "standard_on_demand_vcpus" {
  service_code = "ec2"
  quota_code   = "L-1216C47A"
}

locals {
  compatible_availability_zones = sort(tolist(setintersection(
    toset(data.aws_availability_zones.available.names),
    toset(data.aws_ec2_instance_type_offerings.runner.locations),
    toset(data.aws_ec2_instance_type_offerings.nat.locations),
  )))
  availability_zone = (
    var.availability_zone != null
    ? var.availability_zone
    : local.compatible_availability_zones[0]
  )
  benchmark_node_count = 4
  runner_root_gib      = 24
  nat_root_gib         = 8
  common_instance_tags = {
    Project  = var.project_tag
    AutoStop = "true"
  }
  package_sha256 = filesha256(var.package_path)
  # Имя bucket и префикс source/ оставлены совместимыми с уже применённым
  # permissions boundary. Внутри теперь хранится только готовый .deb.
  package_prefix     = "source/${local.package_sha256}"
  package_object_key = "${local.package_prefix}/spectral-task.deb"
  # Относительный timer нужен только до появления SSM. Рабочий и продлеваемый
  # TTL задаётся абсолютным time_offset.expires через association cluster_ttl.
  # Чистая установка ядра, ENA и DPDK занимает несколько минут, а повтор после
  # частично завершённого apply не должен потерять NAT посередине bootstrap.
  # Рабочий TTL всё равно задаётся отдельным абсолютным Scheduler/association.
  bootstrap_ttl_minutes = 30
  required_standard_vcpus = (
    local.benchmark_node_count * data.aws_ec2_instance_type.runner.default_vcpus
    + data.aws_ec2_instance_type.nat.default_vcpus
  )
}

check "stopped_cluster_is_paused" {
  assert {
    condition     = var.cluster_power_state == "running" || var.cluster_paused
    error_message = "Перед остановкой EC2 переведите cluster_paused в true, чтобы отключить внешний и локальные TTL."
  }
}

check "availability_zone_is_compatible" {
  assert {
    condition     = contains(local.compatible_availability_zones, local.availability_zone)
    error_message = "В availability_zone должны одновременно предлагаться runner_instance_type и nat_instance_type. Совместимые зоны: ${join(", ", local.compatible_availability_zones)}."
  }
}

moved {
  from = aws_s3_bucket.source
  to   = aws_s3_bucket.package
}

moved {
  from = aws_s3_bucket_public_access_block.source
  to   = aws_s3_bucket_public_access_block.package
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.source
  to   = aws_s3_bucket_server_side_encryption_configuration.package
}

moved {
  from = aws_s3_object.source
  to   = aws_s3_object.package
}

moved {
  from = aws_iam_role_policy.runner_source
  to   = aws_iam_role_policy.runner_package
}

resource "terraform_data" "capacity_guard" {
  input = {
    current_vcpus  = data.aws_servicequotas_service_quota.standard_on_demand_vcpus.value
    required_vcpus = local.required_standard_vcpus
  }

  lifecycle {
    precondition {
      condition     = data.aws_servicequotas_service_quota.standard_on_demand_vcpus.value >= local.required_standard_vcpus
      error_message = "Текущая Standard On-Demand quota ${data.aws_servicequotas_service_quota.standard_on_demand_vcpus.value} vCPU меньше требуемых ${local.required_standard_vcpus}. Дождитесь одобрения уже поданной заявки на увеличение EC2 quota."
    }
  }
}

resource "time_offset" "expires" {
  offset_minutes = var.max_runtime_minutes
}

resource "aws_s3_bucket" "package" {
  bucket        = "spectral-runner-source-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  force_destroy = true

  tags = { Name = "spectral-runner-package" }
}

resource "aws_s3_bucket_public_access_block" "package" {
  bucket = aws_s3_bucket.package.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "package" {
  bucket = aws_s3_bucket.package.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "package" {
  bucket                 = aws_s3_bucket.package.id
  key                    = local.package_object_key
  source                 = var.package_path
  source_hash            = filebase64sha256(var.package_path)
  server_side_encryption = "AES256"

  depends_on = [
    aws_s3_bucket_public_access_block.package,
    aws_s3_bucket_server_side_encryption_configuration.package,
  ]
}

resource "aws_vpc" "runner" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "spectral-runner" }
}

resource "aws_internet_gateway" "runner" {
  vpc_id = aws_vpc.runner.id
  tags   = { Name = "spectral-runner" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.runner.id
  cidr_block              = "10.42.0.0/24"
  availability_zone       = local.availability_zone
  map_public_ip_on_launch = false

  tags = { Name = "spectral-runner-public" }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.runner.id
  cidr_block              = "10.42.1.0/24"
  availability_zone       = local.availability_zone
  map_public_ip_on_launch = false

  tags = { Name = "spectral-runner-private" }
}

resource "aws_placement_group" "precision_time" {
  name     = "spectral-runner-precision-time"
  strategy = "precision-time"

  tags = { Name = "spectral-runner-precision-time" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.runner.id
  tags   = { Name = "spectral-runner-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.runner.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.runner.id
  tags   = { Name = "spectral-runner-private" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "nat" {
  name        = "spectral-runner-nat"
  description = "Allow private runner egress through the temporary NAT instance"
  vpc_id      = aws_vpc.runner.id

  ingress {
    description = "All IPv4 traffic from the runner VPC"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = [aws_vpc.runner.cidr_block]
  }

  egress {
    description = "Internet egress"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "spectral-runner-nat" }
}

resource "aws_security_group" "runner" {
  name        = "spectral-runner"
  description = "Only benchmark traffic between private nodes; management through SSM"
  vpc_id      = aws_vpc.runner.id

  ingress {
    description = "All benchmark traffic between nodes in this security group"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    self        = true
  }

  egress {
    description = "Package, S3, SSM, and service egress through NAT"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "spectral-runner" }
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "runner" {
  name                 = "spectral-runner"
  assume_role_policy   = data.aws_iam_policy_document.ec2_assume_role.json
  permissions_boundary = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/spectral-workload-boundary"
}

resource "aws_iam_role_policy_attachment" "runner_ssm" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role" "nat" {
  name                 = "spectral-runner-nat"
  assume_role_policy   = data.aws_iam_policy_document.ec2_assume_role.json
  permissions_boundary = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/spectral-workload-boundary"
}

resource "aws_iam_role_policy_attachment" "nat_ssm" {
  role       = aws_iam_role.nat.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "runner_package" {
  statement {
    sid       = "ReadRunnerPackage"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [aws_s3_object.package.arn]
  }

  statement {
    sid       = "WriteRunnerResults"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.package.arn}/results/*"]
  }

  statement {
    sid       = "ReadRunnerBucketEncryption"
    effect    = "Allow"
    actions   = ["s3:GetEncryptionConfiguration"]
    resources = [aws_s3_bucket.package.arn]
  }
}

resource "aws_iam_role_policy" "runner_package" {
  name   = "spectral-runner-package"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.runner_package.json
}

resource "aws_iam_instance_profile" "runner" {
  name = "spectral-runner"
  role = aws_iam_role.runner.name
}

resource "aws_iam_instance_profile" "nat" {
  name = "spectral-runner-nat"
  role = aws_iam_role.nat.name
}

resource "aws_instance" "nat" {
  ami                         = data.aws_ssm_parameter.al2023_arm64.value
  instance_type               = var.nat_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.nat.id]
  associate_public_ip_address = true
  source_dest_check           = false
  iam_instance_profile        = aws_iam_instance_profile.nat.name

  instance_initiated_shutdown_behavior = "terminate"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  credit_specification {
    cpu_credits = "standard"
  }

  root_block_device {
    encrypted             = true
    volume_type           = "gp3"
    volume_size           = local.nat_root_gib
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/nat-user-data.sh.tftpl", {
    ttl_minutes = local.bootstrap_ttl_minutes
    vpc_cidr    = aws_vpc.runner.cidr_block
  })
  user_data_replace_on_change = true

  # Auto-assigned public IPv4 освобождается при stop и выдаётся заново при
  # start. AWS Provider читает поле как false у stopped-инстанса и без этого
  # пытается заменить NAT вместо обычного запуска. Latest AMI выбирается при
  # создании стенда; публикация следующего образа не должна менять живой стенд.
  lifecycle {
    ignore_changes = [ami, associate_public_ip_address]
  }

  tags = merge(local.common_instance_tags, {
    Name = "spectral-runner-nat"
    Role = "nat"
  })

  depends_on = [
    aws_iam_role_policy_attachment.nat_ssm,
    aws_route.public_internet,
    terraform_data.capacity_guard,
  ]
}

resource "aws_route" "private_internet" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat.primary_network_interface_id
}

resource "aws_instance" "runner" {
  count = local.benchmark_node_count

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.runner_instance_type
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.runner.id]
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.runner.name
  placement_group             = aws_placement_group.precision_time.name

  instance_initiated_shutdown_behavior = "terminate"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    encrypted             = true
    volume_type           = "gp3"
    volume_size           = local.runner_root_gib
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/runner-user-data.sh.tftpl", {
    ttl_minutes = local.bootstrap_ttl_minutes
  })
  user_data_replace_on_change = true

  # data.aws_ami.ubuntu выбирает latest только при создании стенда. Иначе
  # обычное обновление benchmark-пакета пересоздаёт все узлы, как только
  # Canonical публикует следующий образ. Намеренная смена AMI делается явным
  # terraform -replace, чтобы одновременно начать новую измерительную эпоху.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = merge(local.common_instance_tags, {
    Name = "spectral-benchmark-node-${count.index + 1}"
    Role = count.index == 0 ? "source" : "receiver"
  })

  depends_on = [
    aws_iam_role_policy_attachment.runner_ssm,
    aws_iam_role_policy.runner_package,
    aws_route.private_internet,
    terraform_data.capacity_guard,
  ]
}

# DPDK никогда не забирает основной ENI: он остаётся у Linux для SSM,
# bootstrap и аварийного восстановления. Второй интерфейс используется только
# как data plane и может безопасно переключаться между ena и PCI-драйвером DPDK.
resource "aws_network_interface" "runner_data" {
  count = local.benchmark_node_count

  subnet_id       = aws_subnet.private.id
  security_groups = [aws_security_group.runner.id]

  tags = merge(local.common_instance_tags, {
    Name = "spectral-benchmark-data-${count.index + 1}"
    Role = "data"
  })
}

resource "aws_network_interface_attachment" "runner_data" {
  count = local.benchmark_node_count

  instance_id          = aws_instance.runner[count.index].id
  network_interface_id = aws_network_interface.runner_data[count.index].id
  device_index         = 1
}

# Power state является частью желаемого состояния Terraform. Оркестратор делает
# stop/start в две фазы, потому что TTL association должна выполниться на живых
# SSM targets: сначала pause, затем stop; сначала start, затем unpause.
resource "aws_ec2_instance_state" "nat" {
  instance_id = aws_instance.nat.id
  state       = var.cluster_power_state
}

resource "aws_ec2_instance_state" "runner" {
  count = local.benchmark_node_count

  instance_id = aws_instance.runner[count.index].id
  state       = var.cluster_power_state
}

resource "aws_ssm_association" "runner_bootstrap" {
  count = var.bootstrap_association_enabled ? 1 : 0

  name             = "AWS-RunRemoteScript"
  association_name = "spectral-runner-bootstrap"

  parameters = {
    sourceType = "S3"
    sourceInfo = jsonencode({ path = "https://${aws_s3_bucket.package.bucket_regional_domain_name}/${aws_s3_object.package.key}" })
    commandLine = join("\n", [
      "export PACKAGE_PATH='spectral-task.deb'",
      "export EXPECTED_SHA256='${local.package_sha256}'",
      "export PHC_TARGET_KERNEL='6.17.0-1020-aws'",
      file("${path.module}/scripts/phc-prepare.sh"),
      file("${path.module}/scripts/dpdk-prepare.sh"),
      file("${path.module}/templates/runner-bootstrap.sh"),
    ])
    executionTimeout = "900"
  }

  targets {
    key    = "InstanceIds"
    values = aws_instance.runner[*].id
  }

  max_concurrency                  = "4"
  max_errors                       = "0"
  wait_for_success_timeout_seconds = 300

  depends_on = [
    aws_iam_role_policy.runner_package,
    aws_network_interface_attachment.runner_data,
    aws_route.private_internet,
    aws_s3_object.package,
  ]
}

resource "aws_ssm_association" "cluster_ttl" {
  count = var.ttl_association_enabled ? 1 : 0

  name             = "AWS-RunShellScript"
  association_name = "spectral-runner-cluster-ttl"

  parameters = {
    commands = join("\n", [
      "export EXPIRES_AT='${time_offset.expires.rfc3339}'",
      "export CLUSTER_PAUSED='${var.cluster_paused}'",
      file("${path.module}/templates/cluster-ttl.sh"),
    ])
    executionTimeout = "60"
  }

  targets {
    key    = "InstanceIds"
    values = concat([aws_instance.nat.id], aws_instance.runner[*].id)
  }

  max_concurrency                  = "5"
  max_errors                       = "0"
  wait_for_success_timeout_seconds = 300

  depends_on = [
    aws_route.private_internet,
    aws_scheduler_schedule.expiry,
  ]
}

data "aws_iam_policy_document" "scheduler_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:scheduler:${var.aws_region}:${data.aws_caller_identity.current.account_id}:schedule-group/default"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name                 = "spectral-runner-expiry"
  assume_role_policy   = data.aws_iam_policy_document.scheduler_assume_role.json
  permissions_boundary = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/spectral-workload-boundary"
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    sid     = "TerminateOnlyThisRunner"
    effect  = "Allow"
    actions = ["ec2:TerminateInstances"]
    resources = concat(
      [aws_instance.nat.arn],
      aws_instance.runner[*].arn,
    )
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "spectral-runner-expiry"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule" "expiry" {
  name                         = "spectral-runner-expiry-${formatdate("YYYYMMDDhhmmss", time_offset.expires.rfc3339)}"
  description                  = "Terminate the temporary Spectral runner and NAT instance"
  schedule_expression          = "at(${formatdate("YYYY-MM-DD'T'hh:mm:ss", time_offset.expires.rfc3339)})"
  schedule_expression_timezone = "UTC"
  action_after_completion      = "DELETE"
  state                        = var.cluster_paused ? "DISABLED" : "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:${data.aws_partition.current.partition}:scheduler:::aws-sdk:ec2:terminateInstances"
    role_arn = aws_iam_role.scheduler.arn
    input = jsonencode({
      InstanceIds = concat(
        [aws_instance.nat.id],
        aws_instance.runner[*].id,
      )
    })

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 3
    }
  }

  depends_on = [aws_iam_role_policy.scheduler]
}
