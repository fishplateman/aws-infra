resource "aws_vpc" "yanglei"{
    cidr_block = var.cidr
    enable_dns_hostnames = true
}