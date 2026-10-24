# Requirement 5: DNS name of the load balancer.
output "load_balancer_dns_name" {
  description = "Open http://<this> in a browser"
  value       = module.autoscaling.alb_dns_name
}

output "environment" {
  value = var.environment
}

output "instance_type" {
  description = "Chosen from the environment: dev -> t2.micro, prod -> t3.medium"
  value       = local.instance_type
}

output "ami_id" {
  description = "AMI found by the data source"
  value       = data.aws_ami.al2023.id
}

output "availability_zones" {
  value = module.vpc.availability_zones
}

output "web_instance_public_ips" {
  value = module.autoscaling.instance_public_ips
}

output "ssh_private_key_file" {
  description = "Use: ssh -i <this file> ec2-user@<instance ip>  (from the allowed ssh_cidr)"
  value       = local_sensitive_file.ssh_private_key.filename
}
