# Alloy Dev 배포 - 이어서 할 일

## 현재 상태 (2026-02-19)

- [x] config.alloy 환경변수화 (`env("MONITORING_IP")`, `env("ALLOY_ENV")`)
- [x] docker-compose.dev.yml에 alloy, nginx-exporter 서비스 + 환경변수 추가
- [x] 서버에 alloy, nginx-exporter 컨테이너 띄움
- [x] `mount_point_exclude` → `mount_points_exclude` 오타 수정
- [ ] **DB_PASSWORD 실제 값으로 설정** (MySQL 메트릭 수집 안 됨)
- [ ] **config.alloy에서 nginx 파일 수집 블록 제거** (에러 로그 발생 중)
- [ ] 모니터링 서버에서 메트릭/로그 수신 확인

## 서버에서 실행할 명령 (순서대로)

```bash
# 1. config.alloy 수정 — nginx 파일 수집 블록 제거
#    아래 두 블록을 삭제:
#    - local.file_match "nginx_logs" { ... }
#    - loki.source.file "nginx" { ... }
sudo vi ~/app/alloy/config.alloy

# 2. .env에서 DB_PASSWORD를 실제 MySQL 비밀번호로 수정
sudo vi ~/app/.env
#    DB_PASSWORD=<진짜비밀번호>

# 3. alloy 재시작
cd ~/app
docker compose restart alloy

# 4. 에러 없는지 확인
docker compose logs alloy --tail 30

# 5. 모니터링 서버에서 수신 확인 (모니터링 서버 SSH 접속 후)
curl -s 'http://localhost:9090/api/v1/query?query=up{env="dev"}' | jq '.data.result | length'
curl -s 'http://localhost:3100/loki/api/v1/query?query={env="dev"}' | jq '.data.result | length'
```

## 삭제해야 할 config.alloy 블록

```alloy
// 이 두 블록을 삭제:
local.file_match "nginx_logs" {
  path_targets = [
    { "__path__" = "/var/log/nginx/access.log", "app" = "nginx", "log_type" = "access" },
    { "__path__" = "/var/log/nginx/error.log",  "app" = "nginx", "log_type" = "error" },
  ]
}

loki.source.file "nginx" {
  targets    = local.file_match.nginx_logs.targets
  forward_to = [loki.relabel.add_env.receiver]
}
```

이유: nginx alpine이 로그를 stdout/stderr 심볼릭 링크로 처리해서 파일 tail 실패.
nginx 로그는 `loki.source.docker`가 Docker 소켓으로 이미 수집 중.

## 에러 없이 떴을 때 기대되는 수집 항목

| 수집 대상 | 방식 | 목적지 |
|-----------|------|--------|
| 호스트 메트릭 (CPU, mem, disk) | prometheus.exporter.unix | Prometheus |
| MySQL 메트릭 | prometheus.exporter.mysql | Prometheus |
| Spring Boot (backend:8080, chat:8081) | prometheus.scrape | Prometheus |
| Nginx 메트릭 | nginx-exporter → prometheus.scrape | Prometheus |
| 컨테이너 로그 (전체) | loki.source.docker | Loki |
