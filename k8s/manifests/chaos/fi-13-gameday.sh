#!/usr/bin/env bash
# =============================================================================
# FI-13: Game Day — 전체 사용자 여정 카오스
#
# 30분간 k6 부하 + 5분 간격 랜덤 FI 연쇄 주입
#
# 사용법:
#   터미널 1: k6 run --duration 35m --env BASE_URL=http://<endpoint>/api k6/scenarios/load.js
#   터미널 2: ./fi-13-gameday.sh
#
# 성공 기준: 전체 30분 SLO-1 > 99.0%, SLO-3 유지, k6 에러율 < 5%
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NS="chaos-testing"

echo "============================================="
echo " FI-13: Game Day 🎮"
echo " 30분간 5분 간격 랜덤 장애 주입"
echo "============================================="
echo ""

read -p "k6 load (35분)가 실행 중입니까? (y/n): " confirm
[[ "$confirm" != "y" ]] && echo "k6를 먼저 실행하세요. (--duration 35m)" && exit 1

echo ""
echo "  Grafana 대시보드를 모두 열어두세요!"
echo "  시작 시각: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# --- Round 1: 5분 — API Pod Kill ---
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[Round 1/5] $(date '+%H:%M:%S') API Pod 1개 Kill"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
kubectl apply -f "${SCRIPT_DIR}/fi-1-api-pod-kill.yaml"
echo "  → 30초 후 자동 해제 (duration: 30s)"
sleep 300

# --- Round 2: 10분 — DB 지연 200ms ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[Round 2/5] $(date '+%H:%M:%S') DB 200ms 지연 주입"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cat <<'YAML' | kubectl apply -f -
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: fi-13-db-latency
  namespace: chaos-testing
  labels:
    experiment: fi-13
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
    latency: '200ms'
    jitter: '50ms'
  direction: to
  target:
    mode: all
    selector:
      namespaces:
        - prod
      labelSelectors:
        app: doktori
        component: api
  duration: '4m'
YAML
echo "  → 4분간 유지 후 자동 해제"
sleep 300

# --- Round 3: 15분 — Chat Pod Kill ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[Round 3/5] $(date '+%H:%M:%S') Chat Pod 1개 Kill"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
kubectl apply -f "${SCRIPT_DIR}/fi-2-chat-pod-kill.yaml"
echo "  → 30초 후 자동 해제"
sleep 300

# --- Round 4: 20분 — CPU Stress ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[Round 4/5] $(date '+%H:%M:%S') API CPU 80% Stress"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cat <<'YAML' | kubectl apply -f -
apiVersion: chaos-mesh.org/v1alpha1
kind: StressChaos
metadata:
  name: fi-13-cpu-stress
  namespace: chaos-testing
  labels:
    experiment: fi-13
spec:
  mode: all
  selector:
    namespaces:
      - prod
    labelSelectors:
      app: doktori
      component: api
  stressors:
    cpu:
      workers: 2
      load: 80
  duration: '4m'
YAML
echo "  → 4분간 유지 후 자동 해제"
sleep 300

# --- Round 5: 25분 — 모든 장애 해제, 안정화 관찰 ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[Round 5/5] $(date '+%H:%M:%S') 모든 장애 해제 — 안정화 관찰"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
kubectl delete podchaos,networkchaos,stresschaos --all -n "$NS" --ignore-not-found 2>/dev/null
echo "  → 5분간 안정화 관찰..."
sleep 300

echo ""
echo "============================================="
echo " Game Day 완료!"
echo " 종료 시각: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================="
echo ""
echo "확인 사항:"
echo "  1. k6 최종 결과 → 전체 에러율 < 5%?"
echo "  2. Grafana → 30분간 SLO-1 > 99.0%?"
echo "  3. Grafana → SLO-3 (Chat probe) 유지?"
echo "  4. 각 Round 구간별 Grafana 스크린샷 저장"
echo "  5. 안정화 Round에서 모든 지표 baseline 복귀 확인"