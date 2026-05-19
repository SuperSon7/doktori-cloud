#!/usr/bin/env bash
# =============================================================================
# Calico VXLAN WebSocket 실험 전 로컬 Preflight
#
# 목적:
#   서버/클러스터를 올리기 전에 레포와 로컬 도구 상태를 먼저 검증한다.
#   실험 당일에는 부트스트랩 -> 배포 -> 측정만 수행할 수 있게 준비하는 용도다.
#
# 사용:
#   ./scripts/network-roadmap-preflight.sh
# =============================================================================

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
WARN=0
FAIL=0
RESULTS=()

check() {
  local label="$1"
  local status="$2"
  local detail="${3:-}"

  if [ "$status" = "PASS" ]; then
    RESULTS+=("  [PASS] ${label} ${detail}")
    PASS=$((PASS + 1))
  elif [ "$status" = "WARN" ]; then
    RESULTS+=("  [WARN] ${label} ${detail}")
    WARN=$((WARN + 1))
  else
    RESULTS+=("  [FAIL] ${label} ${detail}")
    FAIL=$((FAIL + 1))
  fi
}

section() {
  RESULTS+=("")
  RESULTS+=("[$1]")
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

file_contains() {
  local file="$1"
  local pattern="$2"
  rg -q --fixed-strings "$pattern" "$file"
}

file_exists() {
  [ -f "$1" ]
}

current_env_file() {
  if [ -f "$ROOT_DIR/.env" ]; then
    printf '%s\n' "$ROOT_DIR/.env"
  else
    printf '%s\n' "$ROOT_DIR/.env.example"
  fi
}

env_value() {
  local file="$1"
  local key="$2"

  awk -F= -v target="$key" '
    $0 ~ /^[[:space:]]*#/ { next }
    $1 == target {
      sub(/^[^=]*=/, "", $0)
      print $0
      exit
    }
  ' "$file"
}

env_has_nonempty() {
  local file="$1"
  local key="$2"
  local value

  value="$(env_value "$file" "$key")"
  [ -n "$value" ]
}

env_has_placeholder() {
  local file="$1"
  local key="$2"
  local value

  value="$(env_value "$file" "$key")"
  [[ "$value" == change_me* ]]
}

run_bash_syntax_check() {
  local file="$1"
  if bash -n "$file" >/dev/null 2>&1; then
    check "bash syntax $(basename "$file")" "PASS"
  else
    check "bash syntax $(basename "$file")" "FAIL"
  fi
}

section "로컬 도구"

for cmd in kubectl helm aws k6 node npm rg; do
  if has_cmd "$cmd"; then
    check "command $cmd" "PASS" "($(command -v "$cmd"))"
  else
    if [ "$cmd" = "k6" ] || [ "$cmd" = "aws" ] || [ "$cmd" = "helm" ] || [ "$cmd" = "kubectl" ]; then
      check "command $cmd" "FAIL" "(실험 당일 필수)"
    else
      check "command $cmd" "WARN"
    fi
  fi
done

section "필수 파일"

required_files=(
  "$ROOT_DIR/k8s/config.env"
  "$ROOT_DIR/k8s/cluster-init.sh"
  "$ROOT_DIR/k8s/deploy-workloads.sh"
  "$ROOT_DIR/k8s/install-observability.sh"
  "$ROOT_DIR/k8s/manifests/workloads/gateway.yaml"
  "$ROOT_DIR/k8s/manifests/workloads/httproutes.yaml"
  "$ROOT_DIR/k8s/manifests/workloads/chat-deployment.yaml"
  "$ROOT_DIR/k8s/manifests/workloads/chat-service.yaml"
  "$ROOT_DIR/k8s/manifests/security/netpol-all.yaml"
  "$ROOT_DIR/k8s/manifests/hpa/chat-hpa.yaml"
  "$ROOT_DIR/k8s/helm/prometheus-adapter-values.yaml"
  "$ROOT_DIR/load-tests/k6/scenarios/chat-websocket.js"
  "$ROOT_DIR/load-tests/k6/helpers.js"
  "$ROOT_DIR/load-tests/scripts/get-token.js"
  "$ROOT_DIR/load-tests/scripts/package.json"
  "$ROOT_DIR/load-tests/k8s/debug-iperf3-pods.yaml"
  "$ROOT_DIR/k8s/manifests/chaos/fi-18-chat-cross-node-network-degradation.yaml"
)

for file in "${required_files[@]}"; do
  if file_exists "$file"; then
    check "file $(realpath --relative-to="$ROOT_DIR" "$file")" "PASS"
  else
    check "file $(realpath --relative-to="$ROOT_DIR" "$file")" "FAIL"
  fi
done

section "환경 변수"

ENV_FILE="$(current_env_file)"
if [ -f "$ENV_FILE" ]; then
  check "env file" "PASS" "($(realpath --relative-to="$ROOT_DIR" "$ENV_FILE"))"
else
  check "env file" "FAIL"
fi

required_env_keys=(
  SPRING_PROFILES_ACTIVE
  JWT_SECRET
  DB_URL
  DB_USERNAME
  DB_PASSWORD
  SPRING_REDIS_HOST
  SPRING_REDIS_PORT
  SPRING_RABBITMQ_HOST
  SPRING_RABBITMQ_PORT
  SPRING_RABBITMQ_USERNAME
  SPRING_RABBITMQ_PASSWORD
  MONGO_URI
  KAKAO_CLIENT_ID
  KAKAO_CLIENT_SECRET
  KAKAO_REDIRECT_URI
  KAKAO_FRONTEND_REDIRECT
  KAKAO_REST_API_KEY
  KAKAO_BOOK_BASE_URL
  ZOOM_ACCOUNT_ID
  ZOOM_CLIENT_ID
  ZOOM_CLIENT_SECRET
  AI_BASE_URL
  AI_API_KEY
  AWS_S3_BUCKET_NAME
  AWS_REGION
  FIREBASE_SERVICE_ACCOUNT_FILE
  FIREBASE_CREDENTIALS_PATH
)

for key in "${required_env_keys[@]}"; do
  if env_has_nonempty "$ENV_FILE" "$key"; then
    check "env $key" "PASS"
  else
    check "env $key" "FAIL" "(누락 또는 빈 값)"
  fi
done

for key in \
  JWT_SECRET \
  KAKAO_CLIENT_ID \
  KAKAO_CLIENT_SECRET \
  KAKAO_REST_API_KEY \
  ZOOM_ACCOUNT_ID \
  ZOOM_CLIENT_ID \
  ZOOM_CLIENT_SECRET \
  AI_API_KEY; do
  if env_has_placeholder "$ENV_FILE" "$key"; then
    check "env placeholder $key" "WARN" "(change_me 교체 필요)"
  fi
done

FIREBASE_FILE_VALUE="$(env_value "$ENV_FILE" "FIREBASE_SERVICE_ACCOUNT_FILE")"
if [ -n "$FIREBASE_FILE_VALUE" ]; then
  FIREBASE_HOST_FILE="$ROOT_DIR/${FIREBASE_FILE_VALUE#./}"
  if [ -f "$FIREBASE_HOST_FILE" ]; then
    check "firebase credential file" "PASS" "($(realpath --relative-to="$ROOT_DIR" "$FIREBASE_HOST_FILE"))"
  else
    check "firebase credential file" "FAIL" "(${FIREBASE_FILE_VALUE})"
  fi
fi

section "스크립트 문법"

run_bash_syntax_check "$ROOT_DIR/k8s/cluster-init.sh"
run_bash_syntax_check "$ROOT_DIR/k8s/deploy-workloads.sh"
run_bash_syntax_check "$ROOT_DIR/k8s/install-observability.sh"
run_bash_syntax_check "$ROOT_DIR/scripts/network-roadmap-preflight.sh"

section "클러스터/네트워크 설정 정합성"

if file_contains "$ROOT_DIR/k8s/cluster-init.sh" "encapsulation: VXLAN"; then
  check "Calico encapsulation" "PASS" "(VXLAN)"
else
  check "Calico encapsulation" "FAIL"
fi

if file_contains "$ROOT_DIR/k8s/cluster-init.sh" "bgp: Disabled"; then
  check "Calico BGP" "PASS" "(Disabled)"
else
  check "Calico BGP" "FAIL"
fi

if file_contains "$ROOT_DIR/k8s/cluster-init.sh" "externalTrafficPolicy=Cluster"; then
  check "NGF externalTrafficPolicy" "PASS" "(Cluster)"
else
  check "NGF externalTrafficPolicy" "FAIL"
fi

if file_contains "$ROOT_DIR/k8s/manifests/workloads/gateway.yaml" "gatewayClassName: nginx"; then
  check "Gateway class" "PASS"
else
  check "Gateway class" "FAIL"
fi

if file_contains "$ROOT_DIR/k8s/manifests/workloads/httproutes.yaml" "value: /ws/chat" &&
   file_contains "$ROOT_DIR/k8s/manifests/workloads/httproutes.yaml" "replacePrefixMatch: /api/ws" &&
   file_contains "$ROOT_DIR/k8s/manifests/workloads/httproutes.yaml" "backendRequest: \"1h\"" &&
   file_contains "$ROOT_DIR/k8s/manifests/workloads/httproutes.yaml" "name: chat-svc" &&
   file_contains "$ROOT_DIR/k8s/manifests/workloads/httproutes.yaml" "port: 8081"; then
  check "WebSocket route" "PASS" "(/ws/chat -> /api/ws -> chat-svc:8081)"
else
  check "WebSocket route" "FAIL"
fi

if file_contains "$ROOT_DIR/k8s/manifests/workloads/chat-deployment.yaml" "replicas: 2" &&
   file_contains "$ROOT_DIR/k8s/manifests/workloads/chat-deployment.yaml" "component: chat" &&
   file_contains "$ROOT_DIR/k8s/manifests/workloads/chat-service.yaml" "component: chat"; then
  check "chat label/selector" "PASS"
else
  check "chat label/selector" "FAIL"
fi

if file_contains "$ROOT_DIR/k8s/manifests/security/netpol-all.yaml" "name: allow-ngf-to-chat" &&
   file_contains "$ROOT_DIR/k8s/manifests/security/netpol-all.yaml" "name: allow-ngf-dataplane-egress" &&
   file_contains "$ROOT_DIR/k8s/manifests/security/netpol-all.yaml" "name: allow-dns-egress"; then
  check "NetworkPolicy set" "PASS"
else
  check "NetworkPolicy set" "FAIL"
fi

if file_contains "$ROOT_DIR/k8s/manifests/hpa/chat-hpa.yaml" "name: chat_ws_sessions_active" &&
   file_contains "$ROOT_DIR/k8s/helm/prometheus-adapter-values.yaml" "seriesQuery: 'chat_ws_sessions_active'"; then
  check "chat HPA custom metric" "PASS"
else
  check "chat HPA custom metric" "FAIL"
fi

section "부하테스트 준비"

if file_contains "$ROOT_DIR/load-tests/k6/scenarios/chat-websocket.js" "wss://api.doktori.kr/ws/chat" &&
   file_contains "$ROOT_DIR/load-tests/k6/scenarios/chat-websocket.js" "ws_connect_duration" &&
   file_contains "$ROOT_DIR/load-tests/k6/scenarios/chat-websocket.js" "ws_errors"; then
  check "k6 websocket scenario" "PASS"
else
  check "k6 websocket scenario" "FAIL"
fi

if file_contains "$ROOT_DIR/load-tests/k6/helpers.js" 'const tokenUrl = `${baseUrl}/dev/tokens`'; then
  check "multi token path" "PASS" "(/api/dev/tokens 경유)"
else
  check "multi token path" "WARN" "(helpers.js 확인 필요)"
fi

if file_contains "$ROOT_DIR/load-tests/scripts/package.json" "\"playwright\"" &&
   file_contains "$ROOT_DIR/load-tests/scripts/get-token.js" "oauth/kakao"; then
  check "token helper" "PASS" "(OAuth 보조 스크립트 존재)"
else
  check "token helper" "WARN"
fi

section "주의 / 블로커"

if file_contains "$ROOT_DIR/k8s/bootstrap-sequence.md" "CNI: Cilium" ||
   file_contains "$ROOT_DIR/k8s/bootstrap-sequence.md" "k8s-app=cilium"; then
  check "bootstrap-sequence CNI 문서" "FAIL" "(Calico 기준으로 수정 필요)"
else
  check "bootstrap-sequence CNI 문서" "PASS"
fi

if file_contains "$ROOT_DIR/load-tests/scripts/get-token.js" "https://your-api.com/api/oauth/kakao"; then
  check "get-token.js 기본값" "WARN" "(OAUTH_URL, FRONTEND_URL 환경변수 지정 필요)"
else
  check "get-token.js 기본값" "PASS"
fi

section "실험 당일 최소 순서"

RESULTS+=("  1) Terraform/노드 준비 완료 확인")
RESULTS+=("  2) master에서 ./k8s/cluster-init.sh")
RESULTS+=("  3) worker join 확인: kubectl get nodes")
RESULTS+=("  4) ./k8s/deploy-workloads.sh")
RESULTS+=("  5) ./k8s/install-observability.sh")
RESULTS+=("  6) Pod Ready 확인 후 same-node / cross-node 실험")
RESULTS+=("  7) k6 -> iperf3 -> ping DF -> tcpdump -> ss/nstat 순서로 결과 저장")

printf '\nCalico VXLAN WebSocket Preflight\n'
printf '================================\n'
for line in "${RESULTS[@]}"; do
  printf '%s\n' "$line"
done

printf '\nSummary: PASS=%d WARN=%d FAIL=%d\n' "$PASS" "$WARN" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
