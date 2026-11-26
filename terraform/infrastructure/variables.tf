variable "aws_region" {
  description = "Deployment region."
  type        = string
  default     = "ap-south-1"
}

variable "name" {
  description = "Short project name used in AWS resource names."
  type        = string
  default     = "linux-web-infrastructure"
}

variable "environment" {
  description = "Environment label used for tagging."
  type        = string
  default     = "staging"
}

variable "vpc_cidr" {
  description = "IPv4 CIDR for the dedicated single-environment VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "public_subnet_cidr" {
  description = "IPv4 CIDR for the single public application subnet."
  type        = string
  default     = "10.42.1.0/24"
}

variable "availability_zone" {
  description = "Optional availability zone. Defaults to the first available zone in the selected region."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type; monitoring profile may require a larger instance."
  type        = string
  default     = "t3.small"
}

variable "ec2_key_pair_name" {
  description = "Existing EC2 key-pair name for Ansible SSH tunneled through SSM. Private key stays outside the repository."
  type        = string
  default     = ""
}

variable "root_volume_size" {
  description = "Encrypted gp3 root volume size in GiB."
  type        = number
  default     = 20
}

variable "allocate_elastic_ip" {
  description = "Allocate a stable public IPv4 address for DNS and certificate stability."
  type        = bool
  default     = true
}

variable "http_ingress_cidrs" {
  description = "IPv4 CIDRs allowed to reach HTTP for ACME validation and HTTPS redirect."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "https_ingress_cidrs" {
  description = "IPv4 CIDRs allowed to reach the public HTTPS service."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cloudwatch_log_retention_days" {
  description = "Retention period for container logs in CloudWatch Logs."
  type        = number
  default     = 30
}

variable "github_oidc_provider_arn" {
  description = "ARN of the account-level GitHub Actions OIDC provider. Leave empty to omit the deploy role."
  type        = string
  default     = ""
}

variable "github_repository" {
  description = "GitHub repository in owner/name form. Required with github_oidc_provider_arn."
  type        = string
  default     = ""

  validation {
    condition     = var.github_repository == "" || can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be empty or use owner/repository form."
  }
}

variable "tags" {
  description = "Additional tags applied to infrastructure."
  type        = map(string)
  default = {
    Owner = "portfolio"
  }
}
