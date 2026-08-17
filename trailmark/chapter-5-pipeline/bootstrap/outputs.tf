output "plan_role_arn" {
  value       = aws_iam_role.plan.arn
  description = "Role ARN for the pull request plan workflow (role-to-assume)"
}

output "apply_role_arn" {
  value       = aws_iam_role.apply.arn
  description = "Role ARN for the merge-to-main apply workflow (role-to-assume)"
}

output "oidc_provider_arn" {
  value       = aws_iam_openid_connect_provider.github.arn
  description = "Account-global GitHub OIDC provider — one per account, do not recreate"
}
