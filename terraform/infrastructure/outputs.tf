output "instance_id" {
  description = "EC2 instance ID for SSM administration."
  value       = aws_instance.web.id
}

output "public_ip" {
  description = "Public address for the domain A record and HTTPS endpoint."
  value       = var.allocate_elastic_ip ? aws_eip.web[0].public_ip : aws_instance.web.public_ip
}

output "ecr_repository_url" {
  description = "Immutable ECR repository for application image releases."
  value       = aws_ecr_repository.application.repository_url
}

output "github_publish_role_arn" {
  description = "Optional OIDC image-publishing role ARN, restricted to main."
  value       = try(aws_iam_role.github_publish[0].arn, null)
}

output "github_deploy_role_arn" {
  description = "Optional OIDC deployment role ARN, restricted to the protected staging environment."
  value       = try(aws_iam_role.github_deploy[0].arn, null)
}

output "cloudwatch_container_log_group" {
  description = "Container log group name."
  value       = aws_cloudwatch_log_group.containers.name
}
