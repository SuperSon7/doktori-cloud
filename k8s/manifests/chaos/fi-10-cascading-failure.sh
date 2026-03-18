#!/usr/bin/env bash
# =============================================================================
# FI-10: 연쇄 장애 (Cascading Failure)
#
# 시나리오: k6 stress + DB 500ms 지연 → 커넥션 풀 고갈 → HPA 스케일아웃 → 악화/안정화
#
# 사용법:
#   터미널 1: k6 run --env BASE_URL=http://<endpoint>/api k6/scenarios/stress.js
#   터미널 2: ./fi-10-cascading-failure.sh
#
# 성공 기준: 서비스 완전 다운 없이 degraded 유지 (5xx < 10%)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================="
echo " FI-10: 연쇄 장애 (Cascading Failure)"
echo "============================================="
echo ""
echo "  시나리오: DB 500ms 지연 → 커넥션 풀 고갈 → HPA 반응 관찰"
echo ""

read -p "k6 stress가 실행 중입니까? (y/n): " confirm
[[ "$confirm" != "y" ]] && echo "k6를 먼저 실행하세요." && exit 1

echo ""
echo "[1/5] 현재 상태 기록..."
echo "  HPA:"
kubectl get hpa -n prod
echo "  HikariCP (Grafana에서 확인):"
echo "  → jvm-api 대시보드 > HikariCP 패널 스크린샷 저장"
echo ""

echo "[2/5] DB 지연 500ms 주입..."
cat <<'YAML' | kubectl apply -f -
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: fi-10-db-latency-500ms
  namespace: chaos-testing
  labels:
    experiment: fi-10
spec:
  action: delay
  mode: all
  selector:
    namespaces:
      - prod
    labelSelectors:
      app: doktori
      component: api
  delay:
    latency: '500ms'
    jitter: '100ms'
    correlation: '50'
  direction: to
  target:
    mode: all
    selector:
      namespaces:
        - prod
      labelSelectors:
        app: doktori
        component: api
  duration: '10m'
YAML

echo "  → 500ms 지연 주입됨. 10분간 유지."
echo ""

echo "[3/5] 관찰 (2분 대기 — HPA 반응 시간)..."
echo "  실시간 관찰:"
echo "    터미널 A: kubectl get hpa -n prod -w"
echo "    터미널 B: kubectl get pods -n prod -w"
echo "    Grafana: HikariCP pending, API P95, 5xx rate"
echo ""

for i in $(seq 1 12); do
  echo "  [$(date '+%H:%M:%S')] --- ${i}0초 경과 ---"
  kubectl get hpa -n prod --no-headers 2>/dev/null | awk '{print "    " $0}'
  sleep 10
done

echo ""
echo "[4/5] 현재 상태 기록..."
echo "  HPA:"
kubectl get hpa -n prod
echo "  Pods:"
kubectl get pods -n prod -l component=api -o wide
echo ""

echo "[5/5] 장애 해제..."
kubectl delete networkchaos fi-10-db-latency-500ms -n chaos-testing --ignore-not-found

echo ""
echo "============================================="
echo " FI-10 완료"
echo "============================================="
echo ""
echo "확인 사항:"
echo "  1. HikariCP pending이 0 이상이었는지 (Grafana 스크린샷)"
echo "  2. HPA가 스케일아웃했는지 → 스케일아웃이 상황을 악화시켰는지"
echo "  3. 5xx rate 최대치가 몇 %였는지"
echo "  4. 해제 후 정상화까지 걸린 시간"