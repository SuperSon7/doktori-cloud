#!/usr/bin/env bash
# ============================================================================
# plan-all.sh — 모든 Terraform 레이어에 init + plan 실행, 결과 요약 출력
#
# Usage:
#   ./scripts/plan-all.sh              # 전체 레이어
#   ./scripts/plan-all.sh prod         # prod 레이어만
#   ./scripts/plan-all.sh staging dev  # staging + dev
# ============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"
BACKEND_HCL="${TF_DIR}/backend.hcl"

# 전체 레이어 (의존성 순서)
ALL_LAYERS=(
  "global"
  "prod/base"
  "prod/app"
  "prod/data"
  "staging/base"
  "staging/app"
  "staging/data"
  "dev/base"
  "dev/app"
)

# ── 필터링 ──────────────────────────────────────────────────────────────────
if [ $# -gt 0 ]; then
  FILTERED=()
  for filter in "$@"; do
    for layer in "${ALL_LAYERS[@]}"; do
      if [[ "$layer" == "$filter" || "$layer" == "$filter/"* ]]; then
        FILTERED+=("$layer")
      fi
    done
  done
  LAYERS=("${FILTERED[@]}")
else
  LAYERS=("${ALL_LAYERS[@]}")
fi

if [ ${#LAYERS[@]} -eq 0 ]; then
  echo "No matching layers found."
  exit 1
fi

echo "=========================================="
echo " Terraform Plan — ${#LAYERS[@]} layers"
echo "=========================================="
echo ""

# ── 결과 저장 ────────────────────────────────────────────────────────────────
declare -a RESULTS=()
declare -a DURATIONS=()
BASE_CHANGED_LIST=""   # 환경별 base 변경 추적 (space-separated: "prod staging")
PASS=0
FAIL=0
NOCHANGE=0
CHANGES=0
SKIP=0
LOG_DIR=$(mktemp -d)

for layer in "${LAYERS[@]}"; do
  if [ "$layer" = "global" ]; then
    WORK_DIR="${TF_DIR}/global"
  else
    WORK_DIR="${TF_DIR}/environments/${layer}"
  fi

  if [ ! -d "$WORK_DIR" ]; then
    echo "⚠  SKIP  ${layer} — directory not found"
    RESULTS+=("SKIP|${layer}|directory not found")
    SKIP=$((SKIP + 1))
    continue
  fi

  # base 변경이 있으면 하위 레이어(app/data) skip
  ENV_NAME="${layer%%/*}"
  LAYER_TYPE="${layer#*/}"
  if [[ "$layer" != "global" && "$LAYER_TYPE" != "base" ]]; then
    if [[ " $BASE_CHANGED_LIST " == *" $ENV_NAME "* ]]; then
      echo "── ${layer} ──────────────────────────────────"
      echo "  ⚠ SKIP — ${ENV_NAME}/base has pending changes (apply base first)"
      echo ""
      RESULTS+=("SKIP|${layer}|base changes pending — apply base first")
      SKIP=$((SKIP + 1))
      continue
    fi
  fi

  echo "── ${layer} ──────────────────────────────────"
  LOG_FILE="${LOG_DIR}/${layer//\//-}.log"
  START=$(date +%s)

  # init
  echo -n "  init... "
  if ! terraform -chdir="$WORK_DIR" init -backend-config="$BACKEND_HCL" -input=false -no-color > "$LOG_FILE" 2>&1; then
    echo "FAILED"
    DURATION=$(( $(date +%s) - START ))
    DURATIONS+=("$DURATION")
    RESULTS+=("FAIL|${layer}|init failed")
    FAIL=$((FAIL + 1))
    echo "  → log: $LOG_FILE"
    continue
  fi
  echo "ok"

  # plan
  echo -n "  plan... "
  set +e
  terraform -chdir="$WORK_DIR" plan -detailed-exitcode -input=false -no-color >> "$LOG_FILE" 2>&1
  EXIT_CODE=$?
  set -e

  DURATION=$(( $(date +%s) - START ))
  DURATIONS+=("$DURATION")

  case $EXIT_CODE in
    0)
      echo "NO CHANGES (${DURATION}s)"
      RESULTS+=("OK|${layer}|no changes")
      PASS=$((PASS + 1))
      NOCHANGE=$((NOCHANGE + 1))
      ;;
    1)
      echo "FAILED (${DURATION}s)"
      RESULTS+=("FAIL|${layer}|plan error")
      FAIL=$((FAIL + 1))
      echo "  → log: $LOG_FILE"
      ;;
    2)
      # 변경 있음 — add/change/destroy 카운트 추출
      SUMMARY=$(grep -E "Plan:" "$LOG_FILE" | tail -1 || echo "changes detected")
      echo "CHANGES (${DURATION}s)"
      echo "  → $SUMMARY"
      RESULTS+=("CHANGE|${layer}|${SUMMARY}")
      PASS=$((PASS + 1))
      CHANGES=$((CHANGES + 1))

      # base 변경 기록 — 하위 레이어 skip 판단용
      if [[ "$layer" != "global" && "$LAYER_TYPE" == "base" ]]; then
        BASE_CHANGED_LIST="$BASE_CHANGED_LIST $ENV_NAME"
      fi
      ;;
    *)
      echo "UNKNOWN EXIT $EXIT_CODE (${DURATION}s)"
      RESULTS+=("FAIL|${layer}|exit code $EXIT_CODE")
      FAIL=$((FAIL + 1))
      echo "  → log: $LOG_FILE"
      ;;
  esac
  echo ""
done

# ── 요약 ─────────────────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo " Summary"
echo "=========================================="
printf "%-20s %-10s %s\n" "LAYER" "STATUS" "DETAIL"
printf "%-20s %-10s %s\n" "----" "------" "------"

for result in "${RESULTS[@]}"; do
  IFS='|' read -r status layer detail <<< "$result"
  case $status in
    OK)     mark="✓" ;;
    CHANGE) mark="△" ;;
    FAIL)   mark="✗" ;;
    SKIP)   mark="⚠" ;;
    *)      mark="?" ;;
  esac
  printf "%-20s %-10s %s\n" "$layer" "$mark $status" "$detail"
done

echo ""
echo "Total: ${#LAYERS[@]} layers | ✓ No change: $NOCHANGE | △ Changes: $CHANGES | ⚠ Skip: $SKIP | ✗ Failed: $FAIL"
echo "Logs: $LOG_DIR"

if [ $FAIL -gt 0 ]; then
  echo ""
  echo "Failed layers — check logs:"
  for result in "${RESULTS[@]}"; do
    IFS='|' read -r status layer detail <<< "$result"
    if [ "$status" = "FAIL" ]; then
      echo "  cat ${LOG_DIR}/${layer//\//-}.log"
    fi
  done
  exit 1
fi
