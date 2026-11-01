output "state_bucket_name" {
  value = aws_s3_bucket.state.bucket
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}
