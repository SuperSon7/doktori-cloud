# Chat Service Probe Failure (SLO-3)

| 항목 | 값 |
|------|-----|
| Alert UID | `slo3_chat_probe_failure` |
| Severity | Critical |
| 조건 | `probe_success{instance=~".*chat-health.*"} < 1` — 3분 지속 (연속 12회 실패) |
| 대상 | Chat 서비스 (WebSocket/STOMP) |

---

## 1. 즉시 확인

```bash
# Chat 컨테이너 상태
docker ps -a --filter "name=chat"

# 수동 헬스체크
curl -v http://localhost:<chat-port>/actuator/health

# WebSocket 연결 테스트 (STOMP)
# 프론트엔드에서 채팅방 입장 시도
```

## 2. 원인 진단

| 증상 | 원인 | 확인 방법 |
|------|------|-----------|
| 컨테이너 다운 | OOM/crash | `docker logs chat --tail 200` |
| 컨테이너 Running + health 실패 | 앱 내부 hang | Thread dump: `docker exec chat jstack 1` |
| Probe만 실패 | 네트워크/Nginx 문제 | Blackbox Exporter 로그, Nginx 설정 확인 |
| WebSocket만 실패 | STOMP Broker 장애 | Chat 로그에서 `MessageBroker` 에러 확인 |

## 3. 복구

```bash
# 방법 1: Chat 컨테이너 재시작
docker restart chat

# 방법 2: 재배포
# GitHub Actions prod-deploy workflow 실행

# 재시작 후 WebSocket 복구 확인
# → 기존 클라이언트는 자동 재연결 (SockJS fallback)
```

## 4. 복구 확인

- [ ] `probe_success{instance=~".*chat-health.*"}` → 1 복귀
- [ ] 프론트엔드에서 채팅방 입장 + 메시지 전송 성공
- [ ] `chat_ws_sessions_active` 게이지 정상 복귀
- [ ] Grafana alert resolved 알림 수신

## 5. 에스컬레이션

Chat 서비스는 실시간 커뮤니케이션 → **5분 내 복구 안 되면 즉시 백엔드 개발자 호출**

## 관련 대시보드

- [Infrastructure](http://13.125.29.187:3000/d/infrastructure)
- [Logs (Chat ERROR)](http://13.125.29.187:3000/d/logs?var-app=chat&var-env=prod&var-level=ERROR&from=now-15m&to=now)