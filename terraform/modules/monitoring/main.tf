# CloudWatch and GuardDuty Monitoring Module
# Provides infrastructure monitoring, logging, and security detection

# ── CloudWatch Agent IAM Role and Policy ─────────────────────────────────────
resource "aws_iam_role" "cloudwatch_agent" {
  name = "${var.project_name}-${var.environment}-cloudwatch-agent-role"

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
}

resource "aws_iam_policy" "cloudwatch_agent" {
  name        = "${var.project_name}-${var.environment}-cloudwatch-agent-policy"
  description = "Policy for CloudWatch agent to put metrics and logs"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "cloudwatch:PutMetricDashboard",
          "ec2:DescribeTags",
          "ec2:DescribeInstances",
          "ssm:GetParameter"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.cloudwatch_agent.name
  policy_arn = aws_iam_policy.cloudwatch_agent.arn
}

resource "aws_iam_instance_profile" "cloudwatch_agent" {
  name = "${var.project_name}-${var.environment}-cloudwatch-agent-profile"
  role = aws_iam_role.cloudwatch_agent.name
}

# ── CloudWatch Metric Alarms ────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "cpu_utilization" {
  alarm_name          = "${var.project_name}-${var.environment}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors EC2 CPU utilization"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    InstanceId = var.jenkins_instance_id
  }
}

resource "aws_cloudwatch_metric_alarm" "app_cpu_utilization" {
  alarm_name          = "${var.project_name}-${var.environment}-app-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors App Server CPU utilization"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    InstanceId = var.app_instance_id
  }
}

resource "aws_cloudwatch_metric_alarm" "disk_utilization" {
  alarm_name          = "${var.project_name}-${var.environment}-high-disk"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "disk_used_percent"
  namespace           = "CWAgent"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors disk utilization"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    InstanceId = var.jenkins_instance_id
    path       = "/"
  }
}

# ── SNS Topic for Alerts ────────────────────────────────────────────────────
resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-${var.environment}-alerts"
}

resource "aws_sns_topic_subscription" "email_alert" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── GuardDuty ────────────────────────────────────────────────────────────────
# Check if GuardDuty detector already exists in this region
data "aws_guardduty_detector" "existing" {
  count = var.enable_guardduty ? 1 : 0
}

# GuardDuty is regional - only create if one doesn't exist
resource "aws_guardduty_detector" "main" {
  count  = var.enable_guardduty && length(data.aws_guardduty_detector.existing) == 0 ? 1 : 0
  enable = true
}

# ── CloudWatch Logs ─────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "jenkins" {
  name              = "/${var.project_name}/${var.environment}/jenkins"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project_name}/${var.environment}/app"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "monitoring" {
  name              = "/${var.project_name}/${var.environment}/monitoring"
  retention_in_days = var.log_retention_days
}

# ── VPC Flow Logs ───────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "vpc_flow" {
  name              = "/${var.project_name}/${var.environment}/vpc-flow-logs"
  retention_in_days = var.log_retention_days
}

# IAM role for VPC Flow Logs
resource "aws_iam_role" "vpc_flow_logs" {
  name = "${var.project_name}-${var.environment}-vpc-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "vpc_flow_logs_policy" {
  name = "${var.project_name}-${var.environment}-vpc-flow-logs-policy"
  role = aws_iam_role.vpc_flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = aws_cloudwatch_log_group.vpc_flow.arn
      }
    ]
  })
}

resource "aws_flow_log" "vpc" {
  log_destination_type = "cloud-watch-logs"
  log_group_name       = aws_cloudwatch_log_group.vpc_flow.name
  vpc_id               = var.vpc_id
  traffic_type         = "ALL"
  iam_role_arn         = aws_iam_role.vpc_flow_logs.arn
}

# ── CloudTrail and S3 Bucket ────────────────────────────────────────────────
resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket        = "${var.project_name}-${var.environment}-cloudtrail-logs-${var.account_id}"
  force_destroy = true

  tags = {
    Name = "${var.project_name}-${var.environment}-cloudtrail-logs"
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  rule {
    id     = "archive-old-logs"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail_logs.arn
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail_logs.arn}/AWSLogs/${var.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

resource "aws_cloudtrail" "main" {
  name                          = "${var.project_name}-${var.environment}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  depends_on = [aws_s3_bucket_policy.cloudtrail_logs]
}

# ── CloudWatch Dashboard ─────────────────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project_name}-${var.environment}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", var.jenkins_instance_id],
            [".", "CPUUtilization", "InstanceId", var.app_instance_id]
          ]
          period = 300
          stat   = "Average"
          region = var.aws_region
          title  = "CPU Utilization"
        }
      },
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/EC2", "NetworkIn", "InstanceId", var.jenkins_instance_id],
            [".", "NetworkIn", "InstanceId", var.app_instance_id]
          ]
          period = 300
          stat   = "Sum"
          region = var.aws_region
          title  = "Network Traffic In"
        }
      },
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/EC2", "StatusCheckFailed", "InstanceId", var.jenkins_instance_id],
            [".", "StatusCheckFailed", "InstanceId", var.app_instance_id]
          ]
          period = 60
          stat   = "Maximum"
          region = var.aws_region
          title  = "Instance Health"
        }
      }
    ]
  })
}
