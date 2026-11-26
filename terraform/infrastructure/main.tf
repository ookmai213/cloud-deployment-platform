provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(var.tags, {
      Project     = var.name
      Environment = var.environment
      ManagedBy   = "terraform"
    })
  }
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  selected_az = var.availability_zone != "" ? var.availability_zone : data.aws_availability_zones.available.names[0]
  common_tags = {
    Name        = var.name
    Project     = var.name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
  instance_arn       = "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.web.id}"
  ecr_repository_arn = aws_ecr_repository.application.arn
}

resource "aws_vpc" "application" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.common_tags, { Name = "${var.name}-vpc" })
}

resource "aws_internet_gateway" "application" {
  vpc_id = aws_vpc.application.id
  tags   = merge(local.common_tags, { Name = "${var.name}-igw" })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.application.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = local.selected_az
  map_public_ip_on_launch = true
  tags                    = merge(local.common_tags, { Name = "${var.name}-public" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.application.id
  tags   = merge(local.common_tags, { Name = "${var.name}-public" })
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.application.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "web" {
  name        = "${var.name}-web"
  description = "Public web ingress only; administration uses Systems Manager."
  vpc_id      = aws_vpc.application.id
  tags        = merge(local.common_tags, { Name = "${var.name}-web" })

  dynamic "ingress" {
    for_each = toset(var.http_ingress_cidrs)
    content {
      description = "HTTP and ACME validation"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  dynamic "ingress" {
    for_each = toset(var.https_ingress_cidrs)
    content {
      description = "HTTPS application traffic"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    description = "Outbound package, SSM, ECR and certificate traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecr_repository" "application" {
  name                 = var.name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(local.common_tags, { Name = "${var.name}-ecr" })
}

resource "aws_cloudwatch_log_group" "containers" {
  name              = "/${var.name}/containers"
  retention_in_days = var.cloudwatch_log_retention_days
  tags              = merge(local.common_tags, { Name = "${var.name}-containers" })
}

resource "aws_iam_role" "instance" {
  name = "${var.name}-instance"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
  tags = merge(local.common_tags, { Name = "${var.name}-instance" })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "instance_runtime" {
  name = "${var.name}-runtime"
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = local.ecr_repository_arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.containers.arn}:*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "web" {
  name = "${var.name}-instance"
  role = aws_iam_role.instance.name
  tags = merge(local.common_tags, { Name = "${var.name}-instance" })
}

resource "aws_instance" "web" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = var.ec2_key_pair_name != "" ? var.ec2_key_pair_name : null
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.web.id]
  iam_instance_profile        = aws_iam_instance_profile.web.name
  associate_public_ip_address = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    encrypted             = true
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    delete_on_termination = true
  }

  tags = merge(local.common_tags, { Name = var.name })
}

resource "aws_eip" "web" {
  count  = var.allocate_elastic_ip ? 1 : 0
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${var.name}-eip" })
}

resource "aws_eip_association" "web" {
  count         = var.allocate_elastic_ip ? 1 : 0
  allocation_id = aws_eip.web[0].id
  instance_id   = aws_instance.web.id
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.name}-${var.environment}-cpu-high"
  alarm_description   = "Average EC2 CPU utilization exceeded 80% for two periods."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"
  dimensions = {
    InstanceId = aws_instance.web.id
  }
  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "status_check_failed" {
  alarm_name          = "${var.name}-${var.environment}-status-check-failed"
  alarm_description   = "EC2 instance or system status checks failed."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  dimensions = {
    InstanceId = aws_instance.web.id
  }
  tags = local.common_tags
}

resource "aws_iam_role" "github_publish" {
  count = var.github_oidc_provider_arn != "" && var.github_repository != "" ? 1 : 0
  name  = "${var.name}-github-publish"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.github_oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:ref:refs/heads/main"
        }
      }
    }]
  })
  tags = merge(local.common_tags, { Name = "${var.name}-github-publish" })
}

resource "aws_iam_role_policy" "github_publish" {
  count = var.github_oidc_provider_arn != "" && var.github_repository != "" ? 1 : 0
  name  = "${var.name}-github-publish"
  role  = aws_iam_role.github_publish[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = local.ecr_repository_arn
      },
    ]
  })
}

resource "aws_iam_role" "github_deploy" {
  count = var.github_oidc_provider_arn != "" && var.github_repository != "" ? 1 : 0
  name  = "${var.name}-github-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.github_oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:environment:staging"
        }
      }
    }]
  })
  tags = merge(local.common_tags, { Name = "${var.name}-github-deploy" })
}

resource "aws_iam_role_policy" "github_deploy" {
  count = var.github_oidc_provider_arn != "" && var.github_repository != "" ? 1 : 0
  name  = "${var.name}-github-deploy"
  role  = aws_iam_role.github_deploy[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}::document/AWS-RunShellScript",
          local.instance_arn,
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetCommandInvocation",
          "ssm:ListCommandInvocations",
          "ssm:ListCommands",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      },
    ]
  })
}
