resource "aws_vpc" "main" {
  cidr_block           = var.config.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = local.name, (local.cluster_tag) = "owned"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = local.name
  }
}

resource "aws_subnet" "public" {
  for_each                = local.azs
  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.config.vpc_cidr, 8, each.value)
  map_public_ip_on_launch = false
  tags = {
    Name = "${local.name}-public-${each.key}", "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  for_each                = local.azs
  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.config.vpc_cidr, 8, 16 + each.value)
  map_public_ip_on_launch = false
  tags = {
    Name = "${local.name}-private-${each.key}", "kubernetes.io/role/internal-elb" = "1", (local.cluster_tag) = "owned"
  }
}

# RDS 전용 데이터 서브넷입니다. 인터넷 기본 경로를 만들지 않습니다.
resource "aws_subnet" "data" {
  for_each                = local.azs
  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.config.vpc_cidr, 8, 32 + each.value)
  map_public_ip_on_launch = false
  tags = {
    Name = "${local.name}-data-${each.key}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "${local.name}-public"
  }
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  for_each       = local.azs
  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  for_each = var.config.single_nat_gateway ? {
    (var.config.azs[0]) = 0
  } : local.azs
  domain = "vpc"
  tags = {
    Name = "${local.name}-nat-${each.key}"
  }
}

resource "aws_nat_gateway" "main" {
  for_each      = aws_eip.nat
  allocation_id = each.value.id
  subnet_id     = aws_subnet.public[each.key].id
  tags = {
    Name = "${local.name}-${each.key}"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "private" {
  for_each = local.azs
  vpc_id   = aws_vpc.main.id
  tags = {
    Name = "${local.name}-private-${each.key}"
  }
}

resource "aws_route" "nat" {
  for_each               = local.azs
  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[var.config.single_nat_gateway ? var.config.azs[0] : each.key].id
}

resource "aws_route_table_association" "private" {
  for_each       = local.azs
  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

resource "aws_route_table" "data" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "${local.name}-isolated-data"
  }
}

resource "aws_route_table_association" "data" {
  for_each       = local.azs
  subnet_id      = aws_subnet.data[each.key].id
  route_table_id = aws_route_table.data.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for rt in aws_route_table.private : rt.id]
  tags = {
    Name = "${local.name}-s3"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = var.config.interface_endpoints
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [for az in var.config.azs : aws_subnet.private[az].id]
  security_group_ids  = [aws_security_group.role["endpoints"].id]
  tags = {
    Name = "${local.name}-${each.key}"
  }
}

