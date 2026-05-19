# Install Script Agent Checklist

이 문서는 Packer setup script, EC2 bootstrap script, AMI bake 스크립트처럼
외부 패키지 저장소와 OS 패키지 매니저를 다루는 작업을 에이전트가 수행할 때
반드시 따라야 하는 사전 점검 체크리스트다.

목표는 세 가지다.

- 공식 문서와 실제 배포판/아키텍처 지원 범위를 먼저 확정한다.
- "대충 되는 것처럼 보이는" 저장소 URL, 패키지명, 버전 문자열 추측을 금지한다.
- 빌드 실패를 조용히 우회하지 않고, 원인이 드러나는 방식으로 실패하게 만든다.

## 1. 작업 시작 전 필수 확인

- 대상 OS 배포판과 codename을 확인한다.
  - 예: Ubuntu 22.04 `jammy`
- CPU 아키텍처를 확인한다.
  - 예: `arm64`, `amd64`
- 설치 대상 컴포넌트의 정확한 요구 버전을 확인한다.
  - 예: `RabbitMQ 3.13`, `Erlang 26`, `Redis 7.2`
- "이 버전 + 이 배포판 + 이 아키텍처" 조합이 공식적으로 지원되는지 먼저 확인한다.

## 2. 반드시 공식 문서부터 확인

- 설치 방법은 반드시 1차 소스에서 확인한다.
  - 공식 product docs
  - 공식 apt/yum repo docs
  - 공식 release page
- 블로그, Stack Overflow, 오래된 gist를 설치 기준으로 삼지 않는다.
- 예전 기억으로 `packagecloud`, PPA, mirror URL을 재사용하지 않는다.

## 3. 저장소/패키지 경로 확인 규칙

- apt repository URL은 실제 배포판 codename에서 Release 파일이 존재하는지 확인한다.
- 아키텍처별로 저장소가 갈리면 문서의 권장 경로를 따른다.
  - 예: arm64만 Launchpad PPA, 나머지는 vendor apt repo
- GPG key URL 또는 fingerprint도 공식 문서 기준으로 확인한다.
- 패키지명이 문서와 실제 repo에서 같은지 확인한다.
  - 예: `redis` vs `redis-server`

## 4. 버전 핀ning 규칙

- "요청 버전이 없으면 latest 설치"를 금지한다.
- repo의 실제 버전 문자열 형식을 먼저 확인한다.
  - apt epoch (`6:`), distro suffix (`~jammy1`)가 붙을 수 있다.
- 한 패키지만 핀하지 말고, 같은 릴리스 세트로 움직이는 의존 패키지는 함께 맞춘다.
  - 예: `redis`, `redis-server`, `redis-tools`, `redis-sentinel`
- 패키지명/버전 매칭 실패 시:
  - available version 목록을 로그로 출력
  - 즉시 실패

## 5. 설치 스크립트 작성 규칙

- 첫 단계에 base repo/universe/requisite package 준비를 명시한다.
- 저장소 추가 후에는 반드시 `apt-get update`를 다시 실행한다.
- 외부 tarball 다운로드 시:
  - checksum 검증
  - 검증 대상 파일 경로와 현재 작업 디렉터리를 명확히 맞춘다
- 서비스는 bake 검증 목적으로 시작할 수 있지만,
  - 런타임 상태 파일
  - 클러스터 상태
  - 비밀값/토큰/쿠키
  - 데이터 디렉터리 잔재
  는 AMI에 남기지 않는다.

## 6. 실패 처리 원칙

- 문서 미확인 상태에서 repo URL을 추측하지 않는다.
- version mismatch를 무시하지 않는다.
- dependency conflict를 `--fix-broken`으로 덮지 않는다.
- 실패 시 로그에 최소한 아래 중 하나는 남긴다.
  - 어떤 저장소를 조회했는지
  - 어떤 버전을 찾았는지 / 못 찾았는지
  - 어떤 패키지 세트 설치가 실패했는지

## 7. 검증 순서

스크립트 수정 후 최소 검증 순서는 아래와 같다.

1. `bash -n packer/scripts/<name>.sh`
2. `packer validate packer`
3. 대상 하나만 단일 빌드
4. 성공 시 manifest 확인
5. `./scripts/ami/update-ami-ids.sh --dry-run`
6. Terraform 변수 반영 후 관련 env validate/plan 확인

## 8. 단일 빌드 원칙

새 저장소나 새 설치 스크립트는 처음부터 병렬 전체 빌드하지 않는다.

- 먼저 `-parallel-builds=1`
- 먼저 `-only=amazon-ebs.<target>`

병렬 빌드는 원인 로그가 섞이므로, 최초 bring-up 단계에서는 금지에 가깝게 다룬다.

## 9. Terraform 연계 확인

AMI를 새로 만들었다고 끝이 아니다. 아래를 반드시 확인한다.

- manifest가 생성됐는가
- `update-ami-ids.sh`가 해당 manifest를 읽는가
- prod 변수 default가 최신 AMI ID로 반영됐는가
- prod 레이어가 raw Ubuntu fallback 없이 해당 AMI를 강제하는가
- app/data 레이어가 실제로 그 변수를 인스턴스/ASG/Launch Template에 연결하는가

## 10. 이번 이슈에서 얻은 교훈

- RabbitMQ:
  - 예전 `packagecloud` 경로를 기억으로 재사용하면 안 된다.
  - arm64, Ubuntu jammy, Erlang 26은 공식 문서 기준으로 경로가 갈린다.
- Redis:
  - `redis-server` 하나만 핀하면 안 되고, 관련 패키지 세트를 같이 맞춰야 한다.
- RDS exporter:
  - checksum 검증은 "파일이 있는 경로" 기준으로 해야 한다.

## 11. 끝나기 전 마지막 질문

스크립트를 마무리하기 전에 에이전트는 스스로 아래를 확인한다.

- 이 저장소 URL이 오늘도 공식적으로 맞는가?
- 이 패키지명이 실제 repo에서 존재하는가?
- 이 버전 문자열 매칭이 epoch/suffix를 고려하는가?
- 이 실패가 "의미 있는 실패"인가, 아니면 조용한 fallback인가?
- 이 빌드 산출물이 Terraform에서 실제로 사용되도록 연결돼 있는가?
