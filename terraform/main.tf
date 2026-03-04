terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ── Look up the latest Amazon Linux 2 AMI ──────────────────────────────────
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}


provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Get current AWS account ID
data "aws_caller_identity" "current" {}


# VPC Module
module "vpc" {
  source = "./modules/vpc"

  project_name       = var.project_name
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  public_subnets     = var.public_subnets
  private_subnets    = var.private_subnets
}

# Key Pair Module
module "keypair" {
  source = "./modules/keypair"

  project_name = var.project_name
  environment  = var.environment
}

# Security Groups Module
module "security_groups" {
  source = "./modules/security"

  project_name = var.project_name
  environment  = var.environment
  vpc_id       = module.vpc.vpc_id
  vpc_cidr     = var.vpc_cidr
  allowed_ips  = var.allowed_ips
}

# Jenkins EC2 Module
module "jenkins" {
  source = "./modules/jenkins"

  project_name               = var.project_name
  environment                = var.environment
  ami_id                     = data.aws_ami.amazon_linux_2.id
  instance_type              = var.jenkins_instance_type
  key_name                   = module.keypair.key_name
  subnet_id                  = module.vpc.public_subnets[0]
  security_group_ids         = [module.security_groups.jenkins_sg_id]
  jenkins_admin_password     = var.jenkins_admin_password
  aws_region                 = var.aws_region
  additional_iam_policy_arns = [module.monitoring.cloudwatch_agent_policy_arn]
}

# Application EC2 Module
module "app_server" {
  source = "./modules/ec2"

  project_name         = var.project_name
  environment          = var.environment
  ami_id               = data.aws_ami.amazon_linux_2.id
  instance_type        = var.app_instance_type
  key_name             = module.keypair.key_name
  subnet_id            = module.vpc.public_subnets[1]
  security_group_ids   = [module.security_groups.app_sg_id]
  user_data            = templatefile("${path.module}/scripts/app-server-setup.sh", {
    project_name = var.project_name
    environment  = var.environment
    aws_region   = var.aws_region
  })
  iam_instance_profile = module.monitoring.cloudwatch_agent_profile_name
  name                 = "app-server"
}

# Monitoring EC2 Module (Prometheus + Grafana + Alertmanager + Node Exporter)
module "monitoring_server" {
  source = "./modules/ec2"

  project_name         = var.project_name
  environment          = var.environment
  ami_id               = data.aws_ami.amazon_linux_2.id
  instance_type        = var.monitoring_instance_type
  key_name             = module.keypair.key_name
  subnet_id            = module.vpc.public_subnets[0]
  security_group_ids   = [module.security_groups.monitoring_sg_id]
  iam_instance_profile = module.monitoring.cloudwatch_agent_profile_name
  name                 = "monitoring"

  # templatefile injects the app server's private IP and credentials so the
  # setup script can write prometheus.yml and the docker-compose .env file
  # without any hardcoded values.
  user_data = templatefile("${path.module}/scripts/monitoring-setup.sh", {
    app_server_ip          = module.app_server.private_ip
    grafana_admin_password = var.grafana_admin_password
    git_repo_url           = var.git_repo_url
  })
}

# CloudWatch and GuardDuty Monitoring Module
module "monitoring" {
  source = "./modules/monitoring"

  project_name        = var.project_name
  environment         = var.environment
  aws_region          = var.aws_region
  account_id          = data.aws_caller_identity.current.account_id
  vpc_id              = module.vpc.vpc_id
  jenkins_instance_id = module.jenkins.instance_id
  app_instance_id     = module.app_server.instance_id
  alert_email         = var.alert_email
  log_retention_days  = var.log_retention_days
  enable_guardduty    = var.enable_guardduty
}
