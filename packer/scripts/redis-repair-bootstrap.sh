#!/usr/bin/env bash
# =============================================================================
# Redis 인스턴스 긴급 복구 스크립트
#
# 용도: user_data가 실패해서 Redis 비밀번호/Alloy config가 미설정된 인스턴스 복구
# 실행: sudo bash redis-repair-bootstrap.sh
#
# 사전 조건:
#   - SSM에 /${PROJECT_NAME}/${ENV}/SPRING_REDIS_PASSWORD 가 존재해야 함
#   - Terraform apply로 위 파라미터를 먼저 생성한 뒤 실행
# =============================================================================
set -euo pipefail

log() { echo "[redis-repair] $*"; }

PROJECT_NAME="${PROJECT_NAME:-doktori}"
ENV="${ENV:-prod}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
SSM_PREFIX="/${PROJECT_NAME}/${ENV}"

# NODE_NAME/NODE_ROLE는 단일 노드 기본값. HA일 경우 환경변수로 override 가능.
NODE_NAME="${NODE_NAME:-redis-a}"
NODE_ROLE="${NODE_ROLE:-primary}"
REDIS_SENTINEL_ENABLED="${REDIS_SENTINEL_ENABLED:-false}"
REDIS_MASTER_NAME="${REDIS_MASTER_NAME:-doktori-master}"
REDIS_PRIMARY_DNS="${REDIS_PRIMARY_DNS:-redis-a.mgmt.doktori.internal}"
REDIS_SENTINEL_QUORUM="${REDIS_SENTINEL_QUORUM:-2}"

get_param() {
  local path="$SSM_PREFIX/$1"
  local attempt
  for attempt in $(seq 1 10); do
    local val
    if val=$(aws ssm get-parameter \
      --region "$AWS_REGION" \
      --name "$path" \
      --with-decryption \
      --query "Parameter.Value" \
      --output text 2>/dev/null); then
      echo "$val"
      return 0
    fi
    log "SSM 재시도 $attempt/10: $path"
    sleep 3
  done
  log "오류: SSM 파라미터를 가져올 수 없음: $path"
  log "Terraform apply로 SPRING_REDIS_PASSWORD를 먼저 생성했는지 확인하세요."
  return 1
}

# ─── SSM에서 비밀번호 조회 ────────────────────────────────────────────────────
log "SSM에서 SPRING_REDIS_PASSWORD 조회 중..."
REDIS_PASSWORD="$(get_param SPRING_REDIS_PASSWORD)"
if [ -z "$REDIS_PASSWORD" ] || [ "$REDIS_PASSWORD" = "CHANGE_ME" ]; then
  log "오류: SPRING_REDIS_PASSWORD가 비어있거나 CHANGE_ME 상태입니다."
  exit 1
fi
log "비밀번호 조회 성공 (길이: ${#REDIS_PASSWORD})"

# ─── Redis 설정 적용 ──────────────────────────────────────────────────────────
log "Redis 설정 파일 작성 중..."
install -m 0755 -d /etc/redis

cat >/etc/redis/redis.conf <<EOF
bind 0.0.0.0
protected-mode no
port 6379
supervised systemd
dir /var/lib/redis
appendonly yes
requirepass $REDIS_PASSWORD
masterauth $REDIS_PASSWORD
EOF

if [ "$NODE_ROLE" = "replica" ]; then
  echo "replicaof $REDIS_PRIMARY_DNS 6379" >>/etc/redis/redis.conf
fi

if [ "$REDIS_SENTINEL_ENABLED" = "true" ]; then
  cat >/etc/redis/sentinel.conf <<EOF
bind 0.0.0.0
protected-mode no
port 26379
dir /var/lib/redis
sentinel monitor $REDIS_MASTER_NAME $REDIS_PRIMARY_DNS 6379 $REDIS_SENTINEL_QUORUM
sentinel auth-pass $REDIS_MASTER_NAME $REDIS_PASSWORD
sentinel down-after-milliseconds $REDIS_MASTER_NAME 5000
sentinel failover-timeout $REDIS_MASTER_NAME 60000
sentinel parallel-syncs $REDIS_MASTER_NAME 1
EOF
  chown redis:redis /etc/redis/redis.conf /etc/redis/sentinel.conf
  chmod 0640 /etc/redis/redis.conf /etc/redis/sentinel.conf
else
  chown redis:redis /etc/redis/redis.conf
  chmod 0640 /etc/redis/redis.conf
fi

systemctl daemon-reload
systemctl enable redis-server
systemctl restart redis-server
log "redis-server 재시작 완료"

# ─── Alloy 설정 적용 ──────────────────────────────────────────────────────────
log "Alloy 설정 파일 작성 중..."
install -m 0750 -o root -g alloy -d /etc/alloy

printf "%s" "$REDIS_PASSWORD" >/etc/alloy/redis-password
chown root:alloy /etc/alloy/redis-password
chmod 0640 /etc/alloy/redis-password

cat >/etc/alloy/config.alloy <<EOF
prometheus.exporter.unix "host" {
  set_collectors = ["cpu", "meminfo", "diskstats", "filesystem", "loadavg", "netdev"]
}

prometheus.exporter.redis "redis" {
  redis_addr          = "127.0.0.1:6379"
  redis_password_file = "/etc/alloy/redis-password"
}

prometheus.scrape "host_metrics" {
  targets         = prometheus.exporter.unix.host.targets
  forward_to      = [prometheus.relabel.data_common.receiver]
  scrape_interval = "30s"
}

prometheus.scrape "redis_metrics" {
  targets         = prometheus.exporter.redis.redis.targets
  forward_to      = [prometheus.relabel.data_common.receiver]
  scrape_interval = "15s"
}

prometheus.relabel "data_common" {
  forward_to = [prometheus.remote_write.monitoring.receiver]
  rule {
    replacement  = "$ENV"
    target_label = "env"
  }
  rule {
    replacement  = "redis"
    target_label = "service"
  }
  rule {
    replacement  = "$NODE_NAME"
    target_label = "instance"
  }
  rule {
    replacement  = "$NODE_ROLE"
    target_label = "role"
  }
}

prometheus.remote_write "monitoring" {
  endpoint {
    url = "http://monitoring.mgmt.doktori.internal:9090/api/v1/write"
  }
}
EOF

chown root:alloy /etc/alloy/config.alloy
chmod 0640 /etc/alloy/config.alloy

systemctl enable alloy
systemctl restart alloy
log "alloy 재시작 완료"

# ─── Sentinel 재시작 (HA 모드) ────────────────────────────────────────────────
if [ "$REDIS_SENTINEL_ENABLED" = "true" ]; then
  systemctl enable redis-sentinel
  systemctl restart redis-sentinel
  log "redis-sentinel 재시작 완료"
fi

# ─── 검증 ─────────────────────────────────────────────────────────────────────
log "상태 검증 중..."
sleep 2

if redis-cli -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q PONG; then
  log "Redis 응답: PONG (비밀번호 인증 정상)"
else
  log "경고: Redis ping 실패 — systemctl status redis-server 확인 필요"
fi

if systemctl is-active --quiet alloy; then
  log "Alloy 서비스: active"
else
  log "경고: Alloy 서비스 inactive — journalctl -u alloy -n 30 확인 필요"
fi

log ""
log "복구 완료. 다음 명령으로 상태 확인:"
log "  systemctl status redis-server alloy"
log "  journalctl -u alloy -f"
