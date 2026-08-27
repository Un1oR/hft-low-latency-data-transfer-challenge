data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  boundary_name = "spectral-workload-boundary"
  boundary_arn  = "arn:${data.aws_partition.current.partition}:iam::${var.target_account_id}:policy/${local.boundary_name}"

  allowed_managed_policy_arns = [
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
  ]
}

check "correct_account" {
  assert {
    condition     = data.aws_caller_identity.current.account_id == var.target_account_id
    error_message = "Bootstrap разрешён только для AWS account ${var.target_account_id}."
  }
}

data "aws_iam_policy_document" "workload_boundary" {
  statement {
    sid       = "DescribeInstances"
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid    = "TaggedEc2Lifecycle"
    effect = "Allow"
    actions = [
      "ec2:StopInstances",
      "ec2:TerminateInstances",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:${var.workload_region}:${var.target_account_id}:instance/*",
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

  statement {
    # Исторические имя bucket и префикс source/ сохраняются, чтобы runner мог
    # перейти с ZIP исходников на .deb без повторного root bootstrap.
    sid       = "ReadRunnerSource"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::spectral-runner-source-${var.target_account_id}-${var.workload_region}/source/*"]
  }

  statement {
    sid       = "WriteRunnerResults"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::spectral-runner-source-${var.target_account_id}-${var.workload_region}/results/*"]
  }

  statement {
    sid       = "ReadRunnerBucketEncryption"
    effect    = "Allow"
    actions   = ["s3:GetEncryptionConfiguration"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::spectral-runner-source-${var.target_account_id}-${var.workload_region}"]
  }

  statement {
    sid    = "WriteBudgetStopLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:us-east-1:${var.target_account_id}:log-group:/aws/lambda/spectral-budget-stop:*",
    ]
  }

  statement {
    sid    = "SsmManagedInstanceCore"
    effect = "Allow"
    actions = [
      "ssm:DescribeAssociation",
      "ssm:DescribeDocument",
      "ssm:GetDeployablePatchSnapshotForInstance",
      "ssm:GetDocument",
      "ssm:GetManifest",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:ListAssociations",
      "ssm:ListInstanceAssociations",
      "ssm:PutComplianceItems",
      "ssm:PutConfigurePackageResult",
      "ssm:PutInventory",
      "ssm:UpdateAssociationStatus",
      "ssm:UpdateInstanceAssociationStatus",
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
      "ec2messages:AcknowledgeMessage",
      "ec2messages:DeleteMessage",
      "ec2messages:FailMessage",
      "ec2messages:GetEndpoint",
      "ec2messages:GetMessages",
      "ec2messages:SendReply",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = local.boundary_name
  description = "Maximum permissions for Spectral workload service roles"
  policy      = data.aws_iam_policy_document.workload_boundary.json
}

resource "aws_servicequotas_service_quota" "standard_on_demand_vcpus" {
  region       = var.workload_region
  service_code = "ec2"
  quota_code   = "L-1216C47A"
  value        = var.standard_on_demand_vcpu_quota
}

data "aws_iam_policy_document" "developer_bootstrap" {
  statement {
    sid       = "CreateBoundedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateRole"]
    resources = ["arn:${data.aws_partition.current.partition}:iam::${var.target_account_id}:role/spectral-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.workload_boundary.arn]
    }
  }

  statement {
    sid    = "ManageBoundedRoles"
    effect = "Allow"
    actions = [
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies",
      "iam:ListRoleTags",
      "iam:PutRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:iam::${var.target_account_id}:role/spectral-*"]
  }

  statement {
    sid    = "AttachApprovedManagedPolicies"
    effect = "Allow"
    actions = [
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:iam::${var.target_account_id}:role/spectral-*"]

    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = local.allowed_managed_policy_arns
    }
  }

  statement {
    sid    = "ManageProjectInstanceProfiles"
    effect = "Allow"
    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:ListInstanceProfileTags",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${var.target_account_id}:instance-profile/spectral-*",
      "arn:${data.aws_partition.current.partition}:iam::${var.target_account_id}:role/spectral-*",
    ]
  }

  statement {
    sid     = "PassOnlyProjectRoles"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${var.target_account_id}:role/spectral-*",
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "ec2.amazonaws.com",
        "lambda.amazonaws.com",
        "scheduler.amazonaws.com",
      ]
    }
  }

  statement {
    sid    = "ReadApprovedManagedPolicies"
    effect = "Allow"
    actions = [
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
    ]
    resources = concat(local.allowed_managed_policy_arns, [aws_iam_policy.workload_boundary.arn])
  }
}

resource "aws_iam_policy" "developer_bootstrap" {
  name        = "spectral-terraform-service-roles"
  description = "Delegated management of bounded Spectral service roles"
  policy      = data.aws_iam_policy_document.developer_bootstrap.json
}

resource "aws_iam_user_policy_attachment" "developer_bootstrap" {
  user       = var.target_user_name
  policy_arn = aws_iam_policy.developer_bootstrap.arn
}
