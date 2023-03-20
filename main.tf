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
  default     = "ami-0555fb873f696dcaa"
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
    from_port   = 22
    to_port     = 22
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 创建3个instances
resource "aws_instance" "example_ec2" {
  ami                         = var.ami
  instance_type               = "t2.micro"
  associate_public_ip_address = true
  key_name                    = "my-key"
  iam_instance_profile        = aws_iam_instance_profile.profile.name
  # user_data = file("user_data.sh")
  user_data = <<EOF
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
  cd /tmp
  java -jar /tmp/demo-1.0-SNAPSHOT.jar -Dspring.config.location=/tmp/application.yml
  EOF
  count     = 3
  subnet_id = aws_subnet.public[count.index].id
  vpc_security_group_ids = [
    aws_security_group.webapp_sg.id,
  ]
  disable_api_termination = true
  lifecycle {
    create_before_destroy = true
  }
}

# 创建volume
resource "aws_ebs_volume" "example_volume" {
  count             = 3
  availability_zone = aws_instance.example_ec2[count.index].availability_zone
  size              = 50
  type              = "gp2"
}

# 给每个instance挂载一个volume，挂载地址在instance的“/dev/sdh”地址
resource "aws_volume_attachment" "example" {
  device_name = "/dev/sdh"
  count       = 3
  volume_id   = aws_ebs_volume.example_volume[count.index].id
  instance_id = aws_instance.example_ec2[count.index].id
}

# 创建三个弹性IP
resource "aws_eip" "public_ips" {
  count = 3
  vpc   = true
  tags = {
    Name = "public-ip-${count.index}"
  }
}

# 把创建的弹性IP与instances关联
resource "aws_eip_association" "public_ip_assoc" {
  count         = 3
  allocation_id = aws_eip.public_ips[count.index].id

  # Remove existing association for this Elastic IP
  provisioner "local-exec" {
    command = <<-EOT
      sleep 5
      aws ec2 disassociate-address --public-ip ${aws_eip.public_ips[count.index].public_ip} --region ${var.region}
    EOT
  }

  instance_id = aws_instance.example_ec2[count.index].id
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
# 数量和private subnet数量对应
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
          "arn:aws:s3:::${aws_s3_bucket.bucket.bucket}/*"]
        },
        {
          Effect   = "Allow",
          Action   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetLifeCycleConfiguration"],
          Resource = "arn:aws:s3:::${aws_s3_bucket.bucket.bucket}"
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

#创建profile
resource "aws_iam_instance_profile" "profile" {
  name = "profile"
  role = aws_iam_role.ec2_role.name
}

#创建route53 record
resource "aws_route53_record" "aws_a_record"{
  zone_id=data.aws_availability_zones.available.names[0]
  name="dev.leiyang.me"
  type = "A"
  ttl = "60"
  records = [aws_instance.example.public_ip]
}
