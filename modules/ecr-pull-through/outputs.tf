output "registry_k8s_io_prefix" {
  value = aws_ecr_pull_through_cache_rule.registry_k8s_io.ecr_repository_prefix
}

output "ecr_public_prefix" {
  value = aws_ecr_pull_through_cache_rule.ecr_public.ecr_repository_prefix
}

output "docker_hub_prefix" {
  value = aws_ecr_pull_through_cache_rule.docker_hub.ecr_repository_prefix
}