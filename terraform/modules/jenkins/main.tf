# Store Jenkins admin password in Secrets Manager
resource "aws_secretsmanager_secret" "jenkins_admin_password" {
  name                    = "${var.project_name}-${var.environment}-jenkins-admin-password1"
  description             = "Jenkins admin password for ${var.project_name}-${var.environment}"
  recovery_window_in_days = 0

  tags = {
    Name = "${var.project_name}-${var.environment}-jenkins-admin-password"
  }
}

resource "aws_secretsmanager_secret_version" "jenkins_admin_password" {
  secret_id     = aws_secretsmanager_secret.jenkins_admin_password.id
  secret_string = var.jenkins_admin_password
}

# IAM role for Jenkins EC2 to access Secrets Manager
resource "aws_iam_role" "jenkins" {
  name = "${var.project_name}-${var.environment}-jenkins-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-jenkins-role"
  }
}

resource "aws_iam_role_policy" "jenkins_secrets_access" {
  name = "${var.project_name}-${var.environment}-jenkins-secrets-policy"
  role = aws_iam_role.jenkins.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          aws_secretsmanager_secret.jenkins_admin_password.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "jenkins_additional" {
  count      = length(var.additional_iam_policy_arns)
  role       = aws_iam_role.jenkins.name
  policy_arn = var.additional_iam_policy_arns[count.index]
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.project_name}-${var.environment}-jenkins-profile"
  role = aws_iam_role.jenkins.name
}

resource "aws_instance" "jenkins" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = aws_iam_instance_profile.jenkins.name

  user_data = templatefile("${path.module}/jenkins-setup.sh", {})
  user_data_replace_on_change = true

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-jenkins"
    Type = "Jenkins"
  }
}

resource "aws_eip" "jenkins" {
  instance = aws_instance.jenkins.id
  domain   = "vpc"

  tags = {
    Name = "${var.project_name}-${var.environment}-jenkins-eip"
  }
}
