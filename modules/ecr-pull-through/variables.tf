variable "environment" {
  description = "Environment name"
  type        = string
}

variable "docker_hub_username" {
  description = "Docker Hub username for pull through cache"
  type        = string
  default     = ""
}

variable "docker_hub_token" {
  description = "Docker Hub access token for pull through cache"
  type        = string
  sensitive   = true
  default     = ""
}