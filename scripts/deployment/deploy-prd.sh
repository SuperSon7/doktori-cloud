#!/usr/bin/env bash
set -euo pipefail

SERVICE="${1:-}"
APP_DIR="/home/ubuntu/app"
ARTIFACT_DIR="$APP_DIR/artifacts"
NGINX_CONF="/etc/nginx/sites-available/default"
DEPLOY_ENV_FILE="/etc/deploy-env"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
PROMETHEUS_CONF="/etc/prometheus/prometheus.yml"

# Grafana Silence API (배포 중 알림 억제)
GRAFANA_URL="${GRAFANA_URL:-}"
GRAFANA_SA_TOKEN="${GRAFANA_SA_TOKEN:-}"
SILENCE_DURATION_MINUTES=10
SILENCE_ID=""

# 버전 관리 설정
VERSION_DIR="$APP_DIR/versions"
MAX_VERSIONS=5  # 최근 5개 버전 유지

if [ -z "$SERVICE" ]; then
  echo "❌ Usage: $0 {fe|be|ai}"
  exit 1
fi

echo "=== Deploying $SERVICE (PRODUCTION) ==="

OLD_FE_PORT=""
OLD_BE_PORT=""
OLD_AI_PORT=""

# ---------------------------
# 1. Helper Functions
# ---------------------------
read_deploy_env() {
  if [ -f "$DEPLOY_ENV_FILE" ]; then
    tr -d '\r\n ' < "$DEPLOY_ENV_FILE"
  else
    echo "prd"
  fi
}

get_param() {
  local name="$1"
  aws ssm get-parameter --region "$AWS_REGION" --name "$name" --with-decryption --query "Parameter.Value" --output text
}

require_nonempty() {
  local key="$1"
  local val="$2"
  if [ -z "$val" ] || [ "$val" = "None" ]; then
    echo "❌ Missing/empty param: $key"
    exit 1
  fi
}

current_nginx_port() {
  local pattern="$1"
  local default="$2"
  grep -oP "$pattern" "$NGINX_CONF" | head -n 1 || echo "$default"
}

reload_nginx() {
  sudo systemctl reload nginx
}

check_service_health() {
  local name="$1"
  local url="$2"
  local max_retry="${3:-12}"

  echo "🩺 [$name] 헬스 체크 중... ($url)"
  local status="000"
  for i in $(seq 1 "$max_retry"); do
    sleep 5
    status="$(curl -o /dev/null -s -w "%{http_code}" "$url" 2>/dev/null || echo "000")"
    echo "  Attempt $i/$max_retry: HTTP $status"
    if [ "$status" = "200" ]; then
      echo "  ✅ $name 가동 확인 완료!"
      return 0
    fi
  done
  echo "  ❌ $name 응답 실패 (HTTP $status)"
  return 1
}

get_file_hash() {
  local file="$1"
  if [ -f "$file" ]; then
    sha256sum "$file" | awk '{print $1}'
  else
    echo "none"
  fi
}

# 버전 정보 생성
generate_version_tag() {
  echo "v$(date +%Y%m%d-%H%M%S)"
}

# 버전 백업 (롤백용)
backup_version() {
  local service="$1"
  local color="$2"
  local version_tag="$3"

  local backup_dir="$VERSION_DIR/$service/$version_tag"
  mkdir -p "$backup_dir"

  case "$service" in
    be)
      cp "$APP_DIR/backend/app-$color.jar" "$backup_dir/app.jar" 2>/dev/null || true
      cp "$APP_DIR/backend/.env-$color" "$backup_dir/.env" 2>/dev/null || true
      ;;
    ai)
      rsync -a --exclude 'venv' --exclude '__pycache__' \
        "$APP_DIR/ai-$color/" "$backup_dir/"
      ;;
    fe)
      tar -czf "$backup_dir/frontend.tar.gz" -C "$APP_DIR/frontend-$color" . 2>/dev/null || true
      ;;
  esac

  echo "$version_tag" > "$backup_dir/VERSION"
  echo "📦 Backed up: $service/$version_tag"
}

# 오래된 버전 정리
cleanup_old_versions() {
  local service="$1"
  local service_version_dir="$VERSION_DIR/$service"

  if [ ! -d "$service_version_dir" ]; then
    return 0
  fi

  local version_count=$(ls -1 "$service_version_dir" | wc -l)

  if [ "$version_count" -gt "$MAX_VERSIONS" ]; then
    echo "🧹 Cleaning old versions (keeping latest $MAX_VERSIONS)..."
    ls -1t "$service_version_dir" | tail -n +$((MAX_VERSIONS + 1)) | while read old_version; do
      rm -rf "$service_version_dir/$old_version"
      echo "  Removed: $old_version"
    done
  fi
}

# 버전 목록 조회
list_versions() {
  local service="$1"
  local service_version_dir="$VERSION_DIR/$service"

  if [ ! -d "$service_version_dir" ]; then
    echo "No versions found for $service"
    return 0
  fi

  echo "📋 Available versions for $service:"
  ls -1t "$service_version_dir" | head -n "$MAX_VERSIONS"
}

create_deploy_silence() {
  if [ -z "$GRAFANA_URL" ] || [ -z "$GRAFANA_SA_TOKEN" ]; then
    echo "⚠️  GRAFANA_URL/GRAFANA_SA_TOKEN 미설정 — Silence 건너뜀"
    return 0
  fi

  local starts_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local ends_at=$(date -u -d "+${SILENCE_DURATION_MINUTES} minutes" +"%Y-%m-%dT%H:%M:%SZ")

  SILENCE_ID=$(curl -sf -X POST \
    "${GRAFANA_URL}/api/alertmanager/grafana/api/v2/silences" \
    -H "Authorization: Bearer ${GRAFANA_SA_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"matchers\": [{
        \"name\": \"alertname\",
        \"value\": \"Service Down|Service Restarted|Probe Failure\",
        \"isRegex\": true,
        \"isEqual\": true
      }],
      \"startsAt\": \"${starts_at}\",
      \"endsAt\": \"${ends_at}\",
      \"createdBy\": \"deploy-prd.sh\",
      \"comment\": \"Deployment ${VERSION_TAG:-unknown} - ${SERVICE:-unknown}\"
    }" | jq -r '.silenceID' 2>/dev/null) || true

  if [ -n "$SILENCE_ID" ] && [ "$SILENCE_ID" != "null" ]; then
    echo "🔇 Silence created: ${SILENCE_ID} (${SILENCE_DURATION_MINUTES}분 자동 만료)"
  else
    echo "⚠️  Silence 생성 실패 — 배포는 계속 진행"
    SILENCE_ID=""
  fi
}

delete_deploy_silence() {
  if [ -z "${SILENCE_ID:-}" ] || [ -z "$GRAFANA_URL" ]; then
    return 0
  fi

  curl -sf -X DELETE \
    "${GRAFANA_URL}/api/alertmanager/grafana/api/v2/silence/${SILENCE_ID}" \
    -H "Authorization: Bearer ${GRAFANA_SA_TOKEN}" 2>/dev/null || true
  echo "🔔 Silence deleted: ${SILENCE_ID}"
  SILENCE_ID=""
}

setup_firebase_key() {
  local env="$1"
  local param_path="/doktori/${env}/FIREBASE_SERVICE_ACCOUNT"
  local dest_file="$APP_DIR/backend/firebase-service-account.json"

  echo "🔥 Fetching Firebase Key from SSM: $param_path" >&2

  local content="$(get_param "$param_path")"

  if [ -z "$content" ] || [ "$content" == "None" ]; then
    echo "🚨 [Error] SSM Parameter not found or empty: $param_path" >&2
    return 1
  fi

  echo "$content" > "$dest_file"
  echo "✅ File created: $dest_file" >&2
  echo "file:$dest_file"
}

# ---------------------------
# 2. Env Loaders (systemd용)
# ---------------------------
create_be_env_file() {
  local color="$1"
  local env_name="$2"
  local env_path="/doktori/${env_name}"
  local env_file="$APP_DIR/backend/.env-$color"

  echo "🔐 Creating BE env file for $color (ENV=$env_name)"

  local db_url="$(get_param "${env_path}/DB_URL")"
  local db_username="$(get_param "${env_path}/DB_USERNAME")"
  local db_password="$(get_param "${env_path}/DB_PASSWORD")"
  local jwt_secret="$(get_param "${env_path}/JWT_SECRET")"
  local kakao_client_id="$(get_param "${env_path}/KAKAO_CLIENT_ID")"
  local kakao_client_secret="$(get_param "${env_path}/KAKAO_CLIENT_SECRET")"
  local kakao_redirect_uri="$(get_param "${env_path}/KAKAO_REDIRECT_URI")"
  local kakao_frontend_redirect="$(get_param "${env_path}/KAKAO_FRONTEND_REDIRECT")"
  local kakao_rest_api_key="$(get_param "${env_path}/KAKAO_REST_API_KEY")"
  local zoom_account_id="$(get_param "${env_path}/ZOOM_ACCOUNT_ID")"
  local zoom_client_id="$(get_param "${env_path}/ZOOM_CLIENT_ID")"
  local zoom_client_secret="$(get_param "${env_path}/ZOOM_CLIENT_SECRET")"

  local firebase_path
  firebase_path="$(setup_firebase_key "$env_name")" || exit 1

  require_nonempty "DB_URL" "$db_url"
  require_nonempty "JWT_SECRET" "$jwt_secret"

  cat > "$env_file" <<EOF
SPRING_PROFILES_ACTIVE=$env_name
DB_URL=$db_url
DB_USERNAME=$db_username
DB_PASSWORD=$db_password
JWT_SECRET=$jwt_secret
KAKAO_CLIENT_ID=$kakao_client_id
KAKAO_CLIENT_SECRET=$kakao_client_secret
KAKAO_REDIRECT_URI=$kakao_redirect_uri
KAKAO_FRONTEND_REDIRECT=$kakao_frontend_redirect
KAKAO_REST_API_KEY=$kakao_rest_api_key
ZOOM_ACCOUNT_ID=$zoom_account_id
ZOOM_CLIENT_ID=$zoom_client_id
ZOOM_CLIENT_SECRET=$zoom_client_secret
FIREBASE_CREDENTIALS_PATH=$firebase_path
EOF

  chmod 600 "$env_file"
  echo "✅ Created: $env_file"
}

create_ai_env_file() {
  local color="$1"
  local env_name="$2"
  local env_path="/doktori/${env_name}"
  local env_file="$APP_DIR/ai-$color/.env"

  echo "🔐 Creating AI env file for $color (ENV=$env_name)"

  local db_url="$(get_param "${env_path}/DB_URL")"
  local gemini_api_key="$(get_param "${env_path}/GEMINI_API_KEY")"

  require_nonempty "DB_URL" "$db_url"
  require_nonempty "GEMINI_API_KEY" "$gemini_api_key"

  cat > "$env_file" <<EOF
DB_URL=$db_url
GEMINI_API_KEY=$gemini_api_key
EOF

  chmod 600 "$env_file"
  echo "✅ Created: $env_file"
}

# ---------------------------
# 3. Service Launchers (systemd)
# ---------------------------
start_fe() {
  local mode="$1"
  local color="$2"
  local port="$3"
  local version_tag="$4"
  local target_dir="$APP_DIR/frontend-$color"
  local artifact_file="$ARTIFACT_DIR/fe/frontend-build.tar.gz"
  local hash_file="$target_dir/.deployed_hash"

  echo "📦 [FE] ($color:$port) - Version: $version_tag"

  # 기존 버전 백업
  if [ -d "$target_dir" ] && [ "$(ls -A $target_dir 2>/dev/null)" ]; then
    backup_version "fe" "$color" "$(cat $target_dir/.version 2>/dev/null || echo 'pre-'$version_tag)"
  fi

  mkdir -p "$target_dir"

  local new_hash=$(get_file_hash "$artifact_file")
  local old_hash="empty"

  if [ -f "$hash_file" ]; then
    old_hash=$(cat "$hash_file")
  fi

  if [ "$new_hash" != "$old_hash" ] || [ "$mode" == "new" ]; then
    echo "🔄 Artifact changed or forced new deployment. Extracting..."
    rm -rf "$target_dir"/*
    tar -xzf "$artifact_file" -C "$target_dir"
    cd "$target_dir"
    pnpm install --frozen-lockfile --prod
    echo "$new_hash" > "$hash_file"
    echo "$version_tag" > "$target_dir/.version"
  else
    echo "⏩ Artifact is identical. Skipping extract & install."
    cd "$target_dir"
  fi

  pm2 delete "frontend-$color" 2>/dev/null || true
  PORT="$port" pm2 start pnpm --name "frontend-$color" -- start

  cleanup_old_versions "fe"
}

start_be() {
  local mode="$1"
  local color="$2"
  local port="$3"
  local deploy_env="$4"
  local version_tag="$5"
  local target_jar="$APP_DIR/backend/app-$color.jar"
  local hash_file="$APP_DIR/backend/app-$color.hash"

  local source_jar="$(ls -t "$ARTIFACT_DIR/be/"*.jar 2>/dev/null | grep -v plain | head -1 || echo "")"

  if [ -z "$source_jar" ]; then
    echo "❌ Error: No backend artifact found."
    exit 1
  fi

  echo "📦 [BE] ($color:$port) - Version: $version_tag"
  mkdir -p "$APP_DIR/backend/logs"

  # 기존 버전 백업
  if [ -f "$target_jar" ]; then
    backup_version "be" "$color" "$(cat $APP_DIR/backend/.version-$color 2>/dev/null || echo 'pre-'$version_tag)"
  fi

  local new_hash=$(get_file_hash "$source_jar")
  local old_hash="empty"

  if [ -f "$hash_file" ]; then
    old_hash=$(cat "$hash_file")
  fi

  if [ "$new_hash" != "$old_hash" ] || [ "$mode" == "new" ] || [ ! -f "$target_jar" ]; then
    echo "🔄 Artifact changed. Copying new JAR..."
    cp "$source_jar" "$target_jar"
    echo "$new_hash" > "$hash_file"
    echo "$version_tag" > "$APP_DIR/backend/.version-$color"
  else
    echo "⏩ JAR is identical. Using existing file."
  fi

  create_be_env_file "$color" "$deploy_env"

  # systemd로 시작
  sudo systemctl stop doktori-be-$color 2>/dev/null || true
  sleep 2
  sudo systemctl start doktori-be-$color

  echo "✅ Backend started via systemd (doktori-be-$color)"

  cleanup_old_versions "be"
}

start_ai() {
  local mode="$1"
  local color="$2"
  local port="$3"
  local deploy_env="$4"
  local version_tag="$5"
  local target_dir="$APP_DIR/ai-$color"
  local source_dir="/home/ubuntu/app/ai-repo"

  echo "📦 [AI] ($color:$port) - Version: $version_tag"

  # 기존 버전 백업
  if [ -d "$target_dir" ] && [ "$(ls -A $target_dir 2>/dev/null)" ]; then
    backup_version "ai" "$color" "$(cat $target_dir/.version 2>/dev/null || echo 'pre-'$version_tag)"
  fi

  mkdir -p "$target_dir/logs"

  if [ -d "$source_dir" ]; then
    rsync -a --delete \
      --exclude 'venv' \
      --exclude '__pycache__' \
      --exclude '.git' \
      --exclude '*.log' \
      "$source_dir/" "$target_dir/"
  else
    echo "❌ Error: Git repository not found at $source_dir"
    exit 1
  fi

  cd "$target_dir"
  echo "$version_tag" > "$target_dir/.version"

  if [ ! -d "venv" ]; then
    local python_bin="${PYENV_ROOT:-$HOME/.pyenv}/versions/3.10.19/bin/python"
    [ -x "$python_bin" ] || python_bin="python3"
    "$python_bin" -m venv venv
  fi

  source venv/bin/activate

  # gunicorn 설치 (systemd에서 필요)
  pip install gunicorn --no-cache-dir

  local req_hash=$(get_file_hash "requirements.txt")
  local installed_hash_file="venv/.installed_hash"
  local installed_hash="none"

  if [ -f "$installed_hash_file" ]; then
    installed_hash=$(cat "$installed_hash_file")
  fi

  if [ "$req_hash" != "$installed_hash" ]; then
    echo "🔄 Requirements changed. Installing dependencies..."

    if [ -f "requirements-torch.txt" ]; then
        pip install -r requirements-torch.txt --index-url https://download.pytorch.org/whl/cpu --no-cache-dir
    else
        pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu --no-cache-dir
    fi

    pip install -r requirements.txt --no-cache-dir
    echo "$req_hash" > "$installed_hash_file"
  else
    echo "⏩ Dependencies up-to-date. Skipping pip install."
  fi

  create_ai_env_file "$color" "$deploy_env"

  # systemd로 시작
  sudo systemctl stop doktori-ai-$color 2>/dev/null || true
  sleep 2
  sudo systemctl start doktori-ai-$color

  echo "✅ AI Server started via systemd (doktori-ai-$color)"

  cleanup_old_versions "ai"
}

# ---------------------------
# 4. Main Execution
# ---------------------------
DEPLOY_ENV="$(read_deploy_env)"
VERSION_TAG="$(generate_version_tag)"

echo "🚀 [Deploy Start] Service: $SERVICE / Env: $DEPLOY_ENV / Version: $VERSION_TAG"

# 배포 중 알림 억제
create_deploy_silence
trap delete_deploy_silence EXIT

# 버전 디렉토리 초기화
mkdir -p "$VERSION_DIR"/{fe,be,ai}

CURRENT_FE_PORT="$(current_nginx_port 'proxy_pass http://127\.0\.0\.1:\K\d+' '3000')"

if [ "$CURRENT_FE_PORT" = "3000" ]; then
  TARGET_COLOR="green"
  OLD_COLOR="blue"
  FE_PORT=3001; BE_PORT=8081; AI_PORT=8001
  OLD_FE_PORT=3000; OLD_BE_PORT=8080; OLD_AI_PORT=8000
else
  TARGET_COLOR="blue"
  OLD_COLOR="green"
  FE_PORT=3000; BE_PORT=8080; AI_PORT=8000
  OLD_FE_PORT=3001; OLD_BE_PORT=8081; OLD_AI_PORT=8001
fi

echo "📍 Direction: $OLD_COLOR -> $TARGET_COLOR"

case "$SERVICE" in
  fe)
    start_fe "check" "$TARGET_COLOR" "$FE_PORT" "$VERSION_TAG"
    start_be "check" "$TARGET_COLOR" "$BE_PORT" "$DEPLOY_ENV" "$VERSION_TAG"
    start_ai "check" "$TARGET_COLOR" "$AI_PORT" "$DEPLOY_ENV" "$VERSION_TAG"
    ;;
  be)
    start_fe "check" "$TARGET_COLOR" "$FE_PORT" "$VERSION_TAG"
    start_be "check" "$TARGET_COLOR" "$BE_PORT" "$DEPLOY_ENV" "$VERSION_TAG"
    start_ai "check" "$TARGET_COLOR" "$AI_PORT" "$DEPLOY_ENV" "$VERSION_TAG"
    ;;
  ai)
    start_fe "check" "$TARGET_COLOR" "$FE_PORT" "$VERSION_TAG"
    start_be "check" "$TARGET_COLOR" "$BE_PORT" "$DEPLOY_ENV" "$VERSION_TAG"
    start_ai "check" "$TARGET_COLOR" "$AI_PORT" "$DEPLOY_ENV" "$VERSION_TAG"
    ;;
  *)
    echo "Unknown service: $SERVICE"
    exit 1
    ;;
esac

echo "🔍 All-in-One Health Check..."
CHECK_FE=0; CHECK_BE=0; CHECK_AI=0

if check_service_health "Frontend" "http://127.0.0.1:$FE_PORT" 6; then CHECK_FE=1; fi
if check_service_health "Backend"  "http://127.0.0.1:$BE_PORT/api/health" 12; then CHECK_BE=1; fi
if check_service_health "AI-Server" "http://127.0.0.1:$AI_PORT/health" 6; then CHECK_AI=1; fi

if [ "$CHECK_FE" -eq 1 ] && [ "$CHECK_BE" -eq 1 ] && [ "$CHECK_AI" -eq 1 ]; then
  echo "✅ 검증 성공! 트래픽 전환."

  sudo sed -i "s/127\.0\.0\.1:300[01]/127.0.0.1:$FE_PORT/g" "$NGINX_CONF"
  sudo sed -i "s/127\.0\.0\.1:808[01]/127.0.0.1:$BE_PORT/g" "$NGINX_CONF"
  sudo sed -i "s/127\.0\.0\.1:800[01]/127.0.0.1:$AI_PORT/g" "$NGINX_CONF"

  reload_nginx

  sudo sed -i "s/localhost:808[01]/localhost:$BE_PORT/g" "$PROMETHEUS_CONF"
  sudo systemctl restart prometheus

  echo "⏳ 전환 완료. 10초 대기 후 구버전 정리..."
  sleep 10

  # Cleanup
  pm2 delete "frontend-$OLD_COLOR" 2>/dev/null || true
  sudo systemctl stop doktori-be-$OLD_COLOR 2>/dev/null || true
  sudo systemctl stop doktori-ai-$OLD_COLOR 2>/dev/null || true

  # 배포 성공 — Silence 즉시 해제
  delete_deploy_silence
  trap - EXIT

  echo "✨ 배포 완료! Version: $VERSION_TAG"
  echo "📦 Deployed versions:"
  list_versions "$SERVICE"
else
  echo "❌ 실패. 롤백(유지)."
  pm2 delete "frontend-$TARGET_COLOR" 2>/dev/null || true
  sudo systemctl stop doktori-be-$TARGET_COLOR 2>/dev/null || true
  sudo systemctl stop doktori-ai-$TARGET_COLOR 2>/dev/null || true
  exit 1
fi