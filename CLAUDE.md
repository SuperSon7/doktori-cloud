# Cloud Repo — Claude Code Instructions

## Git Conventions
- Co-Authored-By 라인 추가하지 않음
- feature/terraform 브랜치에서 작업 후 main으로 PR

## Terraform 레이어 의존성

이 프로젝트는 `base → app → data` 순서의 레이어 의존성이 있다.
app/data는 `terraform_remote_state`로 base output을 참조한다.

### Base 변경 시 PR 분리 (필수)

base 레이어에 새 output이 추가되는 변경이 있으면:

1. **base 변경만 먼저 PR** (modules/ + base layers + outputs)
2. merge → CI가 base apply → remote state 반영 대기
3. **그 후 app/data 변경 PR** (새 output 참조하는 리소스)

한 PR에 합치면 CI plan에서 app/data 검증이 불가능하다 (remote state에 새 output이 없으므로 plan 실패).

### Plan 검증

코드 변경 후 커밋 전에 반드시 `./scripts/plan-all.sh`로 전체 레이어 plan 확인.
base에 changes가 있으면 하위 레이어는 자동 skip된다.
