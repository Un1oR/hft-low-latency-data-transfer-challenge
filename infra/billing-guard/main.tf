data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  alert_emails = var.alert_email == "" ? [] : [var.alert_email]
  topics = {
    warning  = aws_sns_topic.warning
    shutdown = aws_sns_topic.shutdown
  }
}

resource "aws_sns_topic" "warning" {
  name         = "spectral-budget-warning"
  display_name = "Spectral budget warning"
}

resource "aws_sns_topic" "shutdown" {
  name         = "spectral-budget-shutdown"
  display_name = "Spectral budget shutdown"
}

data "aws_iam_policy_document" "topic" {
  for_each = local.topics

  statement {
    sid    = "TopicOwnerManagement"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = [
      "sns:AddPermission",
      "sns:DeleteTopic",
      "sns:GetTopicAttributes",
      "sns:ListSubscriptionsByTopic",
      "sns:Publish",
      "sns:RemovePermission",
      "sns:SetTopicAttributes",
      "sns:Subscribe",
    ]
    resources = [each.value.arn]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "AllowAWSBudgetsPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    actions   = ["sns:Publish"]
    resources = [each.value.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:budgets::${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_sns_topic_policy" "this" {
  for_each = local.topics

  arn    = each.value.arn
  policy = data.aws_iam_policy_document.topic[each.key].json
}

resource "aws_budgets_budget" "monthly" {
  name         = "spectral-monthly-${var.budget_amount_usd}-usd"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_amount_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit = false
    include_refund = false
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = local.alert_emails
    subscriber_sns_topic_arns  = [aws_sns_topic.warning.arn]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = local.alert_emails
    subscriber_sns_topic_arns  = [aws_sns_topic.warning.arn]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = local.alert_emails
    subscriber_sns_topic_arns  = [aws_sns_topic.warning.arn]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = local.alert_emails
    subscriber_sns_topic_arns  = [aws_sns_topic.shutdown.arn]
  }

  depends_on = [aws_sns_topic_policy.this]
}

data "archive_file" "budget_stop" {
  type        = "zip"
  source_file = "${path.module}/lambda/budget_stop.py"
  output_path = "${path.module}/.terraform/budget-stop.zip"
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "budget_stop" {
  name                 = "spectral-budget-stop"
  assume_role_policy   = data.aws_iam_policy_document.lambda_assume_role.json
  permissions_boundary = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/spectral-workload-boundary"
}

data "aws_iam_policy_document" "budget_stop" {
  statement {
    sid    = "DescribeTaggedInstances"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
    ]
    resources = ["*"]
  }

  statement {
    sid     = "StopOnlyTaggedProjectInstances"
    effect  = "Allow"
    actions = ["ec2:StopInstances"]
    resources = [for region in sort(tolist(var.workload_regions)) :
      "arn:${data.aws_partition.current.partition}:ec2:${region}:${data.aws_caller_identity.current.account_id}:instance/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Project"
      values   = [var.project_tag]
    }

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/AutoStop"
      values   = ["true"]
    }
  }

}

resource "aws_iam_role_policy" "budget_stop" {
  name   = "spectral-budget-stop"
  role   = aws_iam_role.budget_stop.id
  policy = data.aws_iam_policy_document.budget_stop.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.budget_stop.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "budget_stop" {
  name              = "/aws/lambda/spectral-budget-stop"
  retention_in_days = 14
}

resource "aws_lambda_function" "budget_stop" {
  function_name = "spectral-budget-stop"
  description   = "Stops explicitly tagged Spectral EC2 resources after a budget breach"
  role          = aws_iam_role.budget_stop.arn
  runtime       = "python3.14"
  handler       = "budget_stop.handler"
  architectures = ["arm64"]
  timeout       = 60
  memory_size   = 128

  filename         = data.archive_file.budget_stop.output_path
  source_code_hash = data.archive_file.budget_stop.output_base64sha256

  environment {
    variables = {
      AUTOSTOP_TAG_VALUE = "true"
      PROJECT_TAG_VALUE  = var.project_tag
      TARGET_REGIONS     = join(",", sort(tolist(var.workload_regions)))
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.budget_stop,
    aws_iam_role_policy.budget_stop,
    aws_iam_role_policy_attachment.lambda_basic,
  ]
}

resource "aws_lambda_permission" "from_shutdown_topic" {
  statement_id  = "AllowShutdownTopic"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.budget_stop.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.shutdown.arn
}

resource "aws_sns_topic_subscription" "budget_stop" {
  topic_arn = aws_sns_topic.shutdown.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.budget_stop.arn

  depends_on = [aws_lambda_permission.from_shutdown_topic]
}
