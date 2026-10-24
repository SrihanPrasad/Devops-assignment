# Auto Scaling module
#   launch template -> Auto Scaling Group (2 instances across 2 AZs)
#   Application Load Balancer + target group + listener
#   terraform_data + remote-exec provisioner that installs/verifies NGINX per instance

variable "name" {
  type = string
}

variable "environment" {
  type = string
}

variable "ami_id" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "key_name" {
  type = string
}

variable "private_key_pem" {
  description = "Private key the provisioner uses to SSH to the instances"
  type        = string
  sensitive   = true
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "One subnet per AZ - used for both the ALB and the instances"
  type        = list(string)
}

variable "alb_sg_id" {
  type = string
}

variable "web_sg_id" {
  type = string
}

variable "min_size" {
  type    = number
  default = 2
}

variable "desired_capacity" {
  type    = number
  default = 2
}

variable "max_size" {
  type    = number
  default = 4
}

variable "ssh_user" {
  type    = string
  default = "ec2-user" # Amazon Linux
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ------------------------------------------------------------------ launch template
resource "aws_launch_template" "web" {
  name_prefix   = "${var.name}-web-"
  image_id      = var.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    environment = var.environment
  }))

  # Public IP is needed so the Terraform provisioner can SSH in (restricted by the SG to ssh_cidr).
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [var.web_sg_id]
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.name}-web" })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------- load balancer
resource "aws_lb" "web" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.subnet_ids
  tags               = merge(var.tags, { Name = "${var.name}-alb" })
}

resource "aws_lb_target_group" "web" {
  name     = "${var.name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = var.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# ------------------------------------------------------------------------------ ASG
resource "aws_autoscaling_group" "web" {
  name                = "${var.name}-asg"
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.desired_capacity
  vpc_zone_identifier = var.subnet_ids # 2 subnets in 2 AZs -> instances spread across both

  target_group_arns         = [aws_lb_target_group.web.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 180

  # Block until the instances are InService so the provisioner below can find them.
  # (Deliberately NOT using wait_for_elb_capacity - see README, it is not needed.)
  wait_for_capacity_timeout = "10m"

  launch_template {
    id      = aws_launch_template.web.id
    version = aws_launch_template.web.latest_version
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.name}-web"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = var.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

# ----------------------------------------------------------- NGINX via provisioner
# Provisioners can only attach to resources Terraform itself creates. ASG instances are
# created by AWS, so we (1) look them up after the ASG is up and (2) run remote-exec via
# a terraform_data resource - one per desired instance.
data "aws_instances" "web" {
  instance_state_names = ["running"]

  filter {
    name   = "tag:aws:autoscaling:groupName"
    values = [aws_autoscaling_group.web.name]
  }

  depends_on = [aws_autoscaling_group.web]
}

locals {
  instance_ips = tolist(data.aws_instances.web.public_ips)
}

resource "terraform_data" "install_nginx" {
  count = var.desired_capacity # known at plan time; one provisioner run per instance

  # Re-run automatically when the instance behind this slot is replaced (its IP changes).
  triggers_replace = try(local.instance_ips[count.index], "pending")

  connection {
    type        = "ssh"
    host        = try(local.instance_ips[count.index], "")
    user        = var.ssh_user
    private_key = var.private_key_pem
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo cloud-init status --wait || true",                                 # wait for user_data to finish (dnf lock)
      "command -v nginx >/dev/null || sudo dnf install -y nginx",              # idempotent install
      "sudo systemctl enable --now nginx",
      "echo \"<h1>${var.environment}</h1><p>Served by $(hostname -f) (provisioner)</p>\" | sudo tee /usr/share/nginx/html/index.html >/dev/null",
      "curl -sf http://localhost/ >/dev/null && echo 'NGINX is up on' $(hostname -f)",
    ]
  }
}

output "alb_dns_name" {
  value = aws_lb.web.dns_name
}

output "asg_name" {
  value = aws_autoscaling_group.web.name
}

output "instance_public_ips" {
  value = local.instance_ips
}
