output "role_arn" {
  description = "ARN of the Terraform state role"
  value       = aws_iam_role.terraform_state.arn
}