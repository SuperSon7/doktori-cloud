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

variable "architecture" {
  description = "CPU architecture: arm64 (Graviton, t4g) or x86_64 (Intel, t3)"
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "architecture must be arm64 or x86_64"
  }
}

variable "instance_type" {
  description = "EC2 instance type (t4g for ARM, t3 for x86)"
  type        = string
  default     = "t4g.small"

  # 변경 가이드:
  # ARM:   t4g.small (2GB, $12/월) | t4g.medium (4GB, $24/월)
  # Intel: t3.small  (2GB, $15/월) | t3.medium  (4GB, $30/월)
}

variable "key_name" {
  description = "SSH key pair name (비상용, 주 접근은 SSM)"
  type        = string
  default     = "doktori-monitoring"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 30

  # 산정 근거:
  # Prometheus 30d  : ~1.3 GB
  # Loki 30d        : ~1-2 GB
  # Grafana         : ~0.3 GB
  # Docker images   : ~2 GB
  # OS              : ~4 GB
  # 합계 ~9.6 GB × 2 (안전 마진) = ~20 GB → 여유분 포함 30 GB
}

variable "allowed_admin_cidrs" {
  description = "Grafana(3000) 접근 허용 관리자 IP 목록"
  type        = list(string)
  # tfvars에서 오버라이드. 미설정 시 외부에서 Grafana 접근 불가.
  default     = []
}

variable "peered_vpc_cidrs" {
  description = "Prometheus/Loki 접근 허용 피어링 VPC CIDR 목록 (dev, prod 등)"
  type        = list(string)
  # 환경 VPC가 추가될 때마다 여기에 추가. K8s Pod CIDR(192.168.0.0/16) 필요 시 포함.
  default     = []
}
