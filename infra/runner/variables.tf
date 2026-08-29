variable "aws_region" {
  description = "Регион AWS для временного runner."
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "Явная AZ для временного стенда. Null выбирает первую зону, где доступны типы runner и NAT."
  type        = string
  default     = null

  validation {
    condition     = var.availability_zone == null || startswith(var.availability_zone, var.aws_region)
    error_message = "availability_zone должна принадлежать выбранному aws_region."
  }
}

variable "runner_instance_type" {
  description = "Целевой серверный x86 instance type. m8a.xlarge даёт четыре физических ядра без SMT."
  type        = string
  default     = "m8a.xlarge"

  validation {
    condition     = can(regex("^m(7i|8a)\\.", var.runner_instance_type))
    error_message = "runner_instance_type должен принадлежать целевому семейству m7i или m8a."
  }
}

variable "nat_instance_type" {
  description = "Маленький Arm-инстанс только для исходящего трафика из приватной подсети."
  type        = string
  default     = "t4g.nano"
}

variable "package_path" {
  description = "Путь к локально собранному Ubuntu 24.04 amd64 .deb. Terraform загрузит его в приватный S3."
  type        = string

  validation {
    condition     = endswith(var.package_path, ".deb") && fileexists(var.package_path)
    error_message = "package_path должен указывать на существующий .deb, собранный командой make deb."
  }
}

variable "max_runtime_minutes" {
  description = "Общий TTL кластера в минутах от apply/extend. EventBridge Scheduler и абсолютные локальные таймеры завершают все узлы одновременно."
  type        = number
  default     = 15

  validation {
    condition     = var.max_runtime_minutes >= 10 && var.max_runtime_minutes <= 120
    error_message = "max_runtime_minutes должен быть от 10 до 120."
  }
}

variable "cluster_paused" {
  description = "Отключает внешний Scheduler и локальные TTL. Оркестратор включает этот режим до остановки EC2."
  type        = bool
  default     = false
}

variable "cluster_power_state" {
  description = "Желаемое состояние всех EC2 кластера. Меняется оркестратором только через Terraform после синхронизации TTL."
  type        = string
  default     = "running"

  validation {
    condition     = contains(["running", "stopped"], var.cluster_power_state)
    error_message = "cluster_power_state должен быть running или stopped."
  }
}

variable "bootstrap_association_enabled" {
  description = "Создаёт SSM association установки пакета. На cold create включается только после появления EC2 в SSM."
  type        = bool
  default     = true
}

variable "ttl_association_enabled" {
  description = "Создаёт общий SSM TTL association. На cold create включается после package bootstrap и reboot."
  type        = bool
  default     = true
}

variable "project_tag" {
  description = "Значение тега Project, по которому бюджетный рубильник находит runner."
  type        = string
  default     = "spectral-task"
}

variable "tags" {
  description = "Теги ресурсов временного runner."
  type        = map(string)
  default = {
    ManagedBy   = "terraform"
    Project     = "spectral-task"
    Environment = "test"
  }
}
