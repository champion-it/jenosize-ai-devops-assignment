# These become GitHub repository variables. None is a secret: federation
# means there is no key to store.
output "github_repository_variables" {
  value = {
    AWS_REGION             = var.region
    AWS_ACCOUNT_ID         = data.aws_caller_identity.current.account_id
    AWS_DEPLOY_ROLE_ARN    = aws_iam_role.deploy.arn
    AWS_TERRAFORM_ROLE_ARN = aws_iam_role.terraform.arn
    TF_STATE_BUCKET        = aws_s3_bucket.state.id
    TF_STATE_LOCK_TABLE    = aws_dynamodb_table.lock.name
    ECR_REGISTRY           = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  }
}

output "ecr_repositories" {
  value = { for k, repo in aws_ecr_repository.main : k => repo.repository_url }
}

output "state_bucket" {
  value = aws_s3_bucket.state.id
}

output "lock_table" {
  value = aws_dynamodb_table.lock.name
}
