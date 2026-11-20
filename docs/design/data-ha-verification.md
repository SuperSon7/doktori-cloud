> 2026-11-17 갱신: [최신 로컬 구성·IaC 검증 범위](data-ha-configuration-2026-11-17.md)를 먼저 읽는다. 아래는 11월 15일 당시의 검사 기록이며, 클라우드는 계속 미배포 상태다.

# 데이터 HA 초안 검증 기록

2026-11-15. 대상은 [설계 문서](data-ha.md)의 로컬 변경이다. **AWS 리소스 생성·변경, Terraform apply/import/destroy, 원격 push, 서비스 기동, 장애 주입은 하지 않았다.**

## 실행한 검사

| 검사 | 실제 결과 | 확인한 범위 |
| --- | --- | --- |
| Terraform 1.14.8 data root `validate` | PASS | 모듈 연결·provider schema·구성/템플릿 인자 유효성 |
| 변경 디렉터리 `terraform fmt -check` | PASS | HCL 형식 |
| provider 없는 topology 모듈 `terraform test` | 6 PASS, 0 FAIL | default/Redis/RabbitMQ/MongoDB/all/legacy 조합, stable primary 키·peer 규칙·3 AZ·Mongo 옵션 |
| `check-bootstrap.py` | 8개 렌더링 PASS | Redis/RabbitMQ 단일·HA, Mongo 단일·HA의 coordinator/follower, Bash 구문 및 embedded Mongo JS/Python 구문 |
| plan 거절 도구 Python 단위 검사 | 5 PASS | peer 생성 허용, primary 교체·축소·불명확한 입력 거절, 검사 범위 구분 |
| backend `ConfirmedNotificationPublisherTest` | 4 PASS, 0 FAIL, 0 ERROR | ACK/NACK/return/confirm timeout |
| backend `NotificationDeliveryConsumerTest` | 11 PASS, 0 FAIL, 0 ERROR | 배달/ACK, confirm 전 원본 ACK 금지, retry/DLQ 인계 실패 requeue, SSE-only 실패, ACK 실패 시 재발행 금지 |
| 각 사본 `git diff --check` | PASS | 변경 줄의 whitespace 오류 |

Java 검사는 JDK 21.0.3, Gradle 8.14.3으로 실행했다. compile 중 기존 `AntPathRequestMatcher` deprecation 경고가 있었으며 이번 변경으로 삭제하지 않았다. 기본 Windows 경로의 한글로 Gradle worker/class 로딩이 실패했으므로, ASCII 경로의 Gradle cache/build directory에서 같은 소스로 재실행한 결과를 위 표에 기록했다.

Terraform root 전체 mock 테스트는 ephemeral resource mock을 Terraform이 지원하지 않아 실행 불가했다. 이를 통과로 처리하지 않고 토폴로지 계산을 순수 모듈로 분리해 실제 6개 plan 테스트를 실행했다. 실제 data root는 별도로 validate했다. mock provider를 사용해 실제 AWS 계획을 통과시켰다고 주장하지 않는다.

Terraform CLI는 공식 배포처의 SHA256SUMS와 대조했다. `init -backend=false`로 잠긴 AWS 5.100.0, random 3.8.1 provider만 설치했다. lock file의 추가 변경은 Windows 실행 플랫폼용 checksum 두 개이며 provider 버전을 변경하지 않았다.

## 재실행 명령

다음 명령은 구성 검사만 수행한다. 배포·failover 명령이 아니다.

```bash
terraform -chdir=terraform/environments/prod/data init -backend=false -input=false
terraform -chdir=terraform/environments/prod/data validate
terraform fmt -check terraform/environments/prod/data terraform/modules/data-topology
terraform -chdir=terraform/modules/data-topology init -backend=false -input=false
terraform -chdir=terraform/modules/data-topology test
python3 scripts/data-ha/check-bootstrap.py --terraform terraform --bash bash --node node
python3 -m unittest discover -s scripts/data-ha -p 'test_*.py' -v
```

backend 사본에서는 JDK 21로 다음을 실행한다. Windows에서 cache와 build 경로에 한글이 있으면 ASCII 경로를 사용한다.

```bash
./gradlew --no-daemon --max-workers=2 :api:test \
  --tests '*ConfirmedNotificationPublisherTest' \
  --tests '*NotificationDeliveryConsumerTest'
```

## 미실행 범위

- 실제 AWS state를 읽는 `scripts/plan-all.sh`, 운영 drift·AMI 교체·기존 state 주소 검토.
- EC2/SSM 부트스트랩 실행과 Packer build. 패키지 저장소·설치 스크립트는 수정하지 않았다.
- Redis failover와 Sentinel/Lettuce 재연결, 로그인·Pub/Sub 누락 보충.
- RabbitMQ 3.13에서 기존 큐 membership grow, policy/feature flag, 실제 publisher confirm 및 DLX 인계.
- MongoDB 7.0 초기 동기화·선출·majority write 유지·드라이버 재연결.
- 실제 백업 복원, AZ 장애, RTO/RPO·성능·비용 측정.

Docker CLI는 설치되어 있으나 Linux engine에 연결되지 않았다. 요청 범위에 맞춰 엔진을 시작하거나 컨테이너를 올리지 않았다. 단위 검사 성공으로 위 항목을 완료 처리하지 않는다.

## 로컬 사본 메모

클라우드 원본에는 Windows에서 일반 경로로 checkout할 수 없는 `terraform/ ` 파일(이름이 공백 하나)이 있다. 원본 blob `352b9e282432b4ba56552bc9bf318be5bf1dfda5`의 27,582 bytes를 extended path로 그대로 보존했으며 byte 동일성을 확인했다. Git의 Windows 경로 오인으로 변경으로 표시되는 것을 막기 위해 이 파일 하나만 로컬 index에서 assume-unchanged로 표시했다. 해당 파일 내용은 HA 변경에 포함되지 않는다. 저장소 설정의 `core.protectNTFS`를 영구적으로 해제하지 않았다.

원격 저장소에는 어떤 변경도 반영하지 않았다. 로컬 코드·문서는 AI 협업 산출물이며 사용자의 장애 진단·실험 해석 역량을 확인한 증거가 아니다.
