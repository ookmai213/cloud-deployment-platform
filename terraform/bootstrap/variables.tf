variable "aws_region" {
  description = "AWS region used for the independent Terraform state bucket."
  type        = string
  default     = "ap-south-1"
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name dedicated to this project's Terraform state."
  type        = string

  validation {
    condition     = length(var.state_bucket_name) >= 3 && length(var.state_bucket_name) <= 63
    error_message = "state_bucket_name must be a valid 3-63 character S3 bucket name."
  }
}

variable "tags" {
  description = "Tags applied to project state resources."
  type        = map(string)
  default = {
    Project   = "linux-web-infrastructure"
    ManagedBy = "terraform"
  }
}
