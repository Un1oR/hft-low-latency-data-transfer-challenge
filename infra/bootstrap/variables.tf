variable "target_account_id" {
  description = "AWS account, в котором разрешено выполнить bootstrap."
  type        = string
  default     = "753369745053"
}

variable "target_user_name" {
  description = "IAM user, которому Terraform выдаёт ограниченные права на служебные роли проекта."
  type        = string
  default     = "spectral-dev"
}

variable "workload_region" {
  description = "Регион временного runner и EC2, которыми могут управлять служебные роли."
  type        = string
  default     = "us-east-1"
}

variable "project_tag" {
  description = "Значение обязательного тега Project на EC2 для stop и terminate."
  type        = string
  default     = "spectral-task"
}

variable "standard_on_demand_vcpu_quota" {
  description = "Запрашиваемая EC2 quota. Целевому стенду из четырёх m8a.xlarge и t4g.nano нужно 18 vCPU; default 34 оставляет запас."
  type        = number
  default     = 34

  validation {
    condition     = var.standard_on_demand_vcpu_quota >= 18
    error_message = "Для полного стенда source, трёх receivers и NAT нужна quota не меньше 18 vCPU."
  }
}
