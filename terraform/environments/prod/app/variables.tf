variable "project_name" {
  type    = string
  default = "doktori"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}


variable "key_name" {
  type    = string
  default = ""
}

variable "domain_name" {
  type    = string
  default = "doktori.kr"
}

# -----------------------------------------------------------------------------
# AMI — Packer 빌드 후 SSM Parameter Store에서 읽는 방식으로 전환 예정
# 현재는 variables.tf에서 명시적으로 관리
# -----------------------------------------------------------------------------
variable "frontend_ami_id" {
  description = "AMI ID for the frontend ASG (Next.js). Packer 빌드 결과물."
  type        = string
  # packer:frontend_ami_id
  default = "ami-073134625384eb471"

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.frontend_ami_id))
    error_message = "frontend_ami_id must be a concrete Packer AMI ID."
  }
}

variable "k8s_ami_id" {
  description = "AMI ID for the K8s cluster (master + worker). K8s 1.34.6 + containerd 1.7.25."
  type        = string
  # packer:k8s_ami_id
  default = "ami-0fddfa15366edcfc0"

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.k8s_ami_id))
    error_message = "k8s_ami_id must be a concrete Packer AMI ID."
  }
}

variable "rds_monitoring_ami_id" {
  description = "AMI ID for RDS monitoring EC2 (mysqld_exporter). Packer 빌드 결과물."
  type        = string
  # packer:rds_monitoring_ami_id
  default = "ami-038d28145ee2ce551"

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.rds_monitoring_ami_id))
    error_message = "rds_monitoring_ami_id must be a concrete Packer AMI ID; do not fall back to a raw Ubuntu AMI."
  }
}

# -----------------------------------------------------------------------------
# K8s 컴포넌트 버전 — 업그레이드 시 이 변수만 수정
# -----------------------------------------------------------------------------
variable "calico_version" {
  description = "Calico CNI version"
  type        = string
  default     = "v3.31.4"
}

variable "gateway_api_version" {
  description = "Kubernetes Gateway API CRD version"
  type        = string
  default     = "v1.4.1"
}

variable "ngf_version" {
  description = "NGINX Gateway Fabric version"
  type        = string
  default     = "2.4.2"
}

variable "codedeploy_stack_version" {
  description = "CodeDeploy 스택 배선이 바뀔 때 올려서 안전한 apply를 강제하는 마커"
  type        = string
  default     = "2026-03-19"
}
