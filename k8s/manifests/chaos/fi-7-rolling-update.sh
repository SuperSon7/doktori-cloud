#!/usr/bin/env bash
# =============================================================================
# FI-7: Rolling Update 무중단 배포 검증
#
# 사용법:
#   1. 별도 터미널에서 k6 부하 실행:
#      k6 run --env BASE_URL=http://<endpoint>/api load-tests/k6/scenarios/load.js
#
#   2. 이 스크립트 실행:
#      ./fi-7-rolling-update.sh <new-image-tag>
#
#   3. k6 결과에서 errors rate = 0 확인
#
# 가설: maxUnavailable=0, maxSurge=1 설정으로 배포 중 5xx = 0건
# 성공 기준: k6 errors rate = 0%, 배포 완료
# =============================================================================
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "사용법: $0 <new-image-tag>"
  echo "  예: $0 v1.2.3"
  echo ""
  echo "⚠️  반드시 k6 부하를 먼저 실행한 상태에서 이 스크립트를 실행하세요!"
  exit 1
fi

NEW_TAG="$1"
NAMESPACE="prod"
ECR_REGISTRY="250857930609.dkr.ecr.ap-northeast-2.amazonaws.com"
API_IMAGE="${ECR_REGISTRY}/doktori/api:${NEW_TAG}"

echo "============================================="
echo " FI-7: Rolling Update 무중단 배포 검증"
echo "============================================="
echo ""
echo "  이미지: ${API_IMAGE}"
echo "  k6가 실행 중인지 확인하세요!"
echo ""

read -p "k6 부하가 실행 중입니까? (y/n): " confirm
if [[ "$confirm" != "y" ]]; then
  echo "k6를 먼저 실행한 후 다시 시도하세요."
  exit 1
fi

echo ""
echo "[1/3] 배포 전 상태..."
kubectl get pods -n "$NAMESPACE" -l component=api -o wide
echo ""

echo "[2/3] Rolling Update 시작..."
kubectl set image deployment/api "doktori-api=${API_IMAGE}" -n "$NAMESPACE"

echo ""
echo "[3/3] Rollout 상태 추적..."
kubectl rollout status deployment/api -n "$NAMESPACE" --timeout=300s

echo ""
echo "============================================="
echo " 배포 완료"
echo "============================================="
echo ""
kubectl get pods -n "$NAMESPACE" -l component=api -o wide
echo ""
echo "✅ k6 결과에서 errors rate를 확인하세요."
echo "   - errors = 0% → 무중단 배포 검증 성공"
echo "   - errors > 0% → pre-stop hook 또는 readiness probe 설정 점검 필요"