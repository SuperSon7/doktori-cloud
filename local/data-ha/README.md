# 독토리 로컬 데이터 HA 구성

2026-11-17 · Redis → RabbitMQ → MongoDB 순서의 **로컬 구성·기본 통신 확인용**이다. 클라우드에는 배포하지 않았다. EC2 IaC는 별도 `terraform/environments/prod/data`에 준비했다. 한 Docker Desktop 호스트의 컨테이너를 3개 AZ처럼 평가하지 않는다.

## 구성과 실제 확인

| 단계 | 구성 | 이번 로컬 관측 |
| --- | --- | --- |
| Redis | data 3 + Sentinel 3, 인증·AOF, quorum 2, replica 최소 1 | Redis 7.2.17, primary 1/replica 2, Sentinel CKQUORUM·동일 primary 발견, 임시 키 쓰기·조회·WAIT 응답 2 |
| RabbitMQ | 4.3 계열 3 broker, 고정 node identity·cookie·peer discovery | 4.3.7, 본 큐/wait.v2/DLQ 각각 quorum·3 online member, 별도 smoke queue의 AMQP confirm·수동 ACK |
| MongoDB | keyfile 인증 P-S-S, 앱·관리·monitor 계정 분리 | 7.0.48, 1 PRIMARY/2 SECONDARY, 앱 계정 majority+journal 쓰기·조회, messages unique index |
| 가시성 | Redis/Mongo 노드별 exporter, Rabbit native metrics, Prometheus/Grafana | 15 exporter target + Alloy heartbeat 1, 21-panel dashboard·세 서비스 Loki 로그·29 alert와 로컬 firing/resolved 확인 |

보고서는 [reports/](reports/)에 보관했다. 실패한 기동·probe를 고친 뒤 확인한 결과다. 장애 전환·분할·실제 알림/채팅 E2E·백업 복원·RTO/RPO·부하·AWS 검증 결과가 아니다. `WAIT`는 비동기 Redis를 강한 일관성으로 바꾸지 않는다.

후속 가시성 작업을 반영했다. 2026-11-17 당시 대시보드 실행·volume 보존을 확인했으며, 2026-11-20 브랜치 게시 시 실행 상태를 다시 조회하지 않았다. 로컬 credential은 공개 브랜치에 포함하지 않는다. [가시성 사용법·검증](../../monitoring/data-ha/README.md)을 먼저 확인한다.

## 실행

Windows Docker Desktop Linux engine, Docker Compose v2, 호스트 Python과 PyYAML 6.0.1이 필요하다. renderer 의존성은 `monitoring/data-ha/requirements.txt`에 고정했다. 데이터 노드는 공식 이미지, 검증 client는 별도 Python 이미지다. 앱 전체를 실행하지 않는다. 먼저 Docker Desktop을 켜고 이 폴더에서 진행한다.

```powershell
python lab.py init
python lab.py up redis
python lab.py up rabbitmq
python lab.py up mongodb
python lab.py observability
python lab.py status
python visibility.py --delivery-test
```

`up`은 해당 단계와 관측 서비스를 시작하고, 초기 토폴로지를 구성한 뒤 기본 통신을 확인한다. 순서대로 실행하면 앞 서비스는 유지된다. 전체 31개 service 중 lab-tools는 일회성이고 30개가 상주한다. 선택한 단계까지 기대 inventory를 누적하고 `.runtime/monitoring-stage.txt`에 마지막 단계를 보존한다. 클러스터 장애를 주입하지 않는다. healthcheck의 ping과 별도로 probe에서 멤버십·인증·쓰기 경로를 확인한다.

`lab.py`는 `desktop-linux` context가 로컬 named pipe인지 확인한다. 원격 Docker endpoint는 거부하며 다른 프로젝트의 컨테이너를 중지·삭제하지 않는다. 환경 변수를 영구 변경하거나 AWS API를 호출하지 않는다.

### 데이터와 credential

`init`이 `.runtime/.env`에 로컬 전용 credential을 생성한다. 기존 값은 보존하며 후속 관측 버전에 필요한 누락 설정만 추가한다. stdout·Git·납품 patch에 넣지 않는다. 이미 있으면 유지한다. `.runtime`을 지우고 기존 volume만 유지하면 credential/config 불일치가 생길 수 있으므로 함께 보존한다. password 회전은 별도 작업이며 자동 초기화·volume 삭제 명령은 제공하지 않는다.

Redis/Sentinel 설정과 DB 파일은 named volume에 남긴다. Redis 설정을 재시작마다 초기 primary로 덮어쓰지 않는다. Rabbit은 매 기동 `reset`하지 않는다. Mongo의 완성된 replica set은 새 primary를 강제하거나 재구성하지 않는다. 기존 주소가 다르면 중단해 검토를 요구한다.

```powershell
python lab.py verify redis
python lab.py verify rabbitmq
python lab.py verify mongodb
python lab.py stop all
```

`verify`도 로컬 통신 검증용 임시 데이터를 쓴다. Redis 키에는 TTL 60초, MQ에는 고유한 smoke queue, Mongo에는 별도 ha_smoke 문서를 사용한다. 앱 큐 메시지를 소비하지 않는다. MQ의 본 큐·대기 큐·DLQ 생성은 `up rabbitmq`의 구성 단계에서 한다. `stop all`은 이 프로젝트만 중지하며 volume·credential은 유지한다.

## 관측·접속

- Grafana dashboard: <http://127.0.0.1:13000/d/doktori-data-ha>, 사용자 `lab`, password는 `.runtime/.env`의 `GRAFANA_PASSWORD`.
- Prometheus: <http://127.0.0.1:19090>, Alertmanager: <http://127.0.0.1:19093>.
- Loki: <http://127.0.0.1:13100>, 로컬 webhook 기록: <http://127.0.0.1:18081/events>, Alloy: <http://127.0.0.1:12345>.
- Rabbit management: <http://127.0.0.1:15672>, 사용자·password는 `.runtime/.env`.
- data 포트는 호스트에 공개하지 않는다. 위 관리 포트도 loopback에만 bind한다.

진행 전 단계의 scrape target은 down일 수 있다. 모든 단계를 시작한 뒤 `observability`는 실제 서버 응답 지표·metrics endpoint·dashboard query·로그·rule health와 provisioning을 확인한다. `--delivery-test`는 유한 TTL 합성 경보를 로컬 수신기에만 보내 firing/resolved를 확인한다. 외부 사람에게 알림을 보내지 않는다. dashboard의 endpoint 상태는 quorum이나 사용자 수신 성공을 뜻하지 않는다. Sentinel 상태와 queue/replica set 멤버십은 stage 보고서를 함께 읽는다.

앱 client는 Compose network 안에서 `sentinel-a/b/c:26379`, `rabbitmq-a/b/c:5672`, `mongo-a/b/c:27017`를 사용한다. host 앱에 localhost seed만 주면 발견된 내부 DNS에 접근하지 못한다. Sentinel client는 master `doktori-master`와 Redis/Sentinel 각각의 인증, Mongo client는 `doktori-rs`와 multi-seed·authSource·write concern을 설정한다. 실제 Spring 앱은 실행하지 않았다.

## 재현·버전

[images.lock.json](images.lock.json)에 실제 pull한 registry digest·로컬 architecture·image ID를 기록했다. 새 `init`은 이 값을 사용한다. lock 이전에 만든 `.env`는 `lock-images`가 image 참조만 갱신하며 credential은 유지한다. 검증은 Docker Desktop x86_64에서 했고 EC2 ARM64 AMI 검증으로 대신하지 않는다.

도구 client는 redis-py 5.2.1, pika 1.3.2, PyMongo 4.10.1로 고정했다. Python base도 lock의 digest를 사용한다. Dockerfile/requirements 변경 시 도구 이미지를 다시 build한다. 결과 JSON은 topology와 버전·검사 범위를 기록하며 성능 비교 자료가 아니다.

BuildKit snapshot 누락 오류가 한 번 발생해 해당 Python base를 다시 pull하고 **도구 이미지만** `build --no-cache`로 복구했다. 전역 image/cache prune은 하지 않았다. 서비스 이름 변경·기존 volume 재사용·credential 회전·버전 업그레이드는 단순 재실행과 분리해 검토한다.

## 소스와 적용 지침

구현은 `deliver-task`, 이 문서와 검증 범위 정리는 `technical-writer`를 적용했다. 학습자의 설계 선택·독립 구현·장애 실험 성과로 분류하지 않는다.

- [Redis Sentinel 공식 문서](https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/): quorum·인증·설정 파일 쓰기·Docker 주소 발견.
- [RabbitMQ cluster formation](https://www.rabbitmq.com/docs/cluster-formation): peer discovery·node identity. 실제 선택 버전은 보고서의 4.3.7이다.
- [MongoDB 7.0 내부 인증 replica set](https://www.mongodb.com/docs/v7.0/tutorial/deploy-replica-set-with-keyfile-access-control/): localhost bootstrap·내부/앱 인증·DNS. keyfile은 이번 개발용 구성이고 운영 인증·TLS 설계는 별도다.
- [EC2 IaC 준비·검증 범위](../../docs/design/data-ha-configuration-2026-11-17.md).

가시성 collector는 별도 monitor identity를 사용한다. 로컬 MQ 계정은 큐 설정·발행·가져오기 거부를 자기 임시 큐로 확인했고 큐를 정리했다. Alloy는 이 project의 데이터 로그만 고르지만 Docker socket의 `:ro` mount가 API 권한 자체를 제한하는 것은 아니다. EC2용 구성은 해당 unit의 journal을 읽는다. 운영 대응은 [runbook](../../runbooks/alerting/data-ha.md)을 따른다.
