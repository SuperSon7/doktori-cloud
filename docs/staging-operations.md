# Staging 환경 운영 가이드

> Staging은 prod 배포 전 검증 게이트이자, 부하 테스트 환경입니다.

---

## 아키텍처 개요

```
VPC: 10.2.0.0/16 (staging 전용)
├── nginx (t4g.nano) ─ EIP
├── front (t4g.nano)
├── api   (t4g.nano)
├── chat  (t4g.micro)
├── ai    (t4g.micro)
├── monitoring (t3.micro)
└── RDS MySQL (db.t4g.micro)
```

## 비용

| 상태 | 설명 | 월 예상 비용 |
|------|------|:---:|
| Running | EC2 + RDS 실행 중 | ~$59 |
| Stopped | EC2/RDS 정지, VPC 유지 | ~$12 |
| Destroyed | 전체 삭제 | $0 |

---

## 워크플로우 트리거

GitHub Actions → `Staging: Manage Environment` (workflow_dispatch)

### 액션 목록

| 액션 | 설명 | 소요 시간 |
|------|------|-----------|
| `apply` | Terraform으로 전체 인프라 생성 (base→app→data) | ~15분 |
| `start` | 정지된 EC2/RDS 시작 + 헬스체크 | ~3분 |
| `stop` | EC2/RDS 정지 (비용 절감) | ~1분 |
| `deploy` | 서비스 배포 (image_tag 필수) | ~3분 |
| `scale` | EC2 스펙 변경 (staging↔prod) | ~5분 |
| `destroy` | 전체 인프라 삭제 (data→app→base) | ~10분 |

---

## 운영 시나리오

### 최초 셋업
```
apply → (인프라 생성 완료) → deploy (image_tag 지정)
```

### 일상 운영 (테스트 시작/종료)
```
start → (테스트 진행) → stop
```

### 부하 테스트
```
start → scale (prod) → deploy (테스트할 이미지) → (테스트) → scale (staging) → stop
```

### 장기 미사용 정리
```
destroy → (비용 $0)
```

### 재구축
```
apply → deploy
```

---

## 배포 게이트 (CI/CD 연동)

각 서비스 레포에서 `deploy-service.yml`을 호출하여 staging 배포를 수행합니다.

```yaml
# 서비스 레포 CI/CD에서 호출 예시
deploy-staging:
  uses: 100-hours-a-week/5-team-service-cloud/.github/workflows/deploy-service.yml@main
  with:
    service_name: api        # api | chat | front | ai
    image_tag: sha-abc1234   # ECR 이미지 태그
  secrets:
    AWS_DEPLOY_ROLE_ARN: ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
    ECR_REGISTRY: ${{ secrets.ECR_REGISTRY }}
    DISCORD_WEBHOOK_URL: ${{ secrets.DISCORD_WEBHOOK_URL }}
```

### 동작 방식

1. **EC2 상태 확인**: running → 진행 / stopped → 자동 시작 / 없음 → **실패**
2. **RDS 상태 확인**: available → 진행 / stopped → 자동 시작 / 없음 → **실패**
3. **SSM 배포**: docker pull → stop → rm → run
4. **헬스체크**: localhost:{port}/{health_path} 확인 (최대 5분)
5. **결과**: 성공 시 다음 단계(prod 배포) 진행, 실패 시 **전체 배포 중단**

### 사전 준비

- Cloud repo Settings → Actions → General → Access에서 서비스 레포 접근 허용
- `AWS_DEPLOY_ROLE_ARN`, `ECR_REGISTRY` 시크릿 등록
- SSM Parameter: `/doktori/staging/FIREBASE_SERVICE_ACCOUNT` 생성 (api, chat 서비스용)

---

## 트러블슈팅

### EC2가 없다고 나올 때
```
::error::Instance doktori-staging-api not found. Run staging 'apply' in Cloud repo first.
```
**원인**: staging 인프라가 apply 되지 않았거나 destroy된 상태
**해결**: Cloud repo에서 `apply` 액션 실행 후 재시도

### RDS가 없다고 나올 때
```
::error::RDS doktori-staging-mysql not found. Run staging 'apply' in Cloud repo first.
```
**원인**: data 레이어가 apply 되지 않았거나 destroy된 상태
**해결**: Cloud repo에서 `apply` 액션 실행

### 배포 후 헬스체크 실패
```
::error::Health check failed
```
**원인 후보**:
1. 컨테이너 시작 실패 (OOM, config 오류)
2. RDS 연결 안 됨 (SG, 시작 안 됨)
3. SSM Parameter 누락 (Firebase 등)

**확인 방법**:
```bash
# SSM으로 EC2에 접속해서 확인
aws ssm start-session --target <instance-id>

# 컨테이너 로그 확인
docker logs doktori-api

# 컨테이너 상태 확인
docker ps -a
```

### RDS 시작 경합 에러 (무시 가능)
```
InvalidDBInstanceState: Instance doktori-staging-mysql is not in available state
```
**원인**: deploy-api와 deploy-chat이 동시에 RDS start 호출
**영향 없음**: `|| true`로 무시하고 `wait`로 둘 다 available 대기

### SSM 명령이 인스턴스에 도달하지 않음
```
::error::No instance matched SSM target
```
**원인 후보**:
1. SSM Agent가 설치/실행 안 됨
2. IAM 역할에 SSM 권한 없음
3. EC2 태그가 `doktori-staging-{service}` 패턴과 불일치

**해결**:
```bash
# 인스턴스 태그 확인
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=doktori-staging-api" \
  --query "Reservations[].Instances[].[InstanceId,State.Name]"

# SSM 연결 가능 여부 확인
aws ssm describe-instance-information \
  --filters "Key=tag:Name,Values=doktori-staging-api"
```

### Terraform destroy 실패 (RDS prevent_destroy)
**원인**: database 모듈에 `prevent_destroy = true` lifecycle 설정
**해결**: destroy 워크플로우는 자동으로 `terraform state rm`으로 RDS를 state에서 제거 후 destroy 진행. RDS 실제 삭제는 AWS 콘솔에서 수동 처리.

### scale 후 서비스 재시작 필요
**원인**: EC2 인스턴스 타입 변경 시 인스턴스가 재시작됨 → 컨테이너도 재시작
**해결**: `--restart unless-stopped` 설정으로 자동 복구. 복구 안 되면 `deploy` 재실행.
