provider "aws"{
    region = "us-east-1"
}
resource "aws_vpc" "mainvpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "MyVPC"
  }
}

#Create Public Subnet1
resource "aws_subnet" "public1" {
  vpc_id = aws_vpc.mainvpc.id
  cidr_block = "10.0.1.0/24"
  # other parameters
}

#Create Public Subnet2
resource "aws_subnet" "public2" {
  vpc_id = aws_vpc.mainvpc.id
  cidr_block = "10.0.2.0/24"
  # other parameters
}

#Create Public Subnet3
resource "aws_subnet" "public3" {
  vpc_id = aws_vpc.mainvpc.id
  cidr_block = "10.0.3.0/24"
  # other parameters
}

#Create Private Subnet1
resource "aws_subnet" "private1" {
  vpc_id = aws_vpc.mainvpc.id
  cidr_block = "10.0.4.0/24"
  # other parameters
}

#Create Private Subnet2
resource "aws_subnet" "private2" {
  vpc_id = aws_vpc.mainvpc.id
  cidr_block = "10.0.5.0/24"
  # other parameters
}

#Create Private Subnet3
resource "aws_subnet" "private3" {
  vpc_id = aws_vpc.mainvpc.id
  cidr_block = "10.0.6.0/24"
  # other parameters
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

#Attach the public subnets created to the route table
resource "aws_route_table_association" "public_route_assoc" {
  subnet_id      = aws_subnet.public1.id
  route_table_id = aws_route_table.public.id
}


#Attach the private subnets created to the route table
resource "aws_route_table_association" "private_route_assoc" {
  subnet_id      = aws_subnet.private1.id
  route_table_id = aws_route_table.private.id
}

#Create a public route in the public route table with the destination CIDR block 0.0.0.0/0 and the internet gateway created as the target
resource "aws_route" "public_igw_route" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gw.id
}  
