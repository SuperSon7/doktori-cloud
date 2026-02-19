# Alloy Dev 배포 — 완료 (2026-02-19)

## 완료 항목

- [x] config.alloy 환경변수화 (`env("MONITORING_IP")`, `env("ALLOY_ENV")`)
- [x] docker-compose.dev.yml에 alloy, nginx-exporter 서비스 + 환경변수 추가
- [x] 서버에 alloy, nginx-exporter 컨테이너 띄움
- [x] `mount_point_exclude` → `mount_points_exclude` 오타 수정
- [x] config.alloy에서 nginx 파일 수집 블록 제거
- [x] `.env`에 `DB_PASSWORD` 실제 값 설정
- [x] 모니터링 서버 SG에 9090/3100 인바운드 추가
- [x] Loki config 수정 (무효 필드 삭제 + delete_request_store 추가 + out_of_order_time_window 제거)
- [x] nginx.conf에 stub_status 블록 추가 (8888 포트)
- [x] 컨테이너 이름 regex 수정 (`/.*(backend|...).*`)
- [x] blackbox probe에 env 라벨 추가
- [x] 모니터링 서버에서 메트릭/로그 수신 확인
- [x] alloy-data named volume 추가 (positions/WAL 보존)
- [x] app 라벨 regex 수정 (`/[^-]+-([^-]+)-.*` → 서비스명만 추출)

## 즉시 할 것 (dev 안정화)

- [ ] Prometheus 기존 외부 scrape job 제거 → 403 노이즈 제거
- [ ] Grafana 로그 대시보드 쿼리 수정 (`log_type` → `detected_level` 기반)
- [ ] Alloy `env()` deprecated 경고 대응 (v1.9.0에서 대체 함수 확인)
- [ ] nginx access log에서 모니터링 트래픽 필터 (`Prometheus/|Blackbox` 제외)
- [ ] nginx log format에 `$upstream_response_time` 추가 (백엔드 지연 가시화)

## 다음 단계 (Terraform 정리)

- [ ] 모니터링 서버 SG 인바운드를 Terraform `target_server_cidrs`로 정리
- [ ] Alloy 관련 compose 변경사항을 Terraform user_data에 반영

## Prod/Staging 배포 시

- [ ] Alloy WAL 활성화 (`loki.write` wal block)
- [ ] Loki S3 백엔드 전환
- [ ] Loki rate limit 명시 설정
- [ ] Alloy 리소스 상향 (256M → 512M)
- [ ] Docker log max-size 확대 (10m → 50m)

→ 상세: [log-reliability.md](../../runbooks/operations/log-reliability.md)

## 트러블슈팅 기록

- [`trouble Shootings/26.02.19/alloy-dev-deploy-troubleshooting.md`](에러 11건 상세)
