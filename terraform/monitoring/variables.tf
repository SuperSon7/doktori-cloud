variable "project_name" {
  description = "Project name for resource naming and tagging"
  type        = string
  default     = "doktori"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

# ── 인스턴스 ──────────────────────────────────────────────────

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
  default     = "t4g.small" # 2 GB RAM — Prometheus + Loki + Grafana 동시 구동

  # 변경 가이드:
  # ARM:   t4g.small (2GB, $12/월) | t4g.medium (4GB, $24/월)
  # Intel: t3.small  (2GB, $15/월) | t3.medium  (4GB, $30/월)
}

variable "key_name" {
  description = "SSH key pair name (비상용, 주 접근은 SSM)"
  type        = string
  default     = "doktori-dev"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 30

  # 산정 근거:
  # Prometheus 30d  : ~1.3 GB (4K series × 15s interval × 1.5 bytes/sample)
  # Loki 30d        : ~1-2 GB (Spring Boot + nginx 로그, 7x 압축)
  # Grafana         : ~0.3 GB
  # Docker images   : ~2 GB
  # OS              : ~4 GB
  # 합계 ~9.6 GB × 2 (안전 마진) = ~20 GB
  # 30 GB 선택: 로그 스파이크, 디버그 로깅, 이미지 업데이트 시 여유
}

# ── 네트워크 보안 ─────────────────────────────────────────────

variable "allowed_admin_cidrs" {
  description = "관리자 IP 목록 (Grafana, Prometheus, SSH 접근)"
  type        = list(string)
  default     = [] # terraform.tfvars에서 설정
}

variable "target_server_cidrs" {
  description = "타겟 서버 IP 목록 (Loki push, Alloy remote_write 허용)"
  type        = list(string)
  default     = [] # prod/dev 서버 EIP → terraform.tfvars에서 설정
}