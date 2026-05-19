# Calico VXLAN WebSocket Before / After

> 목적: same-node / cross-node / MTU 조정 전후 결과를 한 문서에 모은다.

---

## 1. 테스트 조건

| 항목 | 값 |
|---|---|
| 시나리오 | `k6/scenarios/chat-websocket.js` |
| WS URL | `wss://api.doktori.kr/ws/chat` |
| CHAT_ROOM_IDS | `1,2,3` |
| 측정 지표 | `ws_connect_duration`, `ws_errors`, `ws_connect_failed` |
| 비교 축 | same-node / cross-node / MTU 조정 전후 |

---

## 2. 결과 요약

| 조건 | p95 | p99 | error rate | connect failed | 메모 |
|---|---:|---:|---:|---:|---|
| baseline | TBD | TBD | TBD | TBD | |
| same-node | TBD | TBD | TBD | TBD | |
| cross-node | TBD | TBD | TBD | TBD | |
| after MTU review | TBD | TBD | TBD | TBD | |

---

## 3. 로그 메모

### Chat

```text
<heartbeat timeout / close / timeout 로그>
```

### Gateway

```text
<upstream timeout / close 관련 로그>
```

---

## 4. 해석

- same-node 대비 cross-node 에서 tail latency 가 증가하는가:
- retransmission 지표와 방향이 일치하는가:
- MTU 조정 후 개선이 재현되는가:

