# AWS 계정 전환 가이드

새 AWS 계정으로 전환할 때 필요한 작업 체크리스트.

---

## 변경해야 할 것 (2곳만)

### 1. `terraform/backend.hcl` — 버킷 이름 변경

```hcl
# 버킷 이름만 바꾸면 됨 (S3 이름은 글로벌 유니크)
bucket         = "doktori-v3-terraform-state"   # ← 새 이름
dynamodb_table = "doktori-v3-terraform-locks"   # ← 새 이름
```

### 2. `terraform/backend/main.tf` — 버킷/테이블 리소스 이름 매칭

```hcl
resource "aws_s3_bucket" "terraform_state" {
  bucket = "${var.project_name}-v3-terraform-state"  # ← backend.hcl과 일치시킴
}

resource "aws_dynamodb_table" "terraform_locks" {
  name = "${var.project_name}-v3-terraform-locks"    # ← backend.hcl과 일치시킴
}
```

> `state_bucket` 변수를 사용하는 모듈도 있음 (dev/compute, prod/compute, dev/dns, prod/dns).
> `grep -r "doktori-v2-terraform-state" terraform/` 로 찾아서 일괄 교체.

---

## 적용 순서

```bash
# 0. AWS CLI 프로필이 새 계정을 가리키는지 확인
aws sts get-caller-identity
# → Account가 새 계정 ID인지 확인

# 1. 로컬 tfstate 백업 (backend 모듈은 로컬 state 사용)
cd terraform/backend/
mv terraform.tfstate terraform.tfstate.old-<구계정ID>

# 2. backend 부트스트랩 (S3 + DynamoDB 생성)
terraform init
terraform apply
# → 새 계정에 S3 버킷 + DynamoDB 테이블 생성됨

# 3. 각 모듈 re-init (새 backend 연결)
for dir in dev/networking dev/compute dev/storage dev/dns \
           prod/networking prod/compute prod/storage prod/dns \
           monitoring global; do
  echo "=== $dir ==="
  cd terraform/$dir
  terraform init -reconfigure -backend-config=../../backend.hcl
  cd ../..
done

# 4. 각 모듈 plan → apply (기존 리소스는 새 계정에 없으므로 모두 새로 생성)
```

---

## 하드코딩 제거 완료 항목

| 항목 | 구 방식 | 현재 방식 |
|------|---------|----------|
| AWS Account ID | `246477585940` 하드코딩 | `data.aws_caller_identity.current.account_id` |
| KMS Key ARN | 특정 키 ID 하드코딩 | `key/*` + `kms:ViaService` 조건으로 범위 제한 |
| State Bucket | `doktori-terraform-state` 하드코딩 | `backend.hcl` 1곳 + `state_bucket` 변수 |

---

## 주의사항

- **S3 버킷 이름은 글로벌 유니크** → 구 계정에서 삭제하지 않는 한 같은 이름 재사용 불가
- **backend 모듈만 로컬 state** (닭-달걀 문제) → `terraform.tfstate` 파일을 git에 올리지 말 것 (.gitignore에 이미 등록)
- **`terraform init -reconfigure`** 사용해야 기존 backend 캐시를 무시하고 새 backend로 연결됨
- 구 계정의 `.terraform/` 디렉터리가 남아있으면 `rm -rf .terraform/` 후 다시 init
- `parameter-store/` 모듈의 로컬 tfstate도 구 계정 리소스를 참조 → 백업 후 새로 apply
