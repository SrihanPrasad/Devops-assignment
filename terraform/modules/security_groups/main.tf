# Security-group module
#   alb_sg : HTTP (80) from the internet
#   web_sg : HTTP (80) ONLY from the load balancer, SSH (22) ONLY from ssh_cidr

variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "ssh_cidr" {
  description = "The only CIDR allowed to SSH to the web servers, e.g. 203.0.113.10/32"
  type        = string

  validation {
    condition     = can(cidrnetmask(var.ssh_cidr)) && var.ssh_cidr != "0.0.0.0/0"
    error_message = "ssh_cidr must be a valid IPv4 CIDR and must not be 0.0.0.0/0."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ---------------------------------------------------------------- load balancer
resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  description = "Public HTTP access to the load balancer"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-alb-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow all outbound (to reach targets)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ------------------------------------------------------------------ web servers
resource "aws_security_group" "web" {
  name_prefix = "${var.name}-web-"
  description = "Web servers: HTTP from ALB, SSH from one CIDR"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-web-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "web_http_from_alb" {
  security_group_id            = aws_security_group.web.id
  description                  = "HTTP from the load balancer only"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_ingress_rule" "web_ssh" {
  security_group_id = aws_security_group.web.id
  description       = "SSH from the allowed CIDR only"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.ssh_cidr
}

resource "aws_vpc_security_group_egress_rule" "web_all" {
  security_group_id = aws_security_group.web.id
  description       = "Allow all outbound (package installs)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

output "alb_sg_id" {
  value = aws_security_group.alb.id
}

output "web_sg_id" {
  value = aws_security_group.web.id
}
