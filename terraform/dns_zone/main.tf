# -----------------------------------------------------------------------------
# 동적 레코드는 해당 리소스 레이어에서 관리 (PRINCIPLES.md §3)
#
# CloudFront alias (@, www)  → environments/prod/cdn/main.tf
# ALB alias (api.doktori.kr) → environments/prod/app/main.tf
# ACM validation records     → environments/prod/cdn/main.tf (CloudFront cert)
# dev/monitoring/origin A    → 각 환경 레이어에서 EIP 확정 후 추가
# -----------------------------------------------------------------------------
