# 데이터 HA 변경 검토

`feature/data-ha-clusters`는 Redis → RabbitMQ → MongoDB 순서의 self-managed HA 준비를 모은 브랜치다. 기준은 `88b501ec3835aff32a7e8a8913449b9a3a357fc9`이며 Karpenter·APM·전체 서비스 부하·데이터 스냅샷 작업은 포함하지 않았다.

| 구성 | 구현 내용 | 먼저 볼 파일 |
| --- | --- | --- |
| Redis | data 3개 + Sentinel 3개. Redis Cluster 샤딩 구성이 아니라 primary/replica failover 구성 | [로컬 구성](local/data-ha/README.md), [단계 1](terraform/environments/prod/data/stages/01-redis.tfvars.example) |
| RabbitMQ | broker 3개, peer discovery, quorum queue 전환 도구 | [단계 2](terraform/environments/prod/data/stages/02-rabbitmq.tfvars.example), [quorum 도구](scripts/data-ha/configure-rabbitmq-quorum.sh) |
| MongoDB | data-bearing replica set 3개, multi-seed URI·majority/journal | [단계 3](terraform/environments/prod/data/stages/03-mongodb.tfvars.example), [bootstrap](terraform/environments/prod/data/templates/mongodb_node_user_data.sh.tftpl) |
| IaC·AMI | 기본 false인 서비스별 HA flag, 기존 primary resource key 유지, 단계별 AMI 인계 | [설계·전환 조건](docs/design/data-ha-configuration-2026-11-17.md), [Packer](packer/data-ha/README.md) |
| 가시성 | exporter·Alloy·Prometheus·Grafana·alert·runbook | [관측 안내](monitoring/data-ha/README.md) |

백엔드 대응 변경은 [doktori-backend의 codex/data-ha-clients](https://github.com/SuperSon7/doktori-backend/tree/codex/data-ha-clients)에 분리했다. 앱의 HA profile·배포 이미지·NetworkPolicy를 활성화하는 작업은 아직 남아 있다. MQ의 기존 버전과 새 AMI 버전 사이의 전환, 기존 데이터 보존, 실제 failover/복원은 별도 검증 대상이다.

## 검증과 공개 범위

2026-11-20 업로드 준비 시 Python 단위 검사 22개와 provider 없는 Terraform topology 검사 7개를 다시 통과했다. 과거 Docker 기본 복제·인증·관측, Packer 실제 빌드와 임시 자원 정리 결과는 해당 날짜의 문서·보고서에 보존했다. 이를 이번에 클라우드를 기동하거나 운영 HA를 검증한 결과로 표현하지 않는다.

기존 클라우드 미조회·미배포 조건을 유지해 실제 backend/state와 연결하는 `scripts/plan-all.sh`는 실행하지 않았다. 이 브랜치는 리뷰용이며 운영 merge/apply의 검증을 완료한 브랜치가 아니다. 이번에는 새 AMI 빌드·Terraform apply·서비스 기동·장애 주입을 하지 않았다.

`.runtime`, 실제 `.env`, 인증 파일, Terraform state·plan, 실행 로그는 포함하지 않았다. AMI manifest/ID는 과거 비공개 AMI의 식별 정보이며 다른 계정에서 바로 사용할 수 있는 공개 이미지가 아니다. 포함된 화면은 당시 로컬 Grafana 관측 결과다.

문서는 기존 `technical-writer`·`korean-document-writing` 기준으로 구성·교정했고, 업로드 분리·관련 검사는 `deliver-task` 절차를 적용했다. AI 작업·과거 실행·이번 검사·미실행 범위를 구분한다.
