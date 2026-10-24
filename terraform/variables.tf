variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Name prefix for resources"
  type        = string
  default     = "webapp"
}

variable "environment" {
  description = "Deployment environment. Drives the instance type: dev -> t2.micro, prod -> t3.medium."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be \"dev\" or \"prod\"."
  }
}

variable "ssh_cidr" {
  description = "The only CIDR allowed to SSH into the web servers (also the CIDR Terraform runs from, for the provisioner)."
  type        = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "desired_capacity" {
  description = "Number of web servers (also the number of provisioner runs)"
  type        = number
  default     = 2
}
