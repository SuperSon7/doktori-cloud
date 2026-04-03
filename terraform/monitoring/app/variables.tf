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
  default     = "t4g.medium"

  # 변경 가이드:
  # ARM:   t4g.small (2GB, $12/월) | t4g.medium (4GB, $24/월)
  # Intel: t3.small  (2GB, $15/월) | t3.medium  (4GB, $30/월)
  # Prometheus ~1.5GB + Loki ~400MB + Grafana ~200MB → K8s 연결 시 4GB 권장
}

variable "key_name" {
  description = "SSH key pair name (비상용, 주 접근은 SSM)"
  type        = string
  default     = "doktori-monitoring"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 60

  # 산정 근거 (K8s 환경 기준):
  # Prometheus 14d (K8s 메트릭 포함) : ~8-15 GB
  # Loki index cache (chunks는 S3)   : ~2-3 GB
  # Docker images                    : ~3 GB
  # OS + 기타                        : ~4 GB
  # 합계 ~22 GB → 여유분 포함 60 GB
  # Loki S3 완전 전환 후 재평가 가능
}

variable "allowed_admin_cidrs" {
  description = "Grafana(3000) 접근 허용 CIDR (WireGuard VPN 클라이언트 서브넷)"
  type        = list(string)
  # EC2가 private 서브넷이므로 인터넷 직접 노출 없음
  # VPN 연결 후 mgmt private CIDR(172.16.1.0/24) 경유로 접근
  # 미설정 시 mgmt VPC 내부(172.16.0.0/16)에서만 접근 가능
  default     = ["172.16.0.0/16"]
}

variable "peered_vpc_cidrs" {
  description = "Prometheus/Loki 접근 허용 피어링 VPC CIDR 목록 (dev, prod 등)"
  type        = list(string)
  # 환경 VPC가 추가될 때마다 여기에 추가. K8s Pod CIDR(192.168.0.0/16) 필요 시 포함.
  default     = []
}
