# Terraform CI/CD 설계

이 문서는 Doktori Terraform을 GitHub Actions로 운영하는 기준이다.
`README.md`는 요약, `PRINCIPLES.md`는 의사결정 원칙, 이 문서는 실제 workflow 설계와 현행 차이 분석을 담당한다.

참고 기준:

- HashiCorp Terraform workflow: Write -> Plan -> Apply
- Terraform automation: `terraform plan -out=tfplan` 후 같은 plan 파일을 `terraform apply tfplan`로 적용
- AWS/GitHub 인증: GitHub OIDC로 AWS IAM Role assume, 장기 access key 미사용

## 목표 구조

배포 단위는 `terraform/modules/*`가 아니라 독립 state를 가진 root module이다.
모듈 변경은 그 모듈을 사용하는 root module들의 plan/apply 대상으로 확장한다.

```
.github/workflows/
  terraform-pr.yml        # PR 검증과 plan
  terraform-apply.yml     # main merge 후 순서 보장 apply
  terraform-drift.yml     # 정기 drift 감지
  terraform-staging.yml   # staging 수명주기 수동 관리
```

현재는 `terraform.yml` 하나가 PR plan, main apply, drift를 모두 담당한다. 기능은 동작하지만 조건문과 matrix가 커져서 의존성 순서 검증이 어렵다. 다음 정리 단계에서는 위처럼 파일을 분리한다.

## Root Module 목록

CI/CD는 아래 root module을 기준으로 changed matrix를 만든다.

| Group | Root modules |
|-------|--------------|
| Bootstrap | `terraform/backend` |
| Shared | `terraform/global`, `terraform/ecr`, `terraform/dns_zone` |
| Monitoring | `terraform/monitoring/base`, `terraform/monitoring/data`, `terraform/monitoring/app` |
| Dev | `terraform/environments/dev/base`, `terraform/environments/dev/data`, `terraform/environments/dev/app` |
| Staging | `terraform/environments/staging/base`, `terraform/environments/staging/data`, `terraform/environments/staging/app`, `terraform/environments/staging/loadtest` |
| Prod | `terraform/environments/prod/base`, `terraform/environments/prod/data`, `terraform/environments/prod/app`, `terraform/environments/prod/cdn` |
| Standalone loadtest | `terraform/environments/loadtest` |

`backend`은 state bucket 자체를 관리하므로 일반 자동 apply 대상에서 제외한다. 변경 시 별도 수동 절차로 실행한다.

## PR Workflow

PR에서는 apply하지 않는다. 리뷰 가능한 plan과 비용/보안 정보를 남기는 것이 목적이다.

```
detect changes
-> terraform fmt -check -recursive
-> terraform init -backend=false + terraform validate for changed roots
-> tflint
-> tfsec 또는 checkov
-> terraform plan -detailed-exitcode -out=tfplan for changed roots
-> destroy/replace 감지
-> PR comment + Infracost
```

운영 규칙:

- `modules/*` 변경 시 해당 모듈을 참조하는 모든 root module을 plan한다.
- `{env}/base` output 추가 또는 변경이 있으면 같은 PR에서 `{env}/data`, `{env}/app` plan이 실패할 수 있다. 이 경우 base PR과 하위 레이어 PR을 분리한다.
- plan 결과에 delete 또는 replace action이 있으면 PR comment에 경고한다.
- 보안 스캔은 초기에는 warning으로 시작할 수 있으나, main 보호 브랜치에서는 fail-fast로 전환한다.

## Apply Workflow

main merge 이후 apply는 state 의존성 순서를 보장한다.
모든 apply job은 `terraform plan -out=tfplan` 후 같은 job 안에서 `terraform apply tfplan`을 실행한다.
apply 직후에는 `terraform plan -detailed-exitcode`를 한 번 더 실행한다.
exit code `2`가 나오면 apply는 성공했지만 desired state에 수렴하지 않은 것으로 보고 job을 실패시킨다.

```
global
-> ecr + dns_zone
-> monitoring/base
-> monitoring/data
-> monitoring/app
-> env/base
-> monitoring/base re-apply
-> env/data
-> env/app
-> prod/cdn
```

환경별 병렬화는 같은 단계 안에서만 허용한다.

| Stage | Parallel allowed | Reason |
|-------|------------------|--------|
| `dev/base`, `staging/base`, `prod/base` | Yes | 서로 다른 state와 VPC |
| `dev/data`, `staging/data`, `prod/data` | Yes | base 이후, 서로 다른 state |
| `dev/app`, `staging/app`, `prod/app` | Yes | data 이후, 서로 다른 state |
| `monitoring/base`, `monitoring/data`, `monitoring/app` | No | app이 base/data remote state를 읽음 |
| `prod/cdn` | No | prod/app output을 읽음 |

GitHub Environment:

| Target | Environment | Approval |
|--------|-------------|----------|
| dev app/data/base | `terraform-dev` | optional |
| staging app/data/base | `terraform-staging` | recommended |
| prod app/data/base/cdn | `terraform-prod` | required reviewer |
| global/ecr/dns_zone/monitoring | `terraform-shared` | required reviewer |

## Concurrency

Terraform state lock은 마지막 안전장치이고, GitHub Actions에서도 같은 state의 동시 실행을 막는다.

권장 group:

```yaml
concurrency:
  group: terraform-${{ inputs.root_module || matrix.layer }}
  cancel-in-progress: false
```

`terraform.yml`과 `terraform-staging.yml`처럼 workflow 파일이 달라도 같은 root module을 만질 수 있으므로, group 이름은 workflow 이름이 아니라 state key 기준으로 맞춘다.

## Destroy 정책

자동 apply는 delete/replace action을 차단한다.
삭제는 `workflow_dispatch`로만 실행하고, 운영 데이터가 있는 레이어는 GitHub Environment approval을 요구한다.

감지는 문자열 grep보다 plan JSON을 기준으로 한다.

```bash
terraform show -json tfplan |
  jq -e '.resource_changes[]
    | select(.change.actions | index("delete"))'
```

replace는 actions가 `["delete", "create"]` 또는 `["create", "delete"]`로 나타나므로 같은 검사로 잡는다.

## Drift Workflow

정기 drift 감지는 전체 root module을 대상으로 한다.
drift workflow는 `terraform plan -detailed-exitcode`까지만 실행하고 apply하지 않는다.

대상:

```
global, ecr, dns_zone,
monitoring/base, monitoring/data, monitoring/app,
dev/base, dev/data, dev/app,
staging/base, staging/data, staging/app, staging/loadtest,
prod/base, prod/data, prod/app, prod/cdn
```

drift가 발견되면 Discord와 GitHub issue/comment로 알리고, 수정은 별도 PR 또는 수동 apply로 처리한다.

## 현행 차이 분석

| Area | Target | Current | Gap |
|------|--------|---------|-----|
| Workflow 분리 | PR/apply/drift/staging 파일 분리 | `terraform.yml`에 PR, apply, drift가 함께 있음 | 조건문과 matrix가 커져 순서 보장이 어렵다 |
| PR 정적 검증 | `fmt`, `validate`, lint, security scan | `tfsec`만 있고 `soft_fail: true`; `fmt`/`validate` 없음 | 기본 Terraform 문법/포맷 검증이 PR gate가 아님 |
| Changed root 목록 | 모든 root module 포함 | `dev/data`, `prod/cdn`, `staging/loadtest`, standalone `loadtest` 누락 | 실제 변경이 CI 대상에서 빠질 수 있음 |
| Shared apply 순서 | `global -> ecr/dns_zone -> monitoring/base -> data -> app` | shared matrix가 병렬 apply | monitoring 의존성 순서가 깨질 수 있음 |
| Env apply 순서 | `{env}/base -> {env}/data -> {env}/app` | app/data matrix가 병렬 apply | app이 data remote state를 읽는 환경에서 실패 가능 |
| Staging apply 순서 | `base -> data -> app` | `base -> [app, data]` 병렬 | 수동 staging apply도 같은 의존성 위험이 있음 |
| Failure propagation | 선행 apply 실패 시 후속 apply 중단 | `always()` 조건으로 후속 job이 계속 평가됨 | shared/base 실패 후 app apply가 시도될 수 있음 |
| Concurrency | state key 기준 | `terraform-${event}-${ref}`, `terraform-staging` | 서로 다른 workflow가 같은 state를 동시에 만질 수 있음 |
| Prod approval | prod/shared 별도 Environment | 단일 `terraform-apply` | prod와 dev 승인 수준 분리가 약함 |
| Destroy 감지 | plan JSON의 delete action 검사 | `grep 'will be destroyed'` | replace/delete 표현 차이를 놓칠 수 있음 |
| Drift 대상 | 전체 root module | 일부 dev/prod/monitoring만 포함 | shared, data, cdn, staging drift를 놓칠 수 있음 |
| Workflow 변경 감지 | workflow 파일 변경도 PR 검증 | path filter가 `terraform/**`, `infracost.yml` 중심 | Actions 변경 PR에서 Terraform CI가 안 돌 수 있음 |

## 이행 순서

1. `terraform.yml`의 detect matrix에 누락 root module을 추가한다.
2. PR job에 `terraform fmt -check -recursive`와 root module별 `terraform validate`를 추가한다.
3. app/data apply matrix를 분리해 `data`가 먼저 끝난 뒤 `app`이 실행되게 한다.
4. shared apply를 순서형 job으로 나누고 monitoring은 base/data/app 순서를 강제한다.
5. `concurrency` group을 state key 기준으로 통일한다.
6. prod/shared GitHub Environment를 분리하고 required reviewer를 설정한다.
7. drift matrix를 전체 root module로 확장한다.
8. 안정화 후 `terraform.yml`을 `terraform-pr.yml`, `terraform-apply.yml`, `terraform-drift.yml`로 분리한다.
