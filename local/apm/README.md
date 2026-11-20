# 독토리 API APM 로컬 검증

2026-11-18 · delivery · AI 작성 및 실행 검증. 사용자 선택: Java Agent → Alloy → Tempo → Grafana, API 대표 요청 1개, 로컬 검증과 IaC·설계 문서.

## 2026-11-20 자원 점검

개인 AWS 계정의 활성 17개 리전에서 EC2(종료 제외), EBS 볼륨, NAT Gateway, EIP, ALB/NLB, RDS 인스턴스, ECS/EKS 클러스터가 모두 0개임을 읽기 전용 조회로 확인했다. 서울의 Packer 임시 보안 그룹·키와 ENI도 0개다. 이전에 요청해 만든 HA AMI 3개와 연결된 스냅샷 3개는 보관했다. 스냅샷 저장 비용은 남으며, 이 결과는 계정의 모든 AWS 서비스 비용이 0이라는 뜻이 아니다. APM 로컬 컨테이너도 현재 실행 중인 것이 없다.

아래 실행 증거는 2026-11-18 검증 당시 결과이며 오늘 다시 서비스 부하를 실행한 결과가 아니다.

## 무엇을 실행했는가

`GET /api/policies/reading-genres`는 실제 `PolicyController.getReadingGenres` → `PolicyService.getReadingGenrePolicies` → `ReadingGenreRepository.findAllByDeletedAtIsNullOrderByPriorityAsc` → MySQL SELECT 경로다. 백엔드 `apm-lab/build.gradle`이 이 기존 소스와 필요한 엔티티를 직접 컴파일한다. 응답 대역이나 repository mock을 사용하지 않는다.

별도 실행 파일은 전체 API의 보안 필터·스케줄러·Firebase·S3·MQ 초기화를 포함하지 않는다. 기존 공개 GET 경로와 health만 접근하도록 제한했다. 이는 해당 경로의 계측 검증이며, 운영 API 전체 기동·인증·외부 연동 검증은 아니다. 원래 API/Chat bootJar 구성은 변경하지 않았다.

테스트 DB에는 장르 3건을 넣는다. priority=1,2인 두 정상 행만 순서대로 반환하고 삭제된 행은 제외해야 한다. `ddl-auto=create`는 전용 `apmpilot` DB를 기동마다 다시 만든다. 업무 DB 주소를 받는 옵션은 없다.

## 실행

Windows PowerShell, Docker Desktop Linux, Python 3.10+, Java 21, Gradle 8.14.3. 백엔드와 클라우드 저장소를 같은 부모 폴더에 둔다. 아래 명령은 클라우드 저장소 루트에서 실행한다.

```powershell
# JAVA_HOME을 로컬 JDK 21 경로로 지정한다.
Push-Location ../doktori-backend
./gradlew.bat -p apm-lab bootJar --no-daemon
Pop-Location
python local/apm/run.py init
python local/apm/run.py up
python local/apm/run.py check
```

`init`은 공식 GitHub의 Java Agent 2.23.0을 내려받고 `agent.lock.json`의 SHA256과 대조한다. 초기 hash는 공식 HTTPS 다운로드에서 기록했으며 독립적인 서명 검증은 수행하지 않았다. 재실행해도 `.runtime/.env`의 비밀번호는 유지한다. 검증한 컨테이너 이미지는 Compose에 digest로 고정했고 원래 태그·digest·아키텍처는 `images.lock.json`에 보관한다.

API 실행 파일은 Spring Boot 3.5.9 / Java 21.0.5, 검증 DB는 MySQL 8.4.11이다. 수집기는 Alloy 1.15.0, 저장소는 Tempo 2.9.0 / Loki 3.6.5, 화면은 Grafana 12.2.0이다. 이 버전은 이번 실험의 고정값이며 최신 버전 추천을 뜻하지 않는다.

- Grafana: http://127.0.0.1:13001 · 사용자 `lab`, 비밀번호 `.runtime/.env`의 `GRAFANA_PASSWORD`
- API: http://127.0.0.1:18090/api/policies/reading-genres
- Tempo 조회: http://127.0.0.1:13200 · Loki 조회: http://127.0.0.1:13101
- Grafana Explore에서 `APM Tempo`를 선택하고 `reports/verification.json`의 trace ID를 검색한다. `reports/ui.json`에도 검증 화면 URL이 있다.

```powershell
python local/apm/run.py status
python local/apm/run.py stop
```

`stop`은 이 Compose 프로젝트만 중지하며 볼륨을 삭제하지 않는다. Tempo는 tmpfs라 컨테이너 정지·재생성 뒤 trace 보존을 보장하지 않는다. Loki/Grafana는 컨테이너 쓰기 계층이며 재생성 시 사라진다. 재시작 후 `check`로 새로운 trace를 생성한다. MySQL·API 로그는 프로젝트 전용 볼륨이다. 장기간 보존 구성이 아니다.

## 수집 설계와 식별자

| 신호 | 경로 | 확인한 범위 |
| --- | --- | --- |
| trace | Java Agent → OTLP HTTP Alloy:4318 → batch → OTLP gRPC Tempo:4317 | 실제 HTTP·JPA·JDBC span 5개 |
| 로그 | API 파일 `/logs/api.log` → Alloy file tail → Loki | 같은 `trace_id`의 `request_complete status=200` |
| 조회 | Grafana Tempo/Loki 데이터소스 | 양쪽 실제 proxy query와 trace waterfall 화면 |

기존 HTTP 필터는 `X-Trace-Id`와 MDC `traceId`를 사용한다. pilot의 로그에는 이를 `request_id`로 표시하고, Java Agent가 주입하는 `trace_id`·`span_id`를 별도 표시한다. 독립적으로 만든 16자리 요청 ID를 분산 trace ID로 오인하지 않는다. 기존 헤더 계약은 보존했다. W3C `traceparent`로 지정한 32자리 trace ID와 부모 span ID가 HTTP span까지 유지됨을 검증했다.

Loki derived field는 `trace_id=([0-9a-f]{32})`를 추출해 Tempo로 연결한다. Tempo→Loki는 `service.name`을 Loki의 `service_name`으로 매핑하고 trace ID로 필터링한다. trace ID는 Loki 스트림 label로 승격하지 않는다. 파일 수집 한 경로를 쓰므로 Agent 로그 exporter는 `none`, 기존 메트릭 수집과 중복되지 않게 Agent metrics exporter도 `none`이다.

로컬에서는 짧은 검증 요청을 모두 볼 수 있게 `always_on`을 사용한다. 운영 준비 모듈은 부모 기반 10%를 시작값으로 제공한다. 이는 사용자 SLO·운영 비용 산정값이 아니다. sampling에서 제외된 요청의 trace가 저장된다고 보장하지 않는다. 전체 오류율·p95 같은 운영 집계는 기존 비샘플링 HTTP 메트릭을 기준으로 잡는다. 이번 단계에는 RED 대시보드·service graph·profiling을 추가하지 않았다.

## 네트워크·수집 내용

API·DB·Alloy·Tempo·Loki·Grafana는 Docker internal 네트워크에 있고, 별도 Nginx 게이트웨이만 호스트 loopback 포트를 게시한다. DB와 OTLP 수집 포트는 호스트에 공개하지 않는다. Docker socket을 마운트하지 않는다. 런타임 외부 제공자나 AWS 호출이 없다. 이미지·Agent·빌드 의존성 다운로드는 준비 단계의 외부 통신이다.

요청 완료 로그에는 메서드·고정 경로·상태만 남긴다. 본문·Authorization 헤더 수집은 설정하지 않았다. JDBC statement sanitizer를 켰다. 합성 fixture로 검증했으며 임의 개인정보의 모든 유출 경로를 검증한 것은 아니다. 신규 업무 계측 전 attribute와 예외 메시지를 별도 검토한다.

## IaC와 운영 편입

`terraform/modules/apm-runtime`은 기본 `enabled=false`인 provider-free 구성 생성 모듈이다. 환경 변수, JVM에 **추가할** javaagent 인자, hash 검증 후 atomic 교체하는 설치 스크립트를 출력한다. 기존 JAVA_TOOL_OPTIONS를 덮어쓰지 않도록 인자를 별도 출력한다. `terraform/environments/local/apm`은 적용 예다. 실제 EC2 생성·IAM·SG·SSM·systemd 변경은 하지 않는다.

```powershell
terraform -chdir=terraform/modules/apm-runtime init -backend=false
terraform -chdir=terraform/modules/apm-runtime test
terraform -chdir=terraform/environments/local/apm init -backend=false
terraform -chdir=terraform/environments/local/apm validate
python local/apm/render_iac.py --terraform C:/path/to/terraform.exe
```

마지막 명령은 `terraform console`만 사용해 `.runtime/native/api.env`, `java-argument.txt`, `install-agent.sh`를 생성한다. 모듈의 기본 staging/부모기반 10% 설정으로 api.env를 만들며 설치 스크립트는 같은 고정 Agent를 사용한다. 파일 생성이 배포를 뜻하지 않는다. future EC2 실행기에 설치 스크립트 → 환경 파일 → JVM 인자 추가 → 기존 로그 패턴에 trace_id/span_id 추가 → 서비스 재기동을 연결해야 한다. 수집기 주소·TLS·인증·방화벽과 Tempo 영구 저장소는 그 배치 환경에 맞춰 확정해야 한다. collector/Tempo의 검증된 기본 설정은 이 폴더에 있다.

실행 파일에서 Agent 인자를 제거하고 기존 환경으로 재기동하면 계측을 해제할 수 있다. 모듈 `enabled=false`는 생성값을 비울 뿐 이미 배포된 프로세스를 자동 원복하지 않는다. 로컬 장애 시 `run.py stop`을 사용한다.

## 검증 결과와 한계

`reports/verification.json`은 응답 내용·삭제 필터·정렬, W3C 부모 전파, HTTP server span 1개, 실제 MySQL span 1개, DB→HTTP 조상 관계, 같은 ID 로그, Grafana를 경유한 trace·로그 조회를 검사한다. `reports/trace.json`은 해당 합성 요청의 trace 원문이다. `reports/trace.png`는 실제 Grafana 화면을 확인한 증거다. 표시된 지연은 한 요청의 관측값이며 부하 성능이나 SLO로 일반화하지 않는다.

Terraform 1.14.8에서 비활성·활성·샘플링 범위 오류·인증정보 포함 endpoint 거부 4개 plan 테스트 통과. 클라우드 provider와 자원은 없다. 모듈·사용 예 validate 및 생성 설치 스크립트 Bash 구문 검사도 수행한다.

미실행: 전체 API 컨텍스트, JWT 인증, MQ/Redis/Mongo·AI·@Async 경계, 실패/재시도 추적, Agent 중단·백엔드 수집 장애·overhead 부하 비교, EC2/ARM64·TLS, 운영 배포와 클라우드 자원 변경. 다음 단계는 전체 API 로컬 프로필에서 같은 경로를 재검증한 뒤 MQ 발행→소비 구간을 추가하는 것이다.

## 문제 해결

- API 접속 거부: `run.py status`에서 gateway와 API 상태를 확인한다. internal 네트워크에 직접 ports만 설정하면 현재 Docker Desktop에서 게시되지 않아 gateway를 사용했다.
- trace는 있는데 로그가 없음: Alloy의 file tail 상태·`/logs/api.log` 파일과 Loki 수집 지연을 확인한다. 검증기는 최대 50초 기다린다.
- Tempo datasource health API 404: 이 플러그인의 health 메서드가 구현되지 않아 실제 Grafana proxy trace 조회로 검증한다. 이를 수집 장애로 오인하지 않는다.
- agent SHA256 불일치: 실행을 중단하고 공식 릴리스와 lock을 대조한다. 자동으로 새 hash를 승인하지 않는다.

## 적용한 스킬

| 스킬 | 적용 구간 | 검토 결과·한계 |
| --- | --- | --- |
| deliver-task | 기존 호출 경로 확인, 격리 실행 파일·Compose·IaC, 로컬 검증 | 실제 코드 경로와 trace 증거 확보. 전체 API 완료로 확장하지 않음 |
| technical-writer | 실행 안내, 설계 결정, 신호·ID 계약, IaC 인계·미검증 범위 | 명령 실행 결과에 맞춰 작성. 별도 그림이 필요 없어 mermaid-diagrams 미적용 |
| token-usage-log | 작업 전후 본 세션 사용량 기록 | 초기 지침·파일 확인 이후부터 측정. 기술 검증 근거로 사용하지 않음 |

AI가 작성·수정·실행한 결과이며 사용자의 직접 구현·학습 평가 결과로 기록하지 않는다. 별도 agent나 독립 검토자는 참여하지 않았다. 장문 조사·문체 전면 교정이 아니므로 content-research-writer와 humanizer는 적용하지 않았다.

## 공식 근거

- [Java Agent 2.23.0 릴리스](https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/tag/v2.23.0): 고정 바이너리 출처.
- [Java Agent 지원 라이브러리](https://opentelemetry.io/docs/zero-code/java/agent/supported-libraries/): 자동 계측 범위. 이번 조합의 실행 결과는 reports로 별도 확인.
- [Logback MDC 계측](https://github.com/open-telemetry/opentelemetry-java-instrumentation/blob/v2.23.0/docs/logger-mdc-instrumentation.md): trace_id/span_id 로그 상관관계.
- [Alloy→Tempo](https://grafana.com/docs/tempo/latest/set-up-for-tracing/instrument-send/set-up-collector/grafana-alloy/): OTLP receiver·batch·exporter 구성.
- [Tempo 로컬 배치](https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/deploy/locally/): 단일 인스턴스 개발·평가 범위. 공식 latest 문서는 변경 가능하며 실제 사용 버전은 lock에 고정했다.
