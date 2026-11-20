# 데이터 HA 경보 대응

현재 조건은 3노드 구성의 AI 초안이며 사용자 SLO가 아니다. 이 runbook은 읽기 전용 확인 순서를 정한다. 자동 failover·강제 선출·reset·queue 삭제·메시지 소비·복원은 실행하지 않는다.

## 첫 확인

Grafana의 env/cluster와 선택한 단계를 확인하고 준비된 대상 수와 기대 수를 비교한다. Prometheus `/api/v1/rules`에서 rule health도 확인한다. 같은 node의 지표와 Loki 로그를 동일 시간 범위로 맞춘다. 최근 bootstrap·credential·권한·DNS/SG·버전 변경과 함께 관측/추론/미확인을 기록한다.

| 경보 | 기본 조건 | 첫 확인 |
| --- | --- | --- |
| TelemetryMissing | 기대 up 없음 또는 60초 초과, 추가 for 1m | agent·remote_write·receiver·주소·inventory |
| ScrapeFailed | endpoint up=0, 1m | exporter process/HTTP와 실제 DB 상태를 구분 |
| SourceFailed | endpoint와 별도로 DB/API health=0, 1m | auth·role·연결·관리 API 응답 |
| Essential/StateMetricsMissing | HTTP 응답은 있지만 필수 지표 없음, 1m | collector flag·버전·권한·job/node 라벨 |
| RuleEvaluationFailure | 평가 실패 증가, 1m | rule API 오류·중복 series/vector match |
| Log/MetricDeliveryErrors | log retry/drop 또는 remote_write 실패 증가, 2m | Alloy와 receiver 로그·queue·HTTP 오류 |

로컬은 `python local/data-ha/lab.py status`, `python local/data-ha/lab.py observability`로 확인한다. `observability`는 DB/큐 메시지를 쓰지 않는다. 기존 `lab.py verify`는 readiness용 임시 데이터를 쓰므로 구분한다.

EC2가 나중에 실행됐을 때의 읽기 전용 예:

```bash
systemctl status alloy doktori-quorum-exporter --no-pager
journalctl -u alloy --since '10 minutes ago' --output=short-iso --no-pager
journalctl -u redis-server -u redis-sentinel --since '10 minutes ago' --output=short-iso --no-pager
journalctl -u rabbitmq-server --since '10 minutes ago' --output=short-iso --no-pager
journalctl -u mongod --since '10 minutes ago' --output=short-iso --no-pager
```

없는 unit은 제외한다. Alloy journal 그룹이 없으면 component가 시작돼도 로그가 없을 수 있다. credential config·cookie·password URI를 incident 문서에 붙이지 않는다.

## Redis

실제 INFO primary 수 !=1은 1m critical이다. `bootstrap_role`은 현재 선출 역할이 아니다. Sentinel별 주소·CKQUORUM·auth·peer 통신·TILT와 실제 INFO 역할을 대조한다. primary 주소 불일치와 CKQUORUM 실패도 1m critical이다.

연결 replica <2는 2m warning, <1은 1m critical이다. 현재 min-replicas-to-write=1이라 쓰기 거부 가능성을 함께 본다. ACK lag >5초가 2m이면 warning이고 AOF write 오류도 별도 경보다. CKQUORUM·AOF·WAIT 정상만으로 무유실/RPO를 판정하지 않는다.

## RabbitMQ

configured members로 실제 과반을 계산한다. 현재 목표는 3, 과반은 2다. 온라인 수 <요구 과반은 1m critical, <3은 2m warning이다. 5멤버 등으로 바꾸면 warning 목표도 바꾼다. API 세 관측을 합산하지 않고 최소를 사용하므로 일부 API의 낮은 관측만으로도 경보를 낸다. broker별 관측·partition·leader를 대조하며 확정적인 split-brain이라고 단정하지 않는다.

missing queue·classic type·온라인 leader 부재는 1m critical이다. 이름·vhost·선언 시점·버전을 먼저 확인하고 기존 큐를 삭제/재선언하지 않는다. 본 delivery 큐의 backlog>0과 consumers=0이 2m이면 warning이다. wait/DLQ consumer 0은 정상일 수 있어 동일 조건을 적용하지 않는다. DLQ ready>0이 2m이면 이유·TTL/DLX·재시도를 확인하고 임의 소비·purge·재발행하지 않는다.

memory/disk alarm은 publisher가 막힐 수 있다는 신호다. backlog·unacked와 앱 confirm/ACK 증거를 함께 본다. 이번에는 업무 전달 SLI·outbox·최종 수신을 계측하지 않았다.

## MongoDB

exporter별 `mongodb_rs_myState`를 센다. 각 exporter의 전체 set 멤버 목록을 합산하면 같은 멤버가 중복된다. primary 수 !=1은 1m critical, P/S data member <3은 2m warning, <2는 1m critical이다. 현재 3 voting data-bearing P-S-S 전용이며 arbiter/hidden/비투표 구성에는 재검토한다.

self lag >5초가 2m 지속되면 warning이다. Percona 0.44 호환 지표는 primary와 멤버의 optime 시각 차이(초)의 절댓값이다. heartbeat 관측·noop 주기의 단기 변동이 있고 업무 RPO/사용자 지연과 같지 않다. 실제 로컬에서도 0/10초 등의 단기 변동을 관측했다.

auth 실패는 최소 권한·사용자 replication·SSM 값·direct connection을 확인한다. root/admin으로 exporter를 돌려 해결하지 않는다. primary 강제·reconfig·resync·복원은 별도 계획과 증거가 필요하다.

## 전송과 인계

로컬 `visibility.py --delivery-test`는 유한 TTL 합성 경보의 firing/resolved를 자기 webhook에서 확인한다. 실제 DB 장애 탐지 검증은 아니다. native receiver는 외부 목적지 없이 준비했다. 실제 수신자·채널·중복/억제·silence 만료·책임자를 정하고 별도 검증한다.

Prometheus/Grafana/Loki/Alertmanager 전체 호스트나 경보 채널의 장애는 독립 감시가 필요하다. 관측 스택 자체의 HA는 이번에 구축하지 않았다.

```powershell
python local/data-ha/lab.py stop all
```

이 프로젝트만 중지하고 volume·credential을 남긴다. incident 인계에는 시간·env/cluster/node·수집 상태·raw/recording 값·로그·최근 변경·확인한 실패 경계와 미확인을 남긴다.
