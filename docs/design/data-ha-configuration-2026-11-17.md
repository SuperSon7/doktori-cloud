# 데이터 HA 로컬 구성과 EC2 IaC 준비

후속 가시성 구성은 [가시성 가이드·실행 증거](../../monitoring/data-ha/README.md)에 정리했다. 아래 초기 검사 기록과 구분하며 현재 로컬 dashboard·logs·alerts, native 수집/IaC 변경과 미검증 범위를 해당 문서에서 확인한다.

2026-11-17 · AI 구현·정리. 최초 요청에서는 Redis → MQ → MongoDB 순서로 로컬 구성과 IaC를 준비하고 AWS 배포·remote state 조회·실제 AWS plan/apply·Packer build·push를 하지 않았다. **후속 요청에서 실제 Packer AMI 생성·임시 자원 정리를 별도로 승인받았다.** 해당 결과와 범위는 [Packer 실행·검증 가이드](../../packer/data-ha/README.md)에 분리한다. 서비스 배포·Terraform 실제 plan/apply는 실행하지 않는다.

## 로컬 실행과 클라우드 구성의 구분

[로컬 구성](../../local/data-ha/README.md)은 Docker Desktop에서 기본 인증·복제·통신을 확인한다. EC2는 기존 native systemd·Packer 방식이며 local Compose를 EC2에 자동 배포하지 않는다. 서비스 계열과 프로토콜을 맞췄지만 OS·architecture·AMI·디스크·DNS·SG·IAM이 동일하다고 주장하지 않는다.

## IaC에 준비한 항목

| 단계 | EC2 구성·접속 | 추가로 정리한 것 |
| --- | --- | --- |
| Redis | 서로 다른 private_db_a/b/c, data 3·Sentinel 3, peer/data/Sentinel 통신, SSM master/nodes | Sentinel 인증과 앱 password binding, redis 사용자에게 설정 rewrite directory 권한, 초기 bootstrap 허용과 정상 운영 발견 구분 |
| RabbitMQ | broker 3, peer SG·DNS·SSM addresses, cookie는 기존 base 소유 SSM에서 주입 | 새 AMI recipe 기본값 4.3/Erlang 27, classic peer discovery, 매 기동 reset 제거, queue별 3-member voter·DLX policy operator script |
| MongoDB | data-bearing 멤버 3, peer SG·DNS, keyfile·replica set·multi-seed MONGO_URI | 완성된 기존 set의 rejoin 시 primary 강제/객체 재생성 생략, 앱 key/index와 majority/journal URI |

서비스별 HA flag는 기본 false이고 기존 primary resource key는 유지한다. `ha_ami_ids`는 활성화한 HA 서비스마다 검토한 실제 AMI ID를 명시하도록 요구한다. 형식 검증은 이미지 존재·버전·보안·ARM64 호환성을 입증하지 않는다. 과거 AMI default를 새 HA rollout에 조용히 재사용하지 않는다.

후속 요청으로 [Packer 빌드 실행기·AMI 인계](../../packer/data-ha/README.md)를 추가했다. 데이터 서비스만 순서대로 선택하고 manifest를 `ha_ami_ids` 검토 파일로 내보낸다. 실제 빌드 상태는 연결된 기록을 따른다. package 설치 후 서비스 자동 시작을 끄며 EC2 bootstrap이 runtime 설정 후 시작한다.

`terraform/environments/prod/data/stages/01-redis.tfvars.example`, `02-rabbitmq.tfvars.example`, `03-mongodb.tfvars.example`은 **누적 단계의 검토용 예시**다. 자동 로드하지 않으며 AMI placeholder를 그대로 사용하면 입력 검증에서 실패한다. 실제 값·state·전환 순서를 검토하기 전 apply할 파일이 아니다.

## 전환·운영에서 남은 조건

1. **초기 Redis와 steady state:** 첫 bootstrap의 `allow_redis_initial_primary=true`는 새 빈 구성에만 쓴다. 이후 false로 정리할 때 user_data 변경에 따른 EC2 stop/start 영향을 검토해야 한다. 현재 compute는 `user_data_replace_on_change=false`이며, 주소를 유지해도 무중단을 뜻하지 않는다. 두 번째 단계의 false 값은 이 정리가 이미 완료됐다는 전제다. 세 노드의 동시 재시작을 자동 안전하다고 취급하지 않는다.
2. **기존 데이터 보존:** resource key 유지와 디스크/AMI 보존은 다르다. 새 AMI·네트워크·user_data의 실제 변경을 plan과 volume·백업·복구 절차에 대조해야 한다. 정적 `check-plan.py`는 일부 위험 동작을 찾는 보조 도구이며 실제 state 검토를 대신하지 않는다.
3. **RabbitMQ 버전 전환:** 3.13 broker와 새 4.3 broker를 단순히 추가해도 된다는 구성이 아니다. 별도 버전 전환·드레인·데이터 보존과 app wait.v2 전환을 설계해야 한다. operator script는 4.3.x를 확인하고 grow에 `--membership voter`를 명시한다. CLI 옵션 도움말만 로컬에서 확인했으며 EC2에서 operator script를 실행하지 않았다.
4. **Mongo 기존 계정:** standalone에서 replica set으로 바꾸기 전 관리 계정의 clusterManager 등 필요한 권한을 확인한다. 새 bootstrap에는 해당 역할이 있지만 과거 계정이 이미 갖고 있다고 가정하지 않는다. 기존 완성 set에서는 객체·권한 변경을 자동 반복하지 않고 별도 migration/rotation으로 관리한다.
5. **앱 보장:** 기존 MQ confirm/ACK 초안과 새 Redis profile binding은 준비했으나 Spring 앱 전체·Firebase/SSE·DB commit/outbox·화면 중복·MessageMigrationRunner는 실행 검증하지 않았다. HA 토폴로지 구성으로 전체 업무 전달 보장을 완료 처리하지 않는다.
6. **실제 운영 입력:** SLO·용량·비용·TLS·운영 인증·백업 복원·AMI artifact와 secrets 주입을 확정하고 승인된 환경에서 검증해야 한다. 이번 로컬 keyfile·root bootstrap 계정·단일 PC 결과는 운영 기준이 아니다.

## 실제 수행한 로컬 검사

| 검사 | 결과·범위 |
| --- | --- |
| Compose 구성 및 Redis/MQ/Mongo readiness | 각 3노드 기본 토폴로지·인증·임시 쓰기/조회 또는 AMQP 확인. reports에 버전·범위 기록 |
| Mongo 기존 set 재진입 | secondary에서 초기화 스크립트를 재호출해 기존 set을 보존하고 종료함을 확인. 선출을 강제하지 않음 |
| Prometheus/Grafana | node별 9 target과 dashboard query 6종·provisioning 확인. UI 시각 검토·업무 성공 판정과 별도 |
| Terraform validate/fmt | data root 구문·schema 검사. remote backend/state·AWS data source를 실행하는 plan은 하지 않음 |
| provider 없는 topology test | 7개 command=plan 사례, 독립 flag·단계 2 누적·AZ subnet·primary key 등 |
| 원본 variables의 격리 입력 검사 | `check-inputs.py`가 variables만 임시 module에 복사해 4개 command=plan 사례로 AMI 누락·잘못된 형식 거부를 확인. AWS provider/resource/backend 없음 |
| bootstrap 구문 | Terraform template 실제 렌더 8개, Bash·embedded JS/Python 구문 확인. EC2 bootstrap 실행 아님 |
| plan 검토기 unit tests | 5개. 실제 AWS plan을 분석한 결과는 아님 |
| backend 검증 | 기존 MQ 15개와 실제 API/chat YAML의 Sentinel password fallback·override binding 4개. 서버 시작·AWS config import 없이 확인 |

이번 과정의 최초 MQ 설정 키 오류, peer startup 의존성, quorum queue cleanup 제약, Mongo mongosh helper 사용 오류와 도구 build cache 문제를 수정했다. 최종 성공 결과와 실패 이력을 구분해 기록한다.

## 다시 수행할 검사

로컬 실행 명령은 local README를 사용한다. 아래는 cloud repo 루트에서 실행하는 **정적·provider 없는 검사**다.

```powershell
terraform -chdir=terraform/environments/prod/data validate
terraform -chdir=terraform/modules/data-topology test
python scripts/data-ha/check-inputs.py --terraform terraform
python scripts/data-ha/check-bootstrap.py --terraform terraform --bash bash --node node
python -m unittest discover -s scripts/data-ha -p 'test_*.py' -v
```

도구 경로·플랫폼에 맞게 지정한다. bootstrap 검사에서 Windows는 Git Bash와 Node를 사용했다. `terraform init -backend=false`가 필요한 새 환경에서도 cloud backend에 연결하지 않는다. 예시를 실행하려고 AWS plan/apply·Packer build를 덧붙이지 않는다.

## 적용 스킬

`deliver-task`로 기존 구조의 구성·수정·로컬 검증을 수행하고, `technical-writer`로 로컬/클라우드·관측/미검증·실행 절차를 분리했다. 사용자의 독립 구현이나 실제 장애 분석 역량을 평가한 기록이 아니다.
