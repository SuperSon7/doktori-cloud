# 알림 변경 후 검증 가이드

알림 규칙(alert-rules.yml) 수정 후 정상 동작 확인 절차.

---

## 배포

```bash
# 1. 파일 업로드
scp -i ~/.ssh/doktori-dev.pem \
  Cloud/monitoring/grafana/provisioning/alerting/alert-rules.yml \
  ubuntu@13.125.29.187:~/monitoring/grafana/provisioning/alerting/alert-rules.yml

# 2. Grafana 재시작 (provisioning은 기동 시 로드)
ssh -i ~/.ssh/doktori-dev.pem ubuntu@13.125.29.187 "docker restart grafana"
```

> 대시보드 JSON은 30초마다 자동 리로드되므로 재시작 불필요.
> 알림 provisioning YAML은 **Grafana 재시작 필요**.

---

## 검증 체크리스트

### 1. Grafana 기동 확인

```bash
ssh -i ~/.ssh/doktori-dev.pem ubuntu@13.125.29.187 \
  "docker logs grafana --tail 20 2>&1 | grep -E 'provisioning|error|panic'"
```

- `Provisioning alerting` 로그에 에러 없는지 확인
- YAML 문법 오류 시 Grafana가 crash-loop에 빠짐

### 2. Alert Rules 로드 확인

Grafana UI → Alerting → Alert rules

- Infrastructure / Application / Info 3개 폴더 존재 확인
- 각 룰의 State 확인:
  - `Normal` (OK) — 정상
  - `Pending` — for 시간 대기 중
  - `Firing` — 알림 발화 중
  - `NoData` — 데이터 없음 (수정 후 이게 보이면 문제)

### 3. noData 오발 해소 확인

수정 전 오발하던 룰들이 정상으로 돌아왔는지:

```bash
# Prometheus에서 직접 쿼리 — 데이터가 있는지 확인
curl -s 'http://13.125.29.187:9090/api/v1/query?query=up' | \
  python3 -c "import sys,json; d=json.load(sys.stdin); [print(f'{r[\"metric\"][\"job\"]:20s} up={r[\"value\"][1]}') for r in d['data']['result']]"
```

- 모든 job의 up=1이면 Service Down은 Normal이어야 함

```bash
# 디스크 사용률 확인
curl -s 'http://13.125.29.187:9090/api/v1/query?query=1-(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}/node_filesystem_size_bytes{fstype!~"tmpfs|overlay"})' | \
  python3 -c "import sys,json; d=json.load(sys.stdin); [print(f'{r[\"metric\"].get(\"mountpoint\",\"?\"):20s} usage={float(r[\"value\"][1]):.1%}') for r in d['data']['result']]"
```

- 95% 미만이면 Disk > 95%는 Normal이어야 함

### 4. Discord 알림 확인

- 오발하던 알림이 `[RESOLVED]`로 해소 메시지 수신 확인
- 이후 15분간 동일 알림 재발 없는지 모니터링
- Watchdog (Info)은 12시간마다 정상 수신되어야 함

### 5. 실제 발화 테스트 (선택)

의도적으로 알림을 트리거해서 정상 동작 검증:

```bash
# Probe Failure 테스트: blackbox target 중 하나를 일시적으로 내리기
# → 2분 후 Probe Failure 알림 오는지 확인

# CPU High 테스트: stress 도구로 CPU 부하 생성
# ssh into dev server
# stress --cpu 4 --timeout 360  (5분 for + 여유)
# → 5분 후 CPU > 80% 알림 오는지 확인
```

---

## 트러블슈팅

| 증상 | 원인 | 해결 |
|------|------|------|
| Grafana 기동 안 됨 | YAML 문법 에러 | `docker logs grafana` 확인, YAML 검증 후 재배포 |
| 룰이 안 보임 | provisioning 실패 | Grafana 로그에서 `alerting` 관련 에러 확인 |
| 여전히 noData Firing | PromQL이 빈 결과 반환 | Prometheus UI에서 직접 쿼리 실행해 데이터 존재 확인 |
| [RESOLVED] 안 옴 | Contact Point webhook 오류 | Grafana > Alerting > Contact points > Test 버튼 |
| 알림 반복 수신 | repeat_interval 설정 | notification-policies.yml의 repeat_interval 확인 |
