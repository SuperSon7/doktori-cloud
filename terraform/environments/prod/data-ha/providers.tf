terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "doktori-v2-terraform-state"
    key            = "prod/data-ha/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "doktori-v2-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Layer       = "data-ha"
    }
  }
}