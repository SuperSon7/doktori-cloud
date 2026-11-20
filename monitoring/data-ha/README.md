# 독토리 데이터 HA 가시성

2026-11-17 · Redis → RabbitMQ → MongoDB의 수집 상태·복제·quorum·서비스 로그·경보를 구성했다. 로컬 Docker Desktop에서 동작을 확인했다. 이번 작업에서는 AWS API·배포·Terraform 실제 plan/apply·AMI 재빌드·외부 알림 전송을 실행하지 않았다.

## 볼 수 있는 것

| 대상 | 수집·판단 | 해석의 한계 |
| --- | --- | --- |
| 수집 경로 | 기대 target inventory와 60초 이내 up, exporter의 DB/API 성공, Alloy 전송 오류 | 전체 Prometheus/Grafana가 꺼지면 자체 경보도 멈춘다. 독립 감시자는 별도 |
| Redis | 실제 INFO 역할·primary 수·연결 replica·ACK 지연·AOF 오류, Sentinel별 CKQUORUM·primary 주소 | CKQUORUM 성공이나 WAIT는 데이터 무유실/RPO 증거가 아님 |
| MQ | broker scrape·메모리/디스크 alarm, 큐별 configured/online/required majority·leader·type, backlog·unacked·consumers·DLQ | 관리 API 관측이며 publisher confirm·업무 인계·최종 수신 증거가 아님 |
| MongoDB | exporter별 myState·primary/data member 수·self-member replication lag·연결 수 | 현재 3 voting data-bearing P-S-S 전용. client retry/commit·복원·RPO 증거가 아님 |
| 로그 | 같은 env/cluster/service/node로 Loki 조회 | DB/브로커 원본 운영 로그다. 앱 trace·요청 correlation·업무 SLI는 추가하지 않음 |

[대시보드](generated/dashboard.json)는 21개 panel, [규칙](generated/rules.yml)은 29개 alert와 11개 recording rule이다. 추가 inventory rule은 배포 단계에 따라 달라진다. 로그·연결 수 같은 raw panel과 상태 recording을 구분한다. No data를 임의의 건강한 0으로 채우지 않는다. 경보 발생 이력의 빈 결과는 현재 firing이 없는 경우도 있으므로 수집 상태·rule health와 함께 본다.

## 로컬에서 보기

[로컬 사용법](../../local/data-ha/README.md)에 따라 Redis → MQ → Mongo를 실행한다. 아래 화면과 수집 결과는 2026-11-17 당시 실행 기록이며, 2026-11-20 브랜치 게시 시 서비스 실행 상태를 다시 조회하지 않았다.

- Grafana: <http://127.0.0.1:13000/d/doktori-data-ha> — 사용자 `lab`, password는 `local/data-ha/.runtime/.env`의 `GRAFANA_PASSWORD`.
- Prometheus: <http://127.0.0.1:19090>, Alertmanager: <http://127.0.0.1:19093>.
- Loki: <http://127.0.0.1:13100>, 로컬 알림 증거: <http://127.0.0.1:18081/events>.

```powershell
# cloud repo root
python local/data-ha/lab.py observability
python local/data-ha/visibility.py --delivery-test
```

첫 명령은 실제 지표·rule health·firing 상태·세 서비스 로그·Grafana provisioning을 확인한다. 두 번째는 유한 TTL의 합성 경보를 로컬 Alertmanager에 넣고 firing/resolved webhook을 확인한다. DB 장애를 주입하거나 사람에게 알림을 보내지 않는다. 수신 기록은 로컬 메모리에 최대 100개만 남는다.

관측 프로세스도 포함해 로컬 상주 컨테이너는 30개다. 기대 exporter target 15개와 Alloy heartbeat 1개를 본다. Prometheus 자기 scrape는 별도이고 push target은 `/targets` 목록에 나타나지 않는다. 로컬 Alloy는 Docker socket으로 이 Compose project의 데이터 서비스 로그만 읽는다. socket의 `:ro` mount는 Docker API 권한 자체를 읽기 전용으로 바꾸지 않는다. 이 local collector는 신뢰한 Docker Desktop에서만 사용하고, EC2에는 Docker socket 대신 service journal 구성을 준비했다.

## EC2용 IaC와 관측 서버 준비

`enable_data_ha_observability`는 기본 false다. 켜더라도 실제 HA를 선택한 서비스에만 monitor secret·Sentinel/quorum 수집·journal 수집을 준비한다. 기존 AMI의 Python 3·Alloy 1.15.0을 사용하며 새 package나 AMI를 요구하지 않는다.

1. [단계별 입력](../../terraform/environments/prod/data/stages/) 또는 실제 AMI 입력을 검토한다. 후속 변경으로 실제 AMI 입력에도 이 flag를 추가했다. **이번에는 apply하지 않았다.** bootstrap 변경은 기존 EC2의 stop/start에 영향을 줄 수 있다.
2. Terraform의 `data_ha_observability_inventory` output은 실제로 선택한 HA 노드에서 만든 비밀 없는 renderer 입력이다. 현재 state를 조회하지 않았다. 나중에 권한이 정해진 환경에서 output을 내보내거나 준비 단계에서는 [example](inventory.example.json)을 사용한다.
3. 렌더 후 기존 monitoring compose에 opt-in override를 추가한다. 전체 3서비스 예시는 exporter 15개 + 노드별 Alloy 9개, 총 24 target이다. 기본 example은 실제 배포 상태가 아니다.

```powershell
python -m pip install -r monitoring/data-ha/requirements.txt
python monitoring/data-ha/build_assets.py `
  --inventory monitoring/data-ha/inventory.example.json `
  --output monitoring/data-ha/generated --native
# 아래는 향후 승인된 모니터링 서버에서만 실행한다. 이번에는 실행하지 않았다.
docker compose -f monitoring/docker-compose.yml `
  -f monitoring/data-ha/compose.override.yml --profile data-ha up -d
```

override는 기존 dashboard/rule 파일을 지우지 않고 HA 설정·dashboard·Alertmanager를 추가한다. Native [receiver](alertmanager.yml)는 외부 destination이 없는 상태다. 실제 연락 대상·secret·전송 정책을 확정하고 별도 검증해야 한다. 기존 Grafana 경보와 이 Prometheus 경보를 동시에 운영할 때 중복 경보·silence 범위를 검토한다.

네트워크는 기존 private monitoring DNS의 Prometheus remote-write와 Loki push를 기본값으로 사용한다. `data_ha_remote_write_url`, `data_ha_loki_push_url`로 바꿀 수 있다. DNS·SG·TLS·endpoint availability는 EC2에서 미검증이다. Alloy는 서비스 journal만 읽도록 제한하고 `adm,systemd-journal` 읽기 그룹을 부여한다. native journal의 실제 수집·전송은 아직 실행하지 않았다.

## 계정·라벨·크기

- MQ의 `doktori_ha_monitor`는 `monitoring` tag와 빈 AMQP configure/write/read 정규식만 가진다. 로컬 동등 계정으로 상태 GET을 확인했다. collector는 정한 큐 세 개에 GET만 하며 메시지를 소비하거나 큐를 생성하지 않는다.
- Mongo monitor는 `clusterMonitor@admin`과 `read@local`을 사용한다. 관측 활성화 시 admin credential로 exporter를 실행하지 않는다. 기존 monitor 역할이 다르면 자동 확대·수정하지 않고 bootstrap을 중단한다. 실제 SSM/계정 provisioning은 미실행이다.
- 추가 secret은 SSM SecureString write-only 값으로 준비했다. 로그·report·patch에 넣지 않는다. credential 회전은 별도 버전/사용자 변경 절차다.
- `env,cluster,service,job,node`를 수집 경로의 식별자로 쓴다. Redis 초기 역할은 `bootstrap_role`, 실제 INFO `role`은 보존한다. 내장 exporter의 기본 `integrations/*` job은 target relabel로 명시한 job으로 바꾼다.
- Mongo 전체 멤버 보고를 합산하지 않고 exporter별 `mongodb_rs_myState`를 센다. MQ API 세 관측도 합산하지 않고 온라인 멤버의 보수적 최소를 사용한다. 상이한 관측은 실패 징후이며 확정적인 네트워크 분할 증명이 아니다.
- 원격 전송 단절로 up 시계열이 사라져도 별도 inventory가 남아 경보를 낸다. 유효한 inventory가 없는 서비스에는 HA 경보를 켜지 않는다.
- 커진 cloud-init은 gzip wrapper로 전달한다. Terraform의 실제 `base64gzip` 결과를 풀어 원문 일치·LF·16KiB 제한을 검사했다. generic compute 모듈은 변경하지 않았다.

## 검증과 운영

[verification.json](verification.json)에 실행 검사·미실행 범위를 기록한다. [운영 순서와 임계값](../../runbooks/alerting/data-ha.md), [실제 화면](evidence/overview.png), [로그 화면](evidence/logs.png)을 함께 본다.

실제 수행: 로컬 지표·로그·Grafana, 합성 경보 firing/resolved, 18개 promtool 시나리오, collector unit 7개, provider 없는 inventory/secret 선택 5개, 11개 bootstrap/Alloy/gzip 구문·제한, native exporter 설정의 로컬 연결 2종. 실제 failover·AZ·부하·복원·EC2 bootstrap·외부 수신자 전송은 하지 않았다.

작업 중 native 초기 role 덮어쓰기, 내장 exporter의 job 우선순위, 라벨 이전 중 잔존 시계열의 vector match 충돌을 수정했다. 초기 실패 경보도 로컬 수신기에 관측됐으며 최종 검사는 오류 0·firing 0을 확인했다. 해제 확인은 중단 시에도 사라지는 유한 TTL 합성 경보로 검증한다.

## 적용한 스킬

| 스킬 | 실제 사용 구간 | 검토 결과 |
| --- | --- | --- |
| deliver-task | 수집기·라벨·경보·대시보드·로컬/EC2 설정과 검사 | 위 실행 검사 통과. 클라우드 동작은 미검증 |
| technical-writer | 실행 방법·계정/데이터 경계·운영 순서·검증 구분 | 문서 링크와 화면을 확인하고 관측과 미확인을 분리 |

AI가 구현·검사한 산출물이며 사용자의 독립 구현·장애 분석 성과로 평가하지 않는다.

공식 근거: [Alloy 1.15 Redis 설정](https://github.com/grafana/alloy/blob/v1.15.0/docs/sources/reference/components/prometheus/prometheus.exporter.redis.md), [Alloy 1.15 Mongo 설정](https://github.com/grafana/alloy/blob/v1.15.0/docs/sources/reference/components/prometheus/prometheus.exporter.mongodb.md), [Sentinel exporter 1.67 구현](https://github.com/oliver006/redis_exporter/blob/v1.67.0/exporter/sentinels.go), [Mongo 0.44 lag 계산](https://github.com/percona/mongodb_exporter/blob/v0.44.0/exporter/v1_compatibility.go), [RabbitMQ 4.3 metrics](https://www.rabbitmq.com/docs/4.3/prometheus), [Alloy journal 권한·필터](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.journal/).
