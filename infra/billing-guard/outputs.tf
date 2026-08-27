output "budget_name" {
  value       = aws_budgets_budget.monthly.name
  description = "Имя бюджета AWS Budgets."
}

output "warning_topic_arn" {
  value       = aws_sns_topic.warning.arn
  description = "SNS topic для предупреждений без автоматических действий."
}

output "shutdown_topic_arn" {
  value       = aws_sns_topic.shutdown.arn
  description = "SNS topic, сообщения которого запускают остановку EC2 с нужными тегами."
}

output "budget_stop_function_name" {
  value       = aws_lambda_function.budget_stop.function_name
  description = "Lambda-функция аварийного бюджетного рубильника."
}
