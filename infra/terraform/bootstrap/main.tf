# Bootstrap.
#
# What must exist before any environment can be applied, and what is created
# once and then left alone: the state backend, the image registry, and the
# federation that lets GitHub Actions authenticate without a key.
#
# Separate from the environments because it needs broader permissions than a
# day-to-day apply, so the pipeline identity never holds them, and because
# it owns the state bucket the environments use, which a configuration
# cannot do for itself. Its own state stays local.

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Terraform state
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  # The recovery path for corrupted state: restore the previous version of
  # the object.
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    # State is small. Keeping a generous history is cheap; keeping it
    # forever is not useful.
    noncurrent_version_expiration {
      noncurrent_days           = 180
      newer_noncurrent_versions = 20
    }
  }
}

# S3 now supports conditional writes for locking, but DynamoDB remains the
# path that works across every Terraform version in use.
resource "aws_dynamodb_table" "lock" {
  name         = "${var.name_prefix}-tf-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Image registry
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "main" {
  for_each = toset(["api", "worker"])

  name                 = "${var.name_prefix}/${each.value}"
  image_tag_mutability = "MUTABLE"
  force_delete         = var.force_delete_ecr

  image_scanning_configuration {
    # Every push is scanned. A vulnerable image that reaches the registry is
    # still caught, even if CI's own scan were skipped.
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "main" {
  for_each = aws_ecr_repository.main

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Untagged layers accumulate on every build and are pure cost"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep enough tagged images that a rollback target always exists"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-", "v"]
          countType     = "imageCountMoreThan"
          countNumber   = 20
        }
        action = { type = "expire" }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# GitHub Actions federation
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS verifies GitHub's certificate chain itself; the thumbprint is
  # retained for older API behaviour.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  tags            = var.tags
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Pinned to one repository. Without this condition the provider trusts
    # every repository on GitHub and any workflow anywhere could assume
    # these roles. This is the single most important line in the file.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:*"]
    }
  }
}

# Two identities, deliberately. The deploy role can push images and change
# workloads; the terraform role can change infrastructure. A compromise of
# the build pipeline therefore cannot rewrite the network or the IAM policy.
resource "aws_iam_role" "deploy" {
  name               = "${var.name_prefix}-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
  tags               = var.tags
}

resource "aws_iam_role" "terraform" {
  name               = "${var.name_prefix}-terraform"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
    ]
    resources = [for repo in aws_ecr_repository.main : repo.arn]
  }

  statement {
    sid       = "DescribeClusterForKubeconfig"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

# Broader by necessity, which is exactly why it is a different identity.
# PowerUserAccess plus IAM is narrower than Administrator and wide enough to
# manage this stack; a production account would replace it with an explicit
# list once the resource set has stopped changing.
resource "aws_iam_role_policy_attachment" "terraform" {
  for_each = toset(var.terraform_policy_arns)

  role       = aws_iam_role.terraform.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "terraform_iam" {
  name = "manage-iam"
  role = aws_iam_role.terraform.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "iam:*Role*", "iam:*Policy*", "iam:*InstanceProfile*",
        "iam:*OpenIDConnectProvider*", "iam:TagRole", "iam:UntagRole",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "terraform_state" {
  name = "terraform-state"
  role = aws_iam_role.terraform.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketVersioning"]
        Resource = aws_s3_bucket.state.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.state.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = aws_dynamodb_table.lock.arn
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Cost control
# ---------------------------------------------------------------------------

# A budget does not cap spend; it makes spend visible before the invoice
# does. On a cluster whose control plane bills by the hour, that matters
# from day one.
resource "aws_budgets_budget" "monthly" {
  count = var.monthly_budget_usd > 0 ? 1 : 0

  name         = "${var.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = var.budget_alert_emails == [] ? [] : [50, 80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = var.budget_alert_emails
    }
  }

  # Forecast catches a runaway before the money is actually gone.
  dynamic "notification" {
    for_each = var.budget_alert_emails == [] ? [] : [100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "FORECASTED"
      subscriber_email_addresses = var.budget_alert_emails
    }
  }
}
