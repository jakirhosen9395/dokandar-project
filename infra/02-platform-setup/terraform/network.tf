# Subnets + routing + security groups, all inside the VPC from 01-vpn-setup.

# --- Two subnets: public (runner) and private (utilities) ---
resource "aws_subnet" "public" {
  vpc_id                  = local.vpc_id
  cidr_block              = var.subnet_cidrs.public
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true
  tags = {
    Name = "${local.name}-public-runner"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  vpc_id            = local.vpc_id
  cidr_block        = var.subnet_cidrs.private
  availability_zone = var.availability_zone
  tags = {
    Name = "${local.name}-private-utilities"
    Tier = "private"
  }
}

# --- NAT gateway in the public subnet: outbound-only internet for utilities
#     (docker image pulls). ---
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "${local.name}-nat" }
}

# --- Route tables: public -> the VPN VPC's IGW; private -> NAT ---
resource "aws_route_table" "public" {
  vpc_id = local.vpc_id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = local.igw_id
  }
  tags = { Name = "${local.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = local.vpc_id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }
  tags = { Name = "${local.name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# --- Security groups ---
# Runner (public): SSH from the admin IP and from VPN clients; no other inbound
# (the runner only POLLS gitlab.com — it needs no listening ports).
resource "aws_security_group" "runner" {
  name                   = "${local.name}-runner-sg"
  description            = "GitLab runner - SSH from admin IP + VPN clients only"
  vpc_id                 = local.vpc_id
  revoke_rules_on_delete = true

  ingress {
    description = "SSH from the admin public IP (detected at apply time)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.admin_cidr]
  }
  ingress {
    description = "SSH from VPN clients"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.vpn_client_cidr]
  }
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${local.name}-runner-sg" }
}

# Utilities (private): everything from inside the VPC and from VPN clients
# (the 16 tools listen on many ports; the subnet is not internet-reachable).
resource "aws_security_group" "utilities" {
  name                   = "${local.name}-utilities-sg"
  description            = "Utilities host - open within the VPC and to VPN clients"
  vpc_id                 = local.vpc_id
  revoke_rules_on_delete = true

  ingress {
    description = "All from inside the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.vpc_cidr]
  }
  ingress {
    description = "All from VPN clients"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.vpn_client_cidr]
  }
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${local.name}-utilities-sg" }
}
