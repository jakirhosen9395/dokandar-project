# PRIVATE-ONLY networking. EKS requires two AZs -> two private subnets.
# Egress via 02-platform-setup's NAT (tag lookup). NOTHING lives in a public subnet.

locals {
  private_subnets = {
    a = { cidr = var.subnet_cidrs.private_a, az = "${var.region}a" }
    b = { cidr = var.subnet_cidrs.private_b, az = "${var.region}b" }
  }
}

resource "aws_subnet" "private" {
  for_each          = local.private_subnets
  vpc_id            = local.vpc_id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az
  tags = {
    Name                                          = "${local.name}-eks-private-${each.key}"
    Tier                                          = "private"
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_route_table" "private" {
  vpc_id = local.vpc_id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = data.aws_nat_gateway.platform.id
  }
  tags = { Name = "${local.name}-eks-private-rt" }
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
