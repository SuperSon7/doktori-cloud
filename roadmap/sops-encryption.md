# SOPS / 암호화 도구 도입 검토 Roadmap

> SSM 보완용으로 SOPS + AWS KMS 조합을 검토하여, tfvars 민감값 및 환경별 시크릿 설정파일을 git에서 안전하게 관리한다.
>
> 트래킹 시작: 2026-03-17

---

## 진행 현황

| Phase | 제목 | 상태 | 완료일 | 비고 |
|:-----:|------|:----:|:-----:|------|
| 0 | [현황 분석](#phase-0-현황-분석) | 🔲 Todo | - | 현재 시크릿 관리 방식 정리 |
| 1 | [SOPS PoC](#phase-1-sops-poc) | 🔲 Todo | - | dev 환경에서 SOPS + KMS 검증 |
| 2 | [팀 적용](#phase-2-팀-적용) | 🔲 Todo | - | 워크플로 정립 및 CI 연동 |

---

## Phase 0: 현황 분석

**목표:** 현재 시크릿이 어디에 어떻게 관리되는지 파악하고, SOPS가 필요한 범위를 확정한다.

### Checklist
- [ ] git에 평문으로 들어간 민감값 유무 스캔 (tfvars, .env 등)
- [ ] SSM Parameter Store / Secrets Manager 사용 현황 정리
- [ ] SOPS 도입이 필요한 파일 목록 확정 (tfvars? .env? k8s secrets?)

### 산출물 (예상)
- 분석 결과 문서 (이 파일에 메모 추가)

---

## Phase 1: SOPS PoC

**목표:** dev 환경에서 SOPS + AWS KMS 조합으로 암호화/복호화 워크플로를 검증한다.

### Checklist
- [ ] SOPS 설치 및 `.sops.yaml` 설정 (KMS key ARN 지정)
- [ ] 샘플 tfvars 파일 암호화 → git commit → 복호화 테스트
- [ ] Terraform에서 SOPS provider 또는 `local_file` 경유 참조 검증
- [ ] CI(GHA)에서 KMS decrypt 권한으로 plan 가능 여부 확인

### 산출물 (예상)
- `.sops.yaml` — SOPS 설정 파일
- `terraform/environments/dev/secrets.enc.yaml` — 암호화된 시크릿 예시

---

## Phase 2: 팀 적용

**목표:** 팀 전체가 사용할 수 있도록 워크플로를 정립하고 문서화한다.

### Checklist
- [ ] 팀원 IAM에 KMS decrypt 권한 추가
- [ ] GHA workflow에 SOPS decrypt 단계 추가
- [ ] 사용 가이드 작성 (암호화/복호화/키 로테이션)
- [ ] staging/prod 환경으로 확대 적용

### 산출물 (예상)
- IAM policy 변경 (Terraform modules)
- GHA workflow 업데이트