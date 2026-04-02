variable "project_name" {
  description = "Project name"
  type        = string
  default     = "doktori"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "vpc_cidr" {
  description = "mgmt VPC CIDR (172.16.0.0/12 대역 — 환경 VPC 10.x.x.x와 구분)"
  type        = string
  default     = "172.16.0.0/16"
}

variable "public_subnet_cidr" {
  description = "NAT 인스턴스(WireGuard VPN) 배치용 퍼블릭 서브넷"
  type        = string
  default     = "172.16.0.0/24"
}

variable "private_subnet_cidr" {
  description = "monitoring EC2 배치용 프라이빗 서브넷"
  type        = string
  default     = "172.16.1.0/24"
}

variable "availability_zone" {
  description = "단일 AZ (HA 불필요, 비용 절감)"
  type        = string
  default     = "ap-northeast-2a"
}

variable "nat_instance_type" {
  description = "NAT 인스턴스 타입 (ARM Graviton)"
  type        = string
  default     = "t4g.nano"
}

variable "nat_key_name" {
  description = "NAT 인스턴스 SSH key pair 이름 (비상용, 주 접근은 SSM)"
  type        = string
  default     = ""
}
