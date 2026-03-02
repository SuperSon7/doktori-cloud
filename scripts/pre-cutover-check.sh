#!/bin/bash
# =============================================================================
# DNS 컷오버 전 인프라 상태 점검 스크립트
# 로컬 머신에서 실행 (AWS CLI + SSM 필요)
# =============================================================================

set -uo pipefail

# --- 설정 ---
NGINX_PUBLIC_IP="3.34.245.126"
NGINX_INSTANCE="i-0a4beef9dba096fc0"
API_INSTANCE="i-01d309282ecfb432b"
AI_PRIVATE_IP="10.1.20.199"
API_PRIVATE_IP="10.1.21.111"
CHAT_PRIVATE_IP="10.1.30.247"
FRONT_PRIVATE_IP="10.1.30.216"
S3_BUCKET="doktori-v2-prod"
DOMAIN="doktori.kr"
AWS_PROFILE="${AWS_PROFILE:-default}"

PASS=0
FAIL=0
WARN=0
RESULTS=()

# --- 헬퍼 ---
check() {
  local label="$1" status="$2" detail="${3:-}"
  if [ "$status" = "PASS" ]; then
    RESULTS+=("$(printf '  \033[32m✓\033[0m %-45s %s' "$label" "$detail")")
    ((PASS++))
  elif [ "$status" = "WARN" ]; then
    RESULTS+=("$(printf '  \033[33m⚠\033[0m %-45s %s' "$label" "$detail")")
    ((WARN++))
  else
    RESULTS+=("$(printf '  \033[31m✗\033[0m %-45s %s' "$label" "$detail")")
    ((FAIL++))
  fi
}

section() {
  RESULTS+=("")
  RESULTS+=("$(printf '\033[1m[%s]\033[0m' "$1")")
}

# HTTP 상태 코드 체크
http_check() {
  local url="$1" expected="$2" label="$3"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || echo "000")
  if [ "$code" = "$expected" ]; then
    check "$label" "PASS" "HTTP $code"
  else
    check "$label" "FAIL" "HTTP $code (expected $expected)"
  fi
}

# =============================================================================
# 1. 외부 접근 (Nginx 퍼블릭 IP 경유)
# =============================================================================
section "외부 접근 — Nginx ($NGINX_PUBLIC_IP)"

# HTTP → HTTPS 리다이렉트 확인
http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "http://$NGINX_PUBLIC_IP/nginx-health" 2>/dev/null || echo "000")
if [ "$http_code" = "301" ] || [ "$http_code" = "302" ]; then
  check "HTTP → HTTPS 리다이렉트" "PASS" "HTTP $http_code"
elif [ "$http_code" = "200" ]; then
  check "HTTP → HTTPS 리다이렉트" "WARN" "리다이렉트 없이 200 (HTTP 허용 중)"
else
  check "HTTP → HTTPS 리다이렉트" "FAIL" "HTTP $http_code"
fi

# HTTPS 체크 (-k: 인증서 CN 불일치 무시, IP로 접근하므로)
https_check() {
  local path="$1" expected="$2" label="$3"
  local code
  code=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 \
    -H "Host: $DOMAIN" "https://$NGINX_PUBLIC_IP$path" 2>/dev/null || echo "000")
  if [ "$code" = "$expected" ]; then
    check "$label" "PASS" "HTTPS $code"
  else
    check "$label" "FAIL" "HTTPS $code (expected $expected)"
  fi
}

https_check "/nginx-health" "200" "Nginx health"
https_check "/api/health" "200" "API via Nginx"
https_check "/" "200" "Frontend via Nginx"

# AI — 200 or 404 둘 다 도달 확인
ai_code=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 \
  -H "Host: $DOMAIN" "https://$NGINX_PUBLIC_IP/ai/health" 2>/dev/null || echo "000")
if [ "$ai_code" = "200" ] || [ "$ai_code" = "404" ]; then
  check "AI via Nginx" "PASS" "HTTPS $ai_code"
else
  check "AI via Nginx" "FAIL" "HTTPS $ai_code"
fi

# Chat — 알려진 이슈 (main에 prod 설정 없음)
chat_code=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 \
  -H "Host: $DOMAIN" "https://$NGINX_PUBLIC_IP/api/chat/health" 2>/dev/null || echo "000")
if [ "$chat_code" = "200" ] || [ "$chat_code" = "401" ]; then
  check "Chat via Nginx" "PASS" "HTTPS $chat_code"
elif [ "$chat_code" = "502" ] || [ "$chat_code" = "000" ]; then
  check "Chat via Nginx" "WARN" "HTTPS $chat_code (main에 prod 설정 없어 예상된 실패)"
else
  check "Chat via Nginx" "WARN" "HTTPS $chat_code"
fi

# =============================================================================
# 2. SSL 인증서 (doktori.kr)
# =============================================================================
section "SSL 인증서"

# Nginx에서 인증서 존재 여부 확인
cert_check=$(aws ssm send-command \
  --instance-ids "$NGINX_INSTANCE" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=['sudo ls /etc/letsencrypt/live/$DOMAIN/fullchain.pem 2>/dev/null && echo EXISTS || echo MISSING']" \
  --output text --query "Command.CommandId" \
  --profile "$AWS_PROFILE" 2>/dev/null || echo "SSM_FAIL")

if [ "$cert_check" != "SSM_FAIL" ]; then
  sleep 3
  cert_result=$(aws ssm get-command-invocation \
    --command-id "$cert_check" \
    --instance-id "$NGINX_INSTANCE" \
    --query "StandardOutputContent" --output text \
    --profile "$AWS_PROFILE" 2>/dev/null | tr -d '[:space:]')

  if [ "$cert_result" = "EXISTS" ]; then
    # 만료일 확인
    expiry_cmd=$(aws ssm send-command \
      --instance-ids "$NGINX_INSTANCE" \
      --document-name "AWS-RunShellScript" \
      --parameters "commands=['sudo openssl x509 -enddate -noout -in /etc/letsencrypt/live/$DOMAIN/fullchain.pem 2>/dev/null || echo NOREAD']" \
      --output text --query "Command.CommandId" \
      --profile "$AWS_PROFILE" 2>/dev/null)
    sleep 3
    expiry=$(aws ssm get-command-invocation \
      --command-id "$expiry_cmd" \
      --instance-id "$NGINX_INSTANCE" \
      --query "StandardOutputContent" --output text \
      --profile "$AWS_PROFILE" 2>/dev/null | xargs)
    check "SSL cert ($DOMAIN)" "PASS" "$expiry"
  else
    check "SSL cert ($DOMAIN)" "FAIL" "인증서 없음"
  fi
else
  check "SSL cert ($DOMAIN)" "FAIL" "SSM 접근 실패"
fi

# HTTPS 응답 (Host 헤더로 테스트, DNS 전환 전이라 IP로 접근)
https_code=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 \
  -H "Host: $DOMAIN" "https://$NGINX_PUBLIC_IP/nginx-health" 2>/dev/null || echo "000")
if [ "$https_code" = "200" ]; then
  check "HTTPS 응답 (Host: $DOMAIN)" "PASS" "HTTP $https_code"
else
  check "HTTPS 응답 (Host: $DOMAIN)" "FAIL" "HTTP $https_code"
fi

# =============================================================================
# 3. 내부 직접 연결 (Nginx → Backend)
# =============================================================================
section "내부 연결 — Nginx에서 Backend 직접 확인"

internal_cmd=$(aws ssm send-command \
  --instance-ids "$NGINX_INSTANCE" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[
    'echo API=\$(curl -s -o /dev/null -w %{http_code} --connect-timeout 3 http://$API_PRIVATE_IP:8080/api/health)',
    'echo CHAT=\$(curl -s -o /dev/null -w %{http_code} --connect-timeout 3 http://$CHAT_PRIVATE_IP:8081/api/chat/health)',
    'echo FRONT=\$(curl -s -o /dev/null -w %{http_code} --connect-timeout 3 http://$FRONT_PRIVATE_IP:3000/)',
    'echo AI=\$(curl -s -o /dev/null -w %{http_code} --connect-timeout 3 http://$AI_PRIVATE_IP:8000/ai/health)'
  ]" \
  --output text --query "Command.CommandId" \
  --profile "$AWS_PROFILE" 2>/dev/null || echo "SSM_FAIL")

if [ "$internal_cmd" != "SSM_FAIL" ]; then
  sleep 5
  internal_result=$(aws ssm get-command-invocation \
    --command-id "$internal_cmd" \
    --instance-id "$NGINX_INSTANCE" \
    --query "StandardOutputContent" --output text \
    --profile "$AWS_PROFILE" 2>/dev/null)

  for svc in API CHAT FRONT AI; do
    code=$(echo "$internal_result" | grep "^$svc=" | cut -d= -f2 | tr -d '[:space:]')
    case "$svc" in
      API)   expected="200"; label="Nginx → API (:8080)" ;;
      CHAT)  expected="200"; label="Nginx → Chat (:8081)" ;;
      FRONT) expected="200"; label="Nginx → Frontend (:3000)" ;;
      AI)    expected="200"; label="Nginx → AI (:8000)" ;;
    esac
    if [ "$code" = "$expected" ] || [ "$code" = "401" ]; then
      check "$label" "PASS" "HTTP $code"
    elif [ "$svc" = "CHAT" ] && { [ "$code" = "502" ] || [ -z "$code" ]; }; then
      check "$label" "WARN" "HTTP ${code:-timeout} (예상된 실패)"
    else
      check "$label" "FAIL" "HTTP ${code:-timeout}"
    fi
  done
else
  check "내부 연결 확인" "FAIL" "SSM 접근 실패"
fi

# =============================================================================
# 4. S3 접근 (API 인스턴스에서)
# =============================================================================
section "S3 접근 — API 인스턴스"

s3_cmd=$(aws ssm send-command \
  --instance-ids "$API_INSTANCE" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=['aws s3 ls s3://$S3_BUCKET/ --summarize 2>&1 | tail -2']" \
  --output text --query "Command.CommandId" \
  --profile "$AWS_PROFILE" 2>/dev/null || echo "SSM_FAIL")

if [ "$s3_cmd" != "SSM_FAIL" ]; then
  sleep 4
  s3_result=$(aws ssm get-command-invocation \
    --command-id "$s3_cmd" \
    --instance-id "$API_INSTANCE" \
    --query "StandardOutputContent" --output text \
    --profile "$AWS_PROFILE" 2>/dev/null)

  if echo "$s3_result" | grep -q "Total Objects"; then
    obj_count=$(echo "$s3_result" | grep "Total Objects" | awk '{print $3}')
    check "S3 버킷 ($S3_BUCKET)" "PASS" "$obj_count objects"
  elif echo "$s3_result" | grep -qi "AccessDenied\|denied"; then
    check "S3 버킷 ($S3_BUCKET)" "FAIL" "AccessDenied — IAM 정책 확인"
  else
    check "S3 버킷 ($S3_BUCKET)" "FAIL" "$(echo "$s3_result" | head -1)"
  fi
else
  check "S3 버킷 ($S3_BUCKET)" "FAIL" "SSM 접근 실패"
fi

# =============================================================================
# 5. DNS 현재 상태
# =============================================================================
section "DNS 상태"

current_ip=$(dig +short "$DOMAIN" A 2>/dev/null | head -1)
if [ "$current_ip" = "$NGINX_PUBLIC_IP" ]; then
  check "DNS A 레코드 ($DOMAIN)" "PASS" "$current_ip (이미 새 IP)"
else
  check "DNS A 레코드 ($DOMAIN)" "WARN" "$current_ip → 컷오버 시 $NGINX_PUBLIC_IP 로 변경"
fi

ttl=$(dig +noall +answer "$DOMAIN" A 2>/dev/null | awk '{print $2}' | head -1)
if [ -n "$ttl" ] && [ "$ttl" -le 300 ] 2>/dev/null; then
  check "DNS TTL" "PASS" "${ttl}s"
else
  check "DNS TTL" "WARN" "${ttl:-unknown}s (300s 이하 권장)"
fi

# =============================================================================
# 결과 출력
# =============================================================================
echo ""
echo "============================================="
echo "  DNS 컷오버 전 인프라 점검 결과"
echo "============================================="
for line in "${RESULTS[@]}"; do
  echo -e "$line"
done

echo ""
echo "---------------------------------------------"
printf "  \033[32mPASS: %d\033[0m  \033[33mWARN: %d\033[0m  \033[31mFAIL: %d\033[0m\n" "$PASS" "$WARN" "$FAIL"
echo "---------------------------------------------"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "  ⛔ FAIL 항목을 해결한 후 DNS 컷오버를 진행하세요."
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo ""
  echo "  ⚠  WARN 항목을 확인하고, 허용 가능하면 컷오버 진행."
  exit 0
else
  echo ""
  echo "  ✅ 모든 항목 PASS — DNS 컷오버 준비 완료!"
  exit 0
fi