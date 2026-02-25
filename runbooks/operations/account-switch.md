# AWS account switch guide

Last updated: 2026-02-18
Author: jbdev

새 AWS 계정으로 전환할 때 Terraform state와 리소스를 마이그레이션하는 절차서.

## Before you begin

- 새 AWS 계정에 대한 관리자 권한 확보
- AWS CLI 프로필이 새 계정을 가리키도록 설정
- 기존 Terraform state 백업 완료

## Identify files to change

변경이 필요한 파일은 2곳뿐이다.

### 1. `terraform/backend.hcl` — 버킷 이름 변경

```hcl
bucket         = "doktori-v3-terraform-state"   # ← 새 이름
dynamodb_table = "doktori-v3-terraform-locks"   # ← 새 이름
```

### 2. `terraform/backend/main.tf` — 버킷/테이블 리소스 이름 매칭

```hcl
resource "aws_s3_bucket" "terraform_state" {
  bucket = "${var.project_name}-v3-terraform-state"
}

resource "aws_dynamodb_table" "terraform_locks" {
  name = "${var.project_name}-v3-terraform-locks"
}
```

> **Note:** `state_bucket` 변수를 사용하는 모듈도 있음. `grep -r "doktori-v2-terraform-state" terraform/`로 찾아서 일괄 교체.

## Apply the switch

1. Verify AWS CLI points to the new account

   ```bash
   aws sts get-caller-identity
   # → Account가 새 계정 ID인지 확인
   ```

2. Back up local tfstate (backend 모듈)

   ```bash
   cd terraform/backend/
   mv terraform.tfstate terraform.tfstate.old-<구계정ID>
   ```

3. Bootstrap backend (S3 + DynamoDB 생성)

   ```bash
   terraform init
   terraform apply
   ```

4. Re-init each module with new backend

   ```bash
   for dir in dev/networking dev/compute dev/storage dev/dns \
              prod/networking prod/compute prod/storage prod/dns \
              monitoring global; do
     echo "=== $dir ==="
     cd terraform/$dir
     terraform init -reconfigure -backend-config=../../backend.hcl
     cd ../..
   done
   ```

5. Plan and apply each module

   ```bash
   # 기존 리소스는 새 계정에 없으므로 모두 새로 생성됨
   cd terraform/<module>/
   terraform plan
   terraform apply
   ```

## Verify

```bash
# 새 계정에 state 버킷 존재 확인
aws s3 ls | grep terraform-state

# 각 모듈에서 state가 올바르게 연결되었는지 확인
cd terraform/dev/networking/
terraform state list
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| S3 버킷 생성 실패 (이름 충돌) | S3 버킷 이름은 글로벌 유니크 | 버킷 이름에 버전 접미사 변경 (v3 → v4) |
| `terraform init` 실패 | `.terraform/` 캐시가 구 계정 참조 | `rm -rf .terraform/` 후 다시 init |
| backend 모듈 state 충돌 | 닭-달걀 문제 (로컬 state) | `terraform.tfstate`를 백업 후 새로 apply |
| parameter-store state 오류 | 로컬 tfstate가 구 계정 참조 | 백업 후 새로 apply |

## Hardcoding removal status

| 항목 | 구 방식 | 현재 방식 |
|------|---------|----------|
| AWS Account ID | `246477585940` 하드코딩 | `data.aws_caller_identity.current.account_id` |
| KMS Key ARN | 특정 키 ID 하드코딩 | `key/*` + `kms:ViaService` 조건으로 범위 제한 |
| State Bucket | `doktori-terraform-state` 하드코딩 | `backend.hcl` 1곳 + `state_bucket` 변수 |

## What's next

- [Instance setup guide](../compute/instance-setup.md)
- [Alloy push monitoring deploy](../deployment/monitoring-deploy.md)