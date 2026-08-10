
data "aws_availability_zones" "available" {
  state = "available"
}

variable "az_count" {
  type        = number
  description = "Number of Availability Zones to use"
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "The Trailmark network requires at least two Availability Zones."
  }
}

locals {
  selected_azs = slice(
    sort(data.aws_availability_zones.available.names),
    0,
    var.az_count
  )
  public_subnet_definitions = {
    for index, az in local.selected_azs :
    "public-${index + 1}" => {
      cidr_block = cidrsubnet(var.vpc_cidr, 8, index)
      az         = az
      tier       = "public"
    }
  }
  app_subnet_definitions = {
    for index, az in local.selected_azs :
    "app-${index + 1}" => {
      cidr_block = cidrsubnet(var.vpc_cidr, 8, 10 + index)
      az         = az
      tier       = "app"
    }
  }
  db_subnet_definitions = {
    for index, az in local.selected_azs :
    "db-${index + 1}" => {
      cidr_block = cidrsubnet(var.vpc_cidr, 8, 20 + index)
      az         = az
      tier       = "db"
    }
  }
  subnets = merge(
    local.public_subnet_definitions,
    local.app_subnet_definitions,
    local.db_subnet_definitions
  )
  public_subnets = { for k, v in local.subnets : k => v if v.tier == "public" }
  app_subnets    = { for k, v in local.subnets : k => v if v.tier == "app" }
  nat_gateway_by_az = {
    for key, subnet in local.public_subnets : subnet.az => aws_nat_gateway.this[key].id
  }
}

resource "aws_vpc" "vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.prefix}-vpc"
  }
}

resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id            = aws_vpc.vpc.id
  cidr_block        = each.value.cidr_block
  availability_zone = each.value.az
  tags = {
    Name = each.key
    Tier = each.value.tier
  }
}



resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name = "${var.prefix}-igw"
  }
}

resource "aws_route_table" "web-route-table" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.prefix}-web-route-table"
  }
}

resource "aws_route_table_association" "web-route-table-association" {
  for_each = local.public_subnets

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.web-route-table.id
}

resource "aws_eip" "nat" {
  for_each = local.public_subnets

  domain = "vpc"

  tags = {
    Name = "${var.prefix}-eip-${each.key}"
  }
}

resource "aws_nat_gateway" "this" {
  for_each = local.public_subnets

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.this[each.key].id

  depends_on = [aws_internet_gateway.igw]

  tags = {
    Name = "${var.prefix}-nat-${each.key}"
  }
}

resource "aws_route_table" "app-route-table" {
  for_each = local.app_subnets

  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = local.nat_gateway_by_az[each.value.az]
  }

  tags = {
    Name = "${var.prefix}-app-route-table"
  }
}

resource "aws_route_table_association" "app-route-table-association" {
  for_each = local.app_subnets

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.app-route-table[each.key].id
}