variable "budget_amount_usd" {
  description = "Месячный бюджет реальных расходов после credits и refunds."
  type        = number
  default     = 10

  validation {
    condition     = var.budget_amount_usd > 0
    error_message = "budget_amount_usd должен быть больше нуля."
  }
}

variable "alert_email" {
  description = "Необязательный email для прямых уведомлений AWS Budgets. Подписку нужно подтвердить по письму AWS."
  type        = string
  default     = ""
}

variable "workload_regions" {
  description = "Регионы, в которых бюджетный рубильник может останавливать EC2 с нужными тегами."
  type        = set(string)
  default     = ["us-east-1"]

  validation {
    condition     = length(var.workload_regions) > 0
    error_message = "Нужно указать хотя бы один регион."
  }
}

variable "project_tag" {
  description = "Значение тега Project для EC2, которые разрешено останавливать автоматически."
  type        = string
  default     = "spectral-task"
}

variable "tags" {
  description = "Теги ресурсов контура контроля бюджета."
  type        = map(string)
  default = {
    ManagedBy = "terraform"
    Project   = "spectral-task"
  }
}
