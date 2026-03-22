# =============================================================================
# 공통 변수 — 모든 AMI 빌드에서 사용
# =============================================================================

packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "project_name" {
  type    = string
  default = "doktori"
}

variable "vpc_filter_name" {
  description = "빌더 인스턴스를 띄울 VPC 이름 태그"
  type        = string
  default     = "doktori-prod-vpc"
}

variable "subnet_filter_name" {
  description = "빌더 인스턴스를 띄울 서브넷 이름 태그 (public 필요)"
  type        = string
  default     = "doktori-prod-public"
}

# -----------------------------------------------------------------------------
# 버전 핀닝
# -----------------------------------------------------------------------------
variable "k8s_version" {
  description = "Kubernetes minor version (apt repo)"
  type        = string
  default     = "v1.34"
}

variable "containerd_version" {
  description = "containerd.io 패키지 버전"
  type        = string
  default     = "1.7.25-1"
}

variable "docker_version" {
  description = "Docker CE 패키지 버전 (5: prefix 포함)"
  type        = string
  default     = "5:27.4.1-1~ubuntu.22.04~jammy"
}

# -----------------------------------------------------------------------------
# 공통 locals
# -----------------------------------------------------------------------------
locals {
  timestamp = formatdate("YYYYMMDD-hhmm", timestamp())
}