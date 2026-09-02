resource "aws_vpc" "experiment" {
  cidr_block           = "10.73.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "experiment" {
  vpc_id = aws_vpc.experiment.id
  tags   = { Name = "${local.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.experiment.id
  availability_zone       = local.availability_zones[count.index]
  cidr_block              = cidrsubnet(aws_vpc.experiment.cidr_block, 8, count.index)
  map_public_ip_on_launch = false

  tags = {
    Name                     = "${local.name_prefix}-public-${count.index + 1}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  count = 2

  vpc_id                  = aws_vpc.experiment.id
  availability_zone       = local.availability_zones[count.index]
  cidr_block              = cidrsubnet(aws_vpc.experiment.cidr_block, 8, count.index + 10)
  map_public_ip_on_launch = false

  tags = {
    Name                              = "${local.name_prefix}-private-${count.index + 1}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.name_prefix}-nat-eip" }

  depends_on = [aws_internet_gateway.experiment]
}

resource "aws_nat_gateway" "experiment" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${local.name_prefix}-nat" }

  depends_on = [aws_internet_gateway.experiment]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.experiment.id
  tags   = { Name = "${local.name_prefix}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.experiment.id
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.experiment.id
  tags   = { Name = "${local.name_prefix}-private" }
}

resource "aws_route" "private_internet" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.experiment.id
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "rabbitmq" {
  name        = "${local.name_prefix}-rabbitmq"
  description = "AMQPS from the disposable EKS cluster only"
  vpc_id      = aws_vpc.experiment.id

  ingress {
    description     = "AMQPS from EKS workloads"
    protocol        = "tcp"
    from_port       = 5671
    to_port         = 5671
    security_groups = [aws_eks_cluster.experiment.vpc_config[0].cluster_security_group_id]
  }

  egress {
    description = "Broker-managed egress within the experiment VPC"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = [aws_vpc.experiment.cidr_block]
  }

  tags = { Name = "${local.name_prefix}-rabbitmq" }
}
