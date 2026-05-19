# Cloud Repo — Claude Code Instructions

## Git Conventions
- Co-Authored-By 라인 추가하지 않음
- feature/terraform 브랜치에서 작업 후 main으로 PR

## AWS 리소스 조작 규칙
- **생성**: AWS 리소스를 생성하는 모든 행위(terraform apply, aws cli, import)는 사용자 승인 후에만 실행한다.
- **삭제**: AWS 리소스 삭제(terraform destroy, aws s3 rm, aws ec2 terminate 등)는 사용자가 명시적으로 지시한 경우에만 실행한다.
- **plan/조회**: terraform plan, aws s3 ls, describe 등 읽기 전용 명령은 자유롭게 실행 가능하다.
- **절대 금지 기본값**: 사용자가 같은 턴에서 명시적으로 허락하지 않는 한 `terraform apply`, `terraform destroy`, `terraform import`, AWS 생성/수정/삭제 CLI, `git push --force`, `git push --force-with-lease`는 실행하지 않는다.
- **승인 방식**: "올리자", "진행하자", "반영하자"처럼 해석 여지가 있는 표현은 apply/force-push 승인으로 보지 않는다. 실행 직전에 무엇을 실행할지 말하고 명시적 허락을 받아야 한다.

## 설치 스크립트 작업 규칙

Packer setup script, bootstrap script, 외부 패키지 저장소를 다루는 작업은
반드시 `INSTALL-SCRIPT-AGENT-CHECKLIST.md`를 먼저 확인하고 그 절차를 따른다.

## Terraform 레이어 의존성

이 프로젝트는 레이어 간 단방향 의존성을 따른다.
상세 원칙은 `terraform/PRINCIPLES.md`를 참조한다.

### 레이어 순서
```
backend → global → shared (ecr, dns-zone, monitoring) → {env}/base → {env}/data → {env}/app
```

### 레이어 간 데이터 참조
- **인프라 식별자** (VPC ID, Subnet ID 등): `terraform_remote_state`로 상위 레이어 output 직접 참조
- **앱 시크릿** (DB 비밀번호 등): `ephemeral` + `_wo` + SSM Parameter Store (state에 저장 안 됨)
- AWS data source 태그 기반 조회는 사용하지 않는다 (태그 drift 시 실패, 속도 느림)

### Base 변경 시 PR 분리 (필수)

base 레이어에 새 output이 추가되는 변경이 있으면:

1. **base 변경만 먼저 PR** (modules/ + base layers + outputs)
2. merge → CI가 base apply → 반영 대기
3. **그 후 app/data 변경 PR** (새 리소스)

### Plan 검증

코드 변경 후 커밋 전에 반드시 `./scripts/plan-all.sh`로 전체 레이어 plan 확인.
base에 changes가 있으면 하위 레이어는 자동 skip된다.
