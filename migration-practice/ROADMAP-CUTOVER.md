# DB 마이그레이션 (Local MySQL → RDS) Roadmap

> EC2 로컬 MySQL에서 RDS로 무중단 마이그레이션 — 컷오버 리허설, 실측, 프로덕션 수행, 포트폴리오 기록
>
> 트래킹 시작: 2026-02-26

---

## 진행 현황

| Phase | 제목 | 상태 | 완료일 | 비고 |
|:-----:|------|:----:|:-----:|------|
| 0 | [사전 준비](#phase-0-사전-준비) | ✅ Done | 2026-02-25 | HikariCP 설정 정리, 스크립트 준비 완료 |
| 1 | [베이스라인 측정](#phase-1-베이스라인-측정-단순-전환-방식) | 🔲 Todo | - | 비교용 "단순 전환" 지표 확보 |
| 2 | [컷오버 리허설](#phase-2-컷오버-리허설-실행-및-측정) | 🔲 Todo | - | k6 부하 하 리허설 2회+ 반복 |
| 3 | [프로덕션 컷오버](#phase-3-프로덕션-컷오버) | 🔲 Todo | - | 실제 마이그레이션 수행 |
| 4 | [포트폴리오 문서화](#phase-4-포트폴리오-문서화) | 🔲 Todo | - | 실측값 기반 비교표, 면접 대비 |

---

## Phase 0: 사전 준비

**목표:** 컷오버에 필요한 스크립트·설정이 정합성 있게 정리된 상태

### Checklist
- [x] 컷오버 스크립트 v2 작성 (`06-cutover-rehearsal.sh` — nginx reload + KILL CONNECTION)
- [x] 롤백 스크립트 작성 (`07-cutover-rollback.sh`)
- [x] HikariCP stash 설정 분석 → 3개 전부 불필요 판단, stash drop
- [x] 트러블슈팅 문서 업데이트 — KILL 방식 채택 근거, connection-test-query 폐기 사유
- [x] 앱 코드 변경 불필요 확인 (application.yml hikari 섹션 origin/main과 동일)

### 산출물
- `scripts/06-cutover-rehearsal.sh` — 컷오버 v2 (reload + KILL)
- `scripts/07-cutover-rollback.sh` — 롤백 스크립트
- `trouble Shootings/26.02.24/cutover-hikari-connection-eviction.md` — HikariCP 트러블슈팅
- `trouble Shootings/26.02.25/hikari-stash-cleanup-decision.md` — stash 폐기 결정 기록

---

## Phase 1: 베이스라인 측정 (단순 전환 방식)

**목표:** "가장 단순하게 마이그레이션하면?" 의 지표를 확보해서 Phase 2 결과와 비교

### Checklist
- [ ] mysqldump 소요 시간 기록 (현재 데이터 기준, `02-mysqldump.sh` 실행)
- [ ] RDS import 소요 시간 기록 (`mysql < dump.sql`)
- [ ] 단순 전환 시 예상 총 다운타임 산출: `dump 시간 + import 시간 + 앱 재시작`
- [ ] 단순 전환 시 데이터 손실 구간 산출: dump 시작 ~ 앱 재시작 완료

### 산출물 (예상)
- `docs/baseline-measurement.md` — 단순 전환 방식 측정 결과

### 참고
- dump 시간은 이전 리허설에서 이미 수행한 적 있으면 그 기록 재활용 가능
- 핵심은 **"이 숫자를 Phase 2 결과와 나란히 놓을 수 있는가"**

---

## Phase 2: 컷오버 리허설 실행 및 측정

**목표:** k6 부하 하에서 컷오버 리허설을 실행하고, 쓰기 불가 구간·손실 건수를 실측

### Checklist
- [ ] k6 부하 스크립트 준비 (읽기 + 쓰기 혼합, 에러율 집계 가능하게)
- [ ] 리허설 1회차 실행 — `06-cutover-rehearsal.sh`
  - [ ] 쓰기 불가 구간 (초) 기록
  - [ ] k6에서 실패한 요청 수 기록 (= 데이터 손실 건수)
  - [ ] 프록시 → RDS 라우팅 전환 소요 시간 기록
- [ ] 원복 실행 — `07-cutover-rollback.sh` 또는 `99-restore-to-normal.sh`
- [ ] 리허설 2회차 실행 (반복 검증)
  - [ ] 1회차 대비 수치 일관성 확인
- [ ] 롤백 리허설 실행 — RDS → 로컬 MySQL 원복이 정상 동작하는지 확인

### 산출물 (예상)
- `docs/rehearsal-results.md` — 리허설 회차별 측정값
- `/tmp/db-migration/cutover-rehearsal-*.log` — 스크립트 자동 생성 로그

### 측정 항목 정리

| 지표 | 측정 방법 | 목표 |
|------|-----------|------|
| 쓰기 불가 구간 | 스크립트 내 `T_WRITE - T_RO` | 60초 이내 |
| 실패 요청 수 | k6 summary → `http_req_failed` | 0건 (또는 최소화) |
| KILL → 복구 | 스크립트 내 `T_WRITE - T_KILL` | 수 초 이내 |
| 데이터 정합성 | `09-checksum-verify.sh` | 불일치 0 |

---

## Phase 3: 프로덕션 컷오버

**목표:** 실제 프로덕션 DB를 RDS로 전환, 서비스 정상 운영 확인

### Checklist
- [ ] 복제 상태 확인 (Seconds_Behind_Master = 0)
- [ ] `06-cutover-rehearsal.sh` 실행 (이번엔 리허설이 아닌 실전)
- [ ] 쓰기 불가 구간 기록 (포트폴리오용 실측값)
- [ ] k6 또는 실트래픽 기준 에러 확인
- [ ] AI 서버 재시작 확인 (`doktori-ai-green`)
- [ ] 서비스 헬스체크 (API 응답, 채팅 정상)
- [ ] Grafana 모니터링 — HikariCP 커넥션 수, 응답 시간, 에러율 확인
- [ ] 데이터 정합성 검증 (`09-checksum-verify.sh`)
- [ ] 역방향 복제 설정 (`08-setup-reverse-replication.sh`) — 롤백 대비

### 산출물 (예상)
- `docs/production-cutover-report.md` — 실전 수행 결과 + 타임라인

---

## Phase 4: 포트폴리오 문서화

**목표:** 실측값 기반의 기술 포트폴리오 작성 + 면접 대비

### Checklist
- [ ] 아키텍처 결정 기록 — 왜 nginx stream proxy를 뒀는가
- [ ] 비교표 작성 (실측값 기반)

  | 항목 | 단순 전환 (Phase 1) | 무중단 방식 (Phase 3) |
  |------|---------------------|----------------------|
  | 서비스 다운타임 | ?분 | ?초 |
  | 데이터 손실 | dump 이후 전체 | 0건 |
  | 앱 코드 변경 | DB URL + 재배포 | 없음 |
  | 롤백 | dump 시점 복원만 가능 | nginx reload 즉시 원복 |

- [ ] 기술적 깊이 포인트 정리
  - HikariCP 커넥션 eviction 문제 + 해결 과정
  - nginx reload vs restart TCP 동작 차이
  - connection-test-query를 왜 버렸는가 (JDBC4 isValid 성능 퇴보)
  - KILL CONNECTION이 nginx stream proxy와 맞물리는 원리
- [ ] 면접 예상 질문 & 답변 정리
  - "왜 RDS Multi-AZ failover 안 쓰고 직접 했나?"
  - "KILL CONNECTION 대신 connection-test-query 쓰면 안 되나?"
  - "롤백은 어떻게 하나?"
  - "nginx stream proxy 없이 할 수 있나?"

### 산출물 (예상)
- `docs/portfolio-db-migration.md` — 포트폴리오 본문
- `trouble Shootings/` 하위 — 기술 결정 근거 (이미 일부 존재)