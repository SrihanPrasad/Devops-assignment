terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40, < 8.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4"
    }
  }

  # Remote state: S3 bucket + DynamoDB lock table (created by ./bootstrap).
  # Backend blocks cannot use variables, so the values come from a file at init time:
  #   terraform init -backend-config=backend.hcl -backend-config="key=web/dev/terraform.tfstate"
  backend "s3" {}
}
