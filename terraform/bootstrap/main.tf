# =============================================================================
# BOOTSTRAP - creates the S3 bucket + DynamoDB table that hold remote state.
#
# This must be its own tiny Terraform project with LOCAL state: the remote
# backend can't exist before the bucket does (chicken-and-egg).
# Run it once:   terraform init && terraform apply
# Then:          terraform output -raw backend_hcl > ../backend.hcl
# =============================================================================
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40, < 8.0"
    }
  }
}

variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "state_bucket_name" {
  description = "Globally-unique bucket name. Leave null to derive one from the account id."
  type        = string
  default     = null
}

variable "lock_table_name" {
  type    = string
  default = "terraform-state-locks"
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

locals {
  bucket = coalesce(var.state_bucket_name, "tfstate-${data.aws_caller_identity.current.account_id}-${var.region}")
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket

  lifecycle {
    prevent_destroy = true # losing this bucket loses your infrastructure's memory
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled" # lets you roll back a corrupted state file
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Refuse any non-HTTPS access to the state bucket.
data "aws_iam_policy_document" "tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tls_only" {
  bucket     = aws_s3_bucket.state.id
  policy     = data.aws_iam_policy_document.tls_only.json
  depends_on = [aws_s3_bucket_public_access_block.state]
}

resource "aws_dynamodb_table" "locks" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID" # Terraform requires exactly this key name and type

  attribute {
    name = "LockID"
    type = "S"
  }
}

output "state_bucket" {
  value = aws_s3_bucket.state.id
}

output "lock_table" {
  value = aws_dynamodb_table.locks.name
}

# terraform output -raw backend_hcl > ../backend.hcl
output "backend_hcl" {
  value = <<-EOT
    bucket         = "${aws_s3_bucket.state.id}"
    region         = "${var.region}"
    dynamodb_table = "${aws_dynamodb_table.locks.name}"
    encrypt        = true
  EOT
}
