# 인프라 개선 백로그

> 보안 / DevOps / SRE 관점에서 현재 미구현 항목을 임팩트-난이도 매트릭스로 정리
>
> 생성: 2026-03-20
> 최종 갱신: 2026-03-20

---

## 임팩트-난이도 매트릭스

```
          높은 임팩트
              │
    ┌─────────┼─────────┐
    │ ★ 핵심  │  차별화  │
    │ 1,2,3,4 │  6,9    │
    │ 5,7,8   │         │
    ├─────────┼─────────┤
    │ 여유 시  │  보류   │
    │ 10,11   │  14    │
    │ 12,13   │         │
    └─────────┼─────────┘
              │
   낮은 난이도 ──────── 높은 난이도
```

---

## Tier 1: 핵심 — 높은 임팩트 + 낮은~중간 난이도

### 1. Secret 관리 개선 (ESO + Vault 또는 SOPS)

| 항목 | 내용 |
|------|------|
| **현재** | SSM Parameter Store + K8s Secret (수동) |
| **문제** | AWS 완전 종속, 로테이션 없음, GitOps로 시크릿 관리 불가 |
| **목표** | External Secrets Operator로 추상화 + 백엔드 교체 가능 구조 |
| **난이도** | 중 |
| **포트폴리오 임팩트** | ⭐⭐⭐ — 면접 단골 질문, 클라우드 종속 탈피 어필 |
| **선택지** | |

| 방식 | 클라우드 종속 | 운영 부담 | 적합 시점 |
|------|-------------|----------|----------|
| SOPS + age/KMS | 낮음 (age key면 독립) | 낮음 | 즉시 가능 |
| ESO + AWS Secrets Manager | 중간 (ESO가 추상화) | 낮음 | 즉시 가능 |
| ESO + Vault | 없음 | 중~높 (Vault 운영) | 여유 있을 때 |

**피드백 반영**: "파라메터 스토어 의존 줄이고 Vault 등으로 클라우드 종속 탈피"

---

### 2. 분산 트레이싱 (Tempo + OpenTelemetry)

| 항목 | 내용 |
|------|------|
| **현재** | ❌ 없음 — Observability 3대 축 중 Tracing만 빠져있음 |
| **문제** | MSA 환경에서 요청 흐름 추적 불가. API→Chat→RabbitMQ→DB 전체 경로 디버깅 어려움 |
| **목표** | Grafana Tempo + Alloy(OTLP receiver) + Spring Boot 자동 계측 |
| **난이도** | 중 |
| **포트폴리오 임팩트** | ⭐⭐⭐ — "메트릭+로그+트레이싱 전부 구축" 어필 가능 |

**구현 방향**:
- Alloy에 OTLP receiver 추가 (이미 Alloy 사용 중이라 자연스러움)
- monitoring 서버에 Tempo 배포
- Spring Boot Micrometer Tracing + OTLP exporter 설정 (앱 팀 협업)
- Grafana datasource에 Tempo 추가 → 로그↔트레이스 연결

---

### 3. Pod Security Standards (PSS) 적용

| 항목 | 내용 |
|------|------|
| **현재** | 개별 deployment에 securityContext만 설정 |
| **문제** | 클러스터 레벨 강제 없음 → 누군가 privileged 파드 배포 가능 |
| **목표** | 네임스페이스에 `restricted` 프로필 enforce |
| **난이도** | 낮 |
| **포트폴리오 임팩트** | ⭐⭐ — 보안 강화의 기본, 면접에서 PSS vs PSP 질문 대비 |

**구현 방향**:
```yaml
# 네임스페이스에 레이블 추가
metadata:
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
```
- 기존 워크로드가 이미 readOnly + noPrivilegeEscalation이라 호환 가능성 높음
- warn 모드로 먼저 테스트 → enforce로 전환

---

### 4. CI 보안 스캔 (Trivy + kube-linter)

| 항목 | 내용 |
|------|------|
| **현재** | ECR scan on push만 (결과가 CI에 반영 안 됨) |
| **문제** | CVE가 있는 이미지가 프로덕션에 배포될 수 있음 |
| **목표** | PR 단계에서 이미지 취약점 + K8s 매니페스트 검증 |
| **난이도** | 낮 |
| **포트폴리오 임팩트** | ⭐⭐ — shift-left security, 이제는 기본 |

**구현 방향**:
- GHA에 `aquasecurity/trivy-action` 추가 (이미지 스캔)
- `kube-linter` 또는 `kubesec`로 매니페스트 검증
- CRITICAL/HIGH CVE 발견 시 PR 머지 차단

---

### 5. Egress NetworkPolicy

| 항목 | 내용 |
|------|------|
| **현재** | Ingress default-deny만 (아웃바운드는 전부 허용) |
| **문제** | 파드가 외부 임의 IP로 통신 가능 → 데이터 유출 경로 |
| **목표** | Egress default-deny + 필요한 대상만 허용 (DNS, DB, 외부 API) |
| **난이도** | 중 |
| **포트폴리오 임팩트** | ⭐⭐ — zero-trust 완성 |

**주의**: Egress deny 시 DNS(CoreDNS)를 반드시 허용해야 함. 빠뜨리면 모든 서비스 네임 리졸브 실패.

---

### 7. Incident Response 체계 문서화

| 항목 | 내용 |
|------|------|
| **현재** | 런북 21개 있지만 IR 프로세스(SEV 분류, 에스컬레이션) 없음 |
| **문제** | "장애 나면 어떻게 대응하나요?" 질문에 체계적 답변 불가 |
| **목표** | SEV 분류 기준 + 에스컬레이션 체인 + 포스트모텀 템플릿 |
| **난이도** | 낮 (문서 작업) |
| **포트폴리오 임팩트** | ⭐⭐⭐ — SRE 성숙도의 핵심 지표 |

---

### 8. DR 계획 문서화

| 항목 | 내용 |
|------|------|
| **현재** | RDS 7일 백업만, RTO/RPO 미정의 |
| **문제** | "복구 목표 시간이 뭔가요?" 질문에 답변 불가 |
| **목표** | 서비스별 RTO/RPO 정의 + 복구 절차 문서화 + 복구 테스트 |
| **난이도** | 낮 (문서 작업) |
| **포트폴리오 임팩트** | ⭐⭐ — 시니어 레벨 면접 필수 |

---

## Tier 2: 차별화 — 높은 임팩트 + 높은 난이도

### 6. Progressive Delivery (Argo Rollouts)

| 항목 | 내용 |
|------|------|
| **현재** | Rolling Update (maxUnavailable: 0, maxSurge: 1) |
| **문제** | 배포 후 문제 감지가 수동. SLO 위반 시 자동 롤백 없음 |
| **목표** | Canary 배포 + Grafana 메트릭 기반 자동 분석 + 롤백 |
| **난이도** | 높 |
| **포트폴리오 임팩트** | ⭐⭐⭐ — SRE 핵심 역량, 차별화 요소 |

---

### 9. Supply Chain Security (cosign + SBOM)

| 항목 | 내용 |
|------|------|
| **현재** | ❌ 없음 |
| **문제** | 이미지 무결성 검증 없음, 어떤 이미지든 클러스터에서 실행 가능 |
| **목표** | CI에서 이미지 서명 → admission webhook에서 서명 검증 |
| **난이도** | 높 |
| **포트폴리오 임팩트** | ⭐⭐ — 트렌드이지만 대부분의 팀이 아직 미구현 |

---

## Tier 3: 여유 시 — 중간 임팩트

| # | 항목 | 현재 | 한 줄 요약 | 난이도 |
|---|------|------|----------|--------|
| 10 | RDS Multi-AZ | 단일 AZ | DB 단일 장애점. 프로덕션 약점 | 낮 (TF 한 줄) |
| 11 | Secrets 자동 로테이션 | 수동 | Secrets Manager + Lambda 조합 | 중 |
| 12 | Spot Instance 전략 | 전부 On-Demand | 비용 최적화 어필 | 중 |
| 13 | K8s Audit Logging → SIEM | etcd 암호화만 | API server 감사 로그 수집 | 중 |
| 14 | OPA/Kyverno 정책 엔진 | ❌ 없음 | PSS보다 세밀한 정책 (Tier 1 #3과 택1) | 높 |
| 15 | DynamoDB Lock 테이블 제거 | DDB 사용 중 | TF 1.10+ 네이티브 S3 락으로 전환 | 낮 |

---

## 진행 기록

| # | 항목 | 상태 | 완료일 | 비고 |
|---|------|------|--------|------|
| 1 | Secret 관리 개선 | 🔲 Todo | - | |
| 2 | 분산 트레이싱 | 🔲 Todo | - | |
| 3 | Pod Security Standards | 🔲 Todo | - | |
| 4 | CI 보안 스캔 | 🔲 Todo | - | |
| 5 | Egress NetworkPolicy | ✅ Done | 2026-03-20 | ingress+egress default-deny, 서비스별 허용 룰 구현 |
| 6 | Progressive Delivery | 🔲 Todo | - | |
| 7 | IR 체계 문서화 | 🔲 Todo | - | |
| 8 | DR 계획 문서화 | 🔲 Todo | - | |
| 9 | Supply Chain Security | 🔲 Todo | - | |
| 10 | RDS Multi-AZ | 🔲 Todo | - | |
| 11 | Secrets 로테이션 | 🔲 Todo | - | |
| 12 | Spot Instance | 🔲 Todo | - | |
| 13 | K8s Audit Logging | 🔲 Todo | - | |
| 14 | OPA/Kyverno | 🔲 Todo | - | |
| 15 | DynamoDB Lock 제거 | 🔲 Todo | - | backend.hcl에서 dynamodb_table 제거 + use_lockfile=true |