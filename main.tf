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

provider "aws" {
  region  = "${var.region}"
  profile = "${var.profile}"
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

resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.mainvpc.id
  cidr_block        = cidrsubnet("10.0.0.0/16", 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name = "private-subnet-${count.index}"
  }
}

resource "aws_subnet" "public" {
  count             = 3
  vpc_id            = aws_vpc.mainvpc.id
  cidr_block        = cidrsubnet("10.0.0.0/16", 8, count.index + 3)
  map_public_ip_on_launch = true
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name = "public-subnet-${count.index}"
  }
}


#Create an Internet Gateway resource
#Attach the internet Gateway to the VPC
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.mainvpc.id

  tags = {
    Name = "My_Internet_Gateway"
  }
}

#Create a public route table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.mainvpc.id
  tags = {
    Name = "MyPublicRoutetable"
  }
}


#Create a private route table
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.mainvpc.id
  tags = {
    Name = "MyPrivateRoutetable"
  }
}

resource "aws_route_table_association" "public_route_assoc" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

#Attach the private subnets created to the route table
resource "aws_route_table_association" "private_route_assoc" {
  count          = 3
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

#Create a public route in the public route table with the destination CIDR block 0.0.0.0/0 and the internet gateway created as the target
resource "aws_route" "public_igw_route" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gw.id
}

resource "aws_security_group" "example_sg" {
  name   = "example_web_app_sg"
  description = "Security group for web application load balancer"
  vpc_id = aws_vpc.mainvpc.id

  ingress {
    from_port      = 22
    to_port        = 22
    protocol       = "TCP"
    cidr_blocks    = ["0.0.0.0/0"]
  }

  ingress {
    from_port      = 80
    to_port        = 80
    protocol       = "TCP"
    cidr_blocks    = ["0.0.0.0/0"]
  }

  ingress {
    from_port      = 443
    to_port        = 443
    protocol       = "TCP"
    cidr_blocks    = ["0.0.0.0/0"]
  }

  # Ingress rule to any port on which the application runs
  ingress{
    from_port      = 0
    to_port        = 65535
    protocol       = "TCP"
    cidr_blocks    = ["0.0.0.0/0"]
  }

  egress {
    from_port      = 0
    to_port        = 0
    protocol       = "-1"
    cidr_blocks    = ["0.0.0.0/0"]
  }
}

#EC2 BUILDER
resource "aws_instance" "example_ec2" {
  # ami           = data.aws_ami.example_ami.id
  ami                     = "ami-07c67542bd966dfac"
  instance_type           = "t2.micro"
  associate_public_ip_address = true
  key_name                = "my-key"
  count = 3
  subnet_id               = aws_subnet.public[count.index].id
  vpc_security_group_ids = [
    aws_security_group.example_sg.id,
  ]
  # provisioner "file" {
  #   source      = "./init_app.sh"
  #   destination = "/tmp/init_app.sh"
  # }
  lifecycle {
    create_before_destroy = true
  }
}

#VOLUME 
resource "aws_ebs_volume" "example_volume" {
  count = 3
  availability_zone = aws_instance.example_ec2[count.index].availability_zone
  size              = 50
  type              = "gp2"
}

resource "aws_volume_attachment" "example"{
    device_name = "/dev/sdh"
    count = 3
    volume_id = aws_ebs_volume.example_volume[count.index].id
    instance_id = aws_instance.example_ec2[count.index].id
}

# Create 3 EIP
resource "aws_eip" "public_ips" {
  count = 3
  vpc = true
  tags = {
    Name = "public-ip-${count.index}"
  }
}

# Create 3 GW
resource "aws_nat_gateway" "nat_gateway" {
  count = 3
  allocation_id = aws_eip.public_ips[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "nat-gateway-${count.index}"
  }
}

resource "aws_eip_association" "public_ip_assoc" {
  count = 3
  allocation_id = aws_eip.public_ips[count.index].id
  
  # Remove existing association for this Elastic IP
  provisioner "local-exec" {
    command =<<-EOT
      sleep 5
      aws ec2 disassociate-address --public-ip ${aws_eip.public_ips[count.index].public_ip} --region ${var.region}
    EOT
  }

  instance_id   = aws_instance.example_ec2[count.index].id
}