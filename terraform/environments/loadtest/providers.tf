terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # 새 계정의 S3 backend — apply 전에 버킷 먼저 생성 필요
  # backend "s3" {
  #   bucket = "doktori-loadtest-tfstate"
  #   key    = "loadtest/terraform.tfstate"
  #   region = "ap-northeast-2"
  # }

  # 초기에는 local state 사용
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = "doktori-loadtest"
      Environment = "loadtest"
      ManagedBy   = "Terraform"
    }
  }
}