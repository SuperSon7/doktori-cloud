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

variable "cni_plugins_version" {
  description = "containernetworking/plugins release version"
  type        = string
  default     = "1.7.1"
}

variable "ecr_credential_provider_version" {
  description = "cloud-provider-aws ecr-credential-provider release version"
  type        = string
  default     = "v1.31.0"
}

variable "crictl_version" {
  description = "cri-tools crictl release version"
  type        = string
  default     = "v1.34.0"
}

variable "nerdctl_version" {
  description = "containerd nerdctl release version (v prefix 없음)"
  type        = string
  default     = "1.7.7"
}

variable "docker_version" {
  description = "Docker CE 패키지 버전 (5: prefix 포함)"
  type        = string
  default     = "5:27.4.1-1~ubuntu.22.04~jammy"
}

variable "k6_version" {
  description = "k6 release version (v prefix 포함)"
  type        = string
  default     = "v0.54.0"
}

variable "redis_version" {
  description = "Redis server 메이저.마이너 버전 (packages.redis.io)"
  type        = string
  default     = "7.2"
}

variable "rabbitmq_version" {
  description = "RabbitMQ server 메이저.마이너 버전"
  type        = string
  default     = "3.13"
}

variable "erlang_version" {
  description = "Erlang/OTP 메이저 버전 (RabbitMQ 의존성)"
  type        = string
  default     = "26"
}

variable "mongodb_version" {
  description = "MongoDB 메이저.마이너 버전 (apt repo 슬롯)"
  type        = string
  default     = "7.0"
}

variable "mysqld_exporter_version" {
  description = "Prometheus mysqld_exporter 버전 (v prefix 없음)"
  type        = string
  default     = "0.15.1"
}

variable "alloy_version" {
  description = "Grafana Alloy 버전 (apt package prefix)"
  type        = string
  default     = "1.15.0"
}

# -----------------------------------------------------------------------------
# 공통 locals
# -----------------------------------------------------------------------------
locals {
  timestamp = formatdate("YYYYMMDD-hhmm", timestamp())
}
