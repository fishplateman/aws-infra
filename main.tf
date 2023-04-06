variable "region" {
  type        = string
  description = "The AWS region to deploy resources"
  default     = "us-east-1"
}
variable "profile" {
  type        = string
  description = "The AWS profile to use for authentication"
  default     = "demo"
}
variable "ami" {
  type        = string
  description = "The ami id to use for building instances"
  default     = "ami-09753caebba6df40e"
}

variable "zone_id" {
  type        = string
  description = "The zone id to use for building Route53"
  default     = "Z05840372REQB8AHW5V22"
}

variable "subdomain" {
  type        = string
  description = "The subdomain name"
  default     = "demo.kittyman.me"
}

locals {
  cloudwatch_namespace = "webapp"
}

resource "random_string" "bucket_name" {
  length  = 8
  special = false
  upper   = false
}

provider "aws" {
  region  = var.region
  profile = var.profile
}

resource "aws_vpc" "mainvpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "MyVPC"
  }
}

# Declare the data source
data "aws_availability_zones" "available" {
  state = "available"
}

# 私有子网
resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.mainvpc.id
  cidr_block        = cidrsubnet("10.0.0.0/16", 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name = "private-subnet-${count.index}"
  }
}

# 公有子网
resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.mainvpc.id
  cidr_block              = cidrsubnet("10.0.0.0/16", 8, count.index + 3)
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name = "public-subnet-${count.index}"
  }
}

# 创建subnet group
resource "aws_db_subnet_group" "my_db_subnet_group" {
  name        = "my-db-subnet-group"
  description = "My DB Subnet Group"
  subnet_ids = [
    aws_subnet.private[0].id,
    aws_subnet.private[1].id,
    aws_subnet.private[2].id
  ]
  tags = {
    Name = "My DB Subnet Group"
  }
}

# 创建Internet网关
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.mainvpc.id

  tags = {
    Name = "My_Internet_Gateway"
  }
}

# 创建公网路由表
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.mainvpc.id
  # route {
  #   cidr_block            = "0.0.0.0/0"
  #   vpc_endpoint_id       = aws_vpc_endpoint.s3.id
  # }
  tags = {
    Name = "MyPublicRoutetable"
  }
  # depends_on = [aws_vpc_endpoint.s3]
}


# 创建私网路由表
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.mainvpc.id
  tags = {
    Name = "MyPrivateRoutetable"
  }
}

# 把公有子网和公有路由表连接起来
resource "aws_route_table_association" "public_route_assoc" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# 把私有子网和私有路由表连接起来
resource "aws_route_table_association" "private_route_assoc" {
  count          = 3
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# 创建公网路由，CIDR_block为"0.0.0.0/0"，网关为internet网关
resource "aws_route" "public_igw_route" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gw.id
}


# 创建webapp安全组，22,80,443开放TCP请求接收，发出请求无限制
resource "aws_security_group" "webapp_sg" {
  name_prefix = "webapp-sg-"
  vpc_id      = aws_vpc.mainvpc.id

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "TCP"
    cidr_blocks     = ["10.0.0.0/16"]
    security_groups = [aws_security_group.lb_sg.id]
  }

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "TCP"
    cidr_blocks     = ["10.0.0.0/16"]
    security_groups = [aws_security_group.lb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# user data模板
data "template_file" "user_data" {
  template = <<EOF
#!/bin/bash
echo "Configuring webapp with environment variables"
sudo yum update -y
sudo yum upgrade -y
sudo yum clean all
sudo yum install -y sed

# Replace database credentials and S3 bucket name in application.yml
sed -i "s|username:.*|username: ${aws_db_instance.db.username}|g" /tmp/application.yml
sed -i "s|password:.*|password: ${aws_db_instance.db.password}|g" /tmp/application.yml
sed -i "s|url:.*|url: jdbc:mysql://${aws_db_instance.db.endpoint}/csye6225?autoReconnect=true\&useSSL=false\&createDatabaseIfNotExist=true|g" /tmp/application.yml
sed -i "s|bucket-name:.*|bucket-name: ${aws_s3_bucket.bucket.bucket}|g" /tmp/application.yml

# Start the webapp
sudo systemctl restart webapp
EOF
}

# 负载均衡安全组
resource "aws_security_group" "lb_sg" {
  name   = "load_balancer_sg"
  vpc_id = aws_vpc.mainvpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 启动模板
resource "aws_launch_template" "lt" {
  name = "example_launch_template"

  image_id      = var.ami
  instance_type = "t2.micro"
  key_name      = "my-key"
  user_data     = base64encode(data.template_file.user_data.rendered)

  iam_instance_profile {
    name = aws_iam_instance_profile.profile.name
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 50
      volume_type           = "gp2"
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = true
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.webapp_sg.id]
  }
}

# 扩展策略
resource "aws_autoscaling_policy" "asg_scale_out_policy" {
  name                   = "scale_out_policy"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  policy_type            = "SimpleScaling"
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 60
}

# 收缩策略
resource "aws_autoscaling_policy" "asg_scale_in_policy" {
  name                   = "scale_in_policy"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  policy_type            = "SimpleScaling"
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 60
}

resource "aws_cloudwatch_metric_alarm" "scale_out_alarm" {
  alarm_name          = "scale_out_alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "60"
  statistic           = "Average"
  threshold           = "5"
  alarm_description   = "This metric checks if the CPU usage is greater than or equal to 5%"
  alarm_actions       = [aws_autoscaling_policy.asg_scale_out_policy.arn]
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.asg.name
  }
}

resource "aws_cloudwatch_metric_alarm" "scale_in_alarm" {
  alarm_name          = "scale_in_alarm"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "60"
  statistic           = "Average"
  threshold           = "3"
  alarm_description   = "This metric checks if the CPU usage is less than or equal to 3%"
  alarm_actions       = [aws_autoscaling_policy.asg_scale_in_policy.arn]
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.asg.name
  }
}



# 自动伸缩组
resource "aws_autoscaling_group" "asg" {
  name             = "csye6225-asg-spring2023"
  min_size         = 1
  max_size         = 3
  desired_capacity = 1
  default_cooldown = 60
  # 一分钟
  health_check_grace_period = 60
  launch_template {
    id      = aws_launch_template.lt.id
    version = "$Latest"
  }
  target_group_arns   = [aws_lb_target_group.alb_tg.arn]
  vpc_zone_identifier = [aws_subnet.public[0].id, aws_subnet.public[1].id, aws_subnet.public[2].id]

  tag {
    key                 = "Name"
    value               = "csye6225-asg-instance"
    propagate_at_launch = true
  }
}

# 目标组
resource "aws_lb_target_group" "alb_tg" {
  name     = "csye6225-lb-alb-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.mainvpc.id

  target_type = "instance"

  health_check {
    interval            = 30
    path                = "/healthz"
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    protocol            = "HTTP"
    port                = 8080
  }
}

# 创建 ACM 证书
resource "aws_acm_certificate" "example_cert" {
  domain_name       = var.subdomain
  validation_method = "DNS"

  tags = {
    Terraform = "true"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# 获取证书验证记录
resource "aws_route53_record" "cert_validation_record" {
  for_each = {
  for dvo in aws_acm_certificate.example_cert.domain_validation_options : dvo.domain_name => {
    name   = dvo.resource_record_name
    record = dvo.resource_record_value
    type   = dvo.resource_record_type
  }
  }

  name    = each.value.name
  type    = each.value.type
  zone_id = var.zone_id
  records = [each.value.record]
  ttl     = 60
}

# 确认证书已经验证
resource "aws_acm_certificate_validation" "example_cert_validation" {
  certificate_arn         = aws_acm_certificate.example_cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation_record : record.fqdn]
}

# 创建 Application Load Balancer
resource "aws_lb" "lb" {
  name               = "csye6225-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = [aws_subnet.public[0].id, aws_subnet.public[1].id, aws_subnet.public[2].id]
}

# 负载均衡监听器HTTPS
resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.lb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate_validation.example_cert_validation.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_tg.arn
  }
}

# 负载均衡监听器HTTP
resource "aws_lb_listener" "http_front_end" {
  load_balancer_arn = aws_lb.lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_tg.arn
  }
}


# database 安全组
resource "aws_security_group" "database_sg" {
  name_prefix = "database-sg-"
  vpc_id      = aws_vpc.mainvpc.id

  # 接受webaapp_instance发送的流量
  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "TCP"
    cidr_blocks = ["10.0.0.0/16"]
    # 允许名字为web_sg的安全组发来的流量
    security_groups = [aws_security_group.webapp_sg.id]
  }

  ingress {
    from_port   = 22 // SSH access for management
    to_port     = 22
    protocol    = "TCP"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# RDS parameter group
resource "aws_db_parameter_group" "db_param_group" {
  name_prefix = "rds-parameter-group-"
  family      = "mysql8.0"
  description = "RDS Parameter Group"
}

# RDS instance
resource "aws_db_instance" "db" {
  # count                  = 3
  # identifier             = "csye6225-${count.index}"
  identifier             = "csye6225"
  allocated_storage      = 20
  engine                 = "MySQL"
  engine_version         = "8.0.25"
  instance_class         = "db.t3.micro"
  multi_az               = false
  db_name                = "csye6225"
  username               = "csye6225"
  password               = "Password123!"
  db_subnet_group_name   = aws_db_subnet_group.my_db_subnet_group.name
  parameter_group_name   = aws_db_parameter_group.db_param_group.name
  vpc_security_group_ids = [aws_security_group.database_sg.id]
  publicly_accessible    = false
  skip_final_snapshot    = true
  tags = {
    DatabaseName = "csye6225"
  }
}

# 创建bucket
resource "aws_s3_bucket" "bucket" {
  bucket        = "my-bucket-${terraform.workspace}-${random_string.bucket_name.result}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "bucket" {
  bucket = aws_s3_bucket.bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bucket" {
  bucket = aws_s3_bucket.bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "bucket" {
  rule {
    id     = "transition_objects_STANDARD"
    status = "Enabled"
    filter {
      prefix = ""
    }
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
  }
  bucket = aws_s3_bucket.bucket.id
}

resource "aws_s3_bucket_acl" "bucket" {
  bucket = aws_s3_bucket.bucket.id
  acl    = "private"
}

# 创建IAM policy
resource "aws_iam_policy" "s3_policy" {
  name        = "WebAppS3"
  description = "An IAM policy created for intances to perform S3 buckets"
  policy = jsonencode(
    {
      "Version" = "2012-10-17",
      "Statement" = [
        {
          "Action" : [
            "s3:PutObject",
            "s3:PutObjectAcl",
            "s3:GetObject",
            "s3:GetObjectAcl",
            "s3:DeleteObject",
            "s3:DeleteObjectAcl"
          ]
          "Effect" : "Allow",
          "Resource" : [
            "arn:aws:s3:::${aws_s3_bucket.bucket.bucket}",
            "arn:aws:s3:::${aws_s3_bucket.bucket.bucket}/*"
          ]
        },
        {
          Effect = "Allow",
          Action = [
            "s3:ListBucket",
            "s3:GetBucketLocation",
            "s3:GetLifeCycleConfiguration"
          ],
          Resource = [
            "arn:aws:s3:::${aws_s3_bucket.bucket.bucket}",
            "arn:aws:s3:::${aws_s3_bucket.bucket.bucket}/*"
          ]
        }
      ]
    })

}


# 创建了一个名为EC2-CSYE6225的IAM角色，
# 该角色允许EC2服务假装成这个角色来访问其他资源。
resource "aws_iam_role" "ec2_role" {
  name = "EC2-CSYE6225"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
  tags = {
    Name = "EC2-CSYE6225"
  }
}

# 把IAM role绑定上IAM policy
resource "aws_iam_role_policy_attachment" "ec2_policy_attachment" {
  policy_arn = aws_iam_policy.s3_policy.arn
  role       = aws_iam_role.ec2_role.name
}

# 将 CloudWatch IAM policy 附加到 IAM 角色
resource "aws_iam_role_policy_attachment" "cloudwatch_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = aws_iam_role.ec2_role.name
}

#创建profile
resource "aws_iam_instance_profile" "profile" {
  name = "profile"
  role = aws_iam_role.ec2_role.name
}

#创建route53 record
resource "aws_route53_record" "a_record" {
  zone_id = var.zone_id
  name    = var.subdomain
  type    = "A"

  alias {
    name                   = aws_lb.lb.dns_name
    zone_id                = aws_lb.lb.zone_id
    evaluate_target_health = true
  }

  depends_on = [
    aws_lb.lb
  ]
}

