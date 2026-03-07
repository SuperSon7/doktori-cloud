# RabbitMQ 인프라 구축 Roadmap

> Backend-Chat 간 메시지 브로커(RabbitMQ) 도입 — Dev 환경 완료, Prod 배포 예정
>
> 트래킹 시작: 2026-03-04

---

## 진행 현황

| Phase | 제목 | 상태 | 완료일 | 비고 |
|:-----:|------|:----:|:-----:|------|
| 0 | [Dev 환경 구축](#phase-0-dev-환경-구축) | ✅ Done | 2026-03-04 | docker-compose + Parameter Store + 모니터링 |
| 1 | [Spring Boot 의존성 및 설정](#phase-1-spring-boot-의존성-및-설정) | 🔲 Todo | - | starter-amqp 추가, Config 클래스 |
| 2 | [메시징 코드 구현](#phase-2-메시징-코드-구현) | 🔲 Todo | - | Publisher/Consumer, Queue 정의 |
| 3 | [Prod 환경 배포](#phase-3-prod-환경-배포) | 🔲 Todo | - | Prod는 compose 아님, 별도 배포 필요 |
| 4 | [모니터링 대시보드](#phase-4-모니터링-대시보드) | 🔲 Todo | - | Grafana RabbitMQ 패널 |

---

## Phase 0: Dev 환경 구축

**목표:** Dev 서버에 RabbitMQ 컨테이너 가동, Spring에서 연결 가능한 상태

### Checklist
- [x] docker-compose.yml에 rabbitmq 서비스 추가 (Cloud 레포 + Dev 서버)
- [x] backend/chat depends_on + 환경변수 설정
- [x] Dev 서버 .env에 `RABBITMQ_USER`, `RABBITMQ_PASS` 추가
- [x] Parameter Store 등록 (dev: `/doktori/dev/SPRING_RABBITMQ_*`)
- [x] Parameter Store 등록 (prod: `/doktori/prod/SPRING_RABBITMQ_*`)
- [x] application.yml에 `spring.rabbitmq` 섹션 추가 (api + chat 모듈)
- [x] RabbitMQ 컨테이너 healthy 상태 확인
- [x] Alloy config에 `prometheus.scrape "rabbitmq"` (15692 포트) 추가
- [x] Alloy 로그 수집 regex에 rabbitmq 추가
- [x] Alloy 재시작 후 메트릭 수집 정상 확인

### 산출물
- `Cloud/docker-compose.yml` — rabbitmq 서비스, backend/chat 환경변수
- `Cloud/monitoring/alloy/config.alloy` — rabbitmq scrape + 로그 수집
- `Backend/api/src/main/resources/application.yml` — spring.rabbitmq 설정
- `Backend/chat/src/main/resources/application.yml` — spring.rabbitmq 설정

### 접속 정보 (Dev)
| 항목 | 값 |
|------|-----|
| AMQP | `rabbitmq:5672` (컨테이너 내부) |
| Management UI | `http://13.209.183.40:15672` (보안그룹 필요) |
| Prometheus 메트릭 | `rabbitmq:15692/metrics` |
| 계정 | `doktori_mq` / `zsed1235` |

---

## Phase 1: Spring Boot 의존성 및 설정

**목표:** spring-boot-starter-amqp 추가, RabbitMQ 연결 확인

### Checklist
- [ ] `build.gradle`에 `spring-boot-starter-amqp` 의존성 추가 (api + chat)
- [ ] RabbitMQ Config 클래스 작성 (Exchange, Queue, Binding 정의)
- [ ] 앱 기동 시 RabbitMQ 연결 성공 로그 확인
- [ ] health endpoint에 RabbitMQ 상태 포함 확인

### 산출물 (예상)
- `Backend/common/src/main/java/.../config/RabbitMQConfig.java`

---

## Phase 2: 메시징 코드 구현

**목표:** backend-chat 간 실제 메시지 발행/소비 동작

### Checklist
- [ ] 메시지 발행 대상 이벤트 정의 (어떤 이벤트를 MQ로 보낼지)
- [ ] Publisher 구현
- [ ] Consumer 구현
- [ ] 메시지 직렬화/역직렬화 방식 결정 (JSON 등)
- [ ] Dev 환경에서 메시지 흐름 E2E 검증

### 산출물 (예상)
- `Backend/api/src/main/java/.../event/` — Publisher 관련
- `Backend/chat/src/main/java/.../event/` — Consumer 관련

---

## Phase 3: Prod 환경 배포

**목표:** Prod 서버에 RabbitMQ 가동, Spring 앱에서 연결

### Checklist
- [ ] Prod 배포 방식 결정 (standalone Docker / Amazon MQ / ECS 등)
- [ ] Prod 서버에 RabbitMQ 컨테이너 배포
- [ ] 보안그룹 5672 포트 오픈 (앱 → MQ)
- [ ] Prod Parameter Store 값 확인 (이미 등록됨, host 값만 Prod에 맞게 수정 필요)
- [ ] Prod 앱 재배포 후 연결 확인
- [ ] Prod 모니터링 (Alloy) config에 rabbitmq scrape 추가

### 참고
- Prod는 docker-compose가 아니므로 별도 배포 전략 필요
- Parameter Store `/doktori/prod/SPRING_RABBITMQ_HOST` 값을 Prod 환경에 맞게 변경

---

## Phase 4: 모니터링 대시보드

**목표:** Grafana에서 RabbitMQ 상태를 한눈에 파악

### Checklist
- [ ] Grafana에 RabbitMQ 대시보드 추가 (큐 depth, 메시지 rate, 연결 수, 메모리)
- [ ] 알림 규칙 설정 (큐 적체, 연결 끊김 등)

### 산출물 (예상)
- Grafana 대시보드 JSON export