# Service Down

| 항목 | 값 |
|------|-----|
| Alert UID | `service_down` |
| Severity | Critical |
| 조건 | `max by(app) (up{env="prod"}) < 1` — 3분 지속 |
| 대상 | api, chat 서비스 |

---

## 1. 즉시 확인

```bash
# SSH 접속 (SSM)
aws ssm start-session --target <instance-id>

# 컨테이너 상태 확인
docker ps -a --filter "name=api\|chat"

# 최근 종료 컨테이너 로그
docker logs --tail 200 <container-name>
```

## 2. 원인 진단

| 증상 | 원인 | 확인 방법 |
|------|------|-----------|
| `Exited (137)` | OOM Killed | `docker inspect <id> \| grep OOMKilled`, `dmesg \| grep -i oom` |
| `Exited (1)` | 앱 에러 (설정/DB) | `docker logs <container>` 에서 스택트레이스 확인 |
| 컨테이너 없음 | 배포 실패 / 수동 삭제 | 배포 로그, GitHub Actions 확인 |
| 컨테이너 Running인데 up=0 | 헬스체크 실패 | `curl localhost:<port>/actuator/health` |

## 3. 복구

```bash
# 방법 1: 컨테이너 재시작
docker restart <container-name>

# 방법 2: 재배포 (Blue/Green)
# GitHub Actions에서 prod-deploy workflow 수동 실행

# 방법 3: 이전 이미지로 롤백
docker stop <container-name>
docker run -d --name <container-name> <previous-image-tag>
```

## 4. 복구 확인

- [ ] `up{env="prod", app="<app>"}` 메트릭 1로 복귀
- [ ] `curl <서비스URL>/actuator/health` → `{"status":"UP"}`
- [ ] Grafana alert resolved 알림 수신

## 5. 에스컬레이션

| 시간 | 행동 |
|------|------|
| 5분 이내 | 직접 복구 시도 |
| 5~15분 | 백엔드 개발자 호출 |
| 15분 초과 | 팀 리드 + 장애 공지 |

## 관련 대시보드

- [Infrastructure](http://13.125.29.187:3000/d/infrastructure)
- [Logs (ERROR)](http://13.125.29.187:3000/d/logs?var-app=api&var-env=prod&var-level=ERROR&from=now-15m&to=now)