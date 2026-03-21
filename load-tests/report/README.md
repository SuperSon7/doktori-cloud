# 부하테스트 결과 저장소

## 디렉토리 구조

```
report/
├── smoke/              # Smoke 테스트 (5 VU, 기능 검증)
├── load/               # Load 테스트 (300 VU, SLO 검증)
│   ├── *200656*        # v1 — 읽기 위주 (03/19)
│   └── *123921*        # v2 — 읽기55/쓰기45 (03/21)
├── stress/             # Stress 테스트 (1500 VU, 한계 탐색)
├── meeting-search/     # 검색 병목 테스트 (1500 VU)
├── mixed/              # REST + WebSocket 동시 부하
├── lifecycle/          # 모임 라이프사이클 (WS 30분 유지)
├── meeting-spike/      # 모임 시작 스파이크
├── loadtest-report.md  # 종합 결과 리포트
├── mixed-load-chat-report.md  # mixed 상세 분석
└── generate-report.sh  # HTML 리포트 생성기
```

## 파일명 규칙

`<runner-ip>-<scenario>-<timestamp>.log`

- `13-124-202-148` = 러너 1 (모니터링 겸용)
- `15-165-59-190` = 러너 2
- `43-201-14-184` = 러너 3

## 결과 요약

| 날짜 | 시나리오 | VU | P95 | 5xx | SLO |
|------|---------|-----|-----|-----|-----|
| 03/19 | smoke | 15 | 19ms | 0% | PASS |
| 03/19 | load v1 (읽기 위주) | 300 | 30ms | 0% | PASS |
| 03/19 | guest-flow | 300 | 21ms | 0% | PASS |
| 03/20 | stress | 1500 | 1.74s | 30% | FAIL |
| 03/20 | meeting-search | 1500 | 4.69s | 36% | FAIL |
| 03/20 | mixed (load+chatws) | 300 | timeout | 96% | FAIL (토큰 503) |
| 03/21 | mixed v2 (load+chatws) | 300 | 22ms | 0% | PASS (WS 정상) |
| 03/21 | load v2 (읽기55/쓰기45) | 300 | 48s | 14% | FAIL |
| 03/21 | lifecycle (5min) | 150 | 20ms | 0% | PASS (WS 60s 세션) |