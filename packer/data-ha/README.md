# 데이터 HA AMI 빌드와 실행 경로

2026-11-17 · Redis → RabbitMQ → MongoDB. 스크립트·템플릿 준비 후 사용자가 실제 AMI 생성과 임시 자원 정리를 승인해 개인 계정에서 순차 빌드를 진행했다. 결과는 [artifact·정리 기록](artifacts-2026-11-17.json)에 남겼다. `amazon-ebs` 빌드는 임시 EC2·EBS를 사용하며 완료 후 AMI와 snapshot이 남는다.

## 무엇을 실행하는가

| 작업 | 실행기 | 이번 실행 여부 |
| --- | --- | --- |
| 로컬 컨테이너 기동·확인·중지 | [local/data-ha/lab.py](../../local/data-ha/lab.py), [사용법](../../local/data-ha/README.md) | 앞선 구성 작업에서 기본 통신 확인 후 중지 |
| 데이터 AMI 구문 검사 | [images.py](../../scripts/data-ha/images.py) `check` | Packer 1.16.2, fmt·syntax-only 통과 |
| Redis → MQ → Mongo AMI 생성 | 같은 실행기 `build` | 후속 승인으로 실행. artifact·정리 결과는 작업 기록 참조 |
| AMI manifest → Terraform HA 입력 | 같은 실행기 `export` | fixture 10개 검사와 실제 manifest의 단계별 입력 파일 생성. exporter 자체는 AWS/부팅 검증 아님 |
| EC2 최초 기동 설정 | [Terraform bootstrap templates](../../terraform/environments/prod/data/templates/) | 렌더·구문만 검사. 실제 EC2에서 미실행 |

현재 로컬 기동 스크립트는 준비돼 있다. EC2는 Terraform의 user_data가 SSM credential·DNS·노드 역할을 넣고 systemd 서비스를 시작한다. 이 실행기는 Terraform apply·앱 배포·HA 장애 주입을 호출하지 않는다.

실제 결과: [artifact·정리 조회](artifacts-2026-11-17.json), [검증 범위](verification.json), [원본 manifest](manifests/). [Redis](ha-ami-ids-01-redis-2026-11-17.tfvars.json) → [Redis+MQ](ha-ami-ids-02-rabbitmq-2026-11-17.tfvars.json) → [세 서비스](ha-ami-ids-03-mongodb-2026-11-17.tfvars.json)의 실제 AMI 입력을 생성했다. 이 파일들은 자동 로드하지 않으며 Terraform을 실행하지 않았다. 결과 AMI/snapshot은 유지하고 빌드용 임시 자원은 정리했다. 새 AMI로 HA 서비스를 부팅하는 검증은 하지 않았다.

후속 [가시성 작업](../../monitoring/data-ha/README.md)에서 실제 AMI 입력에 `enable_data_ha_observability=true`를 추가했다. 기존 Python·Alloy를 이용하는 bootstrap 변경이며 이번에 AMI를 재빌드하거나 서비스에 apply하지 않았다. 이전 build 시점의 인계 patch는 보관하고 최신 관측 변경과 구분한다.

첫 MQ 빌드는 `rabbitmq-erlang-27` PPA의 Jammy ARM64 index에 필요한 OTP 27 패키지가 없어 중단했다. 공식 설치 가이드의 현재 `rabbitmq-erlang` PPA와 실제 package index를 대조해 수정한 뒤 재빌드했다. 실패 시도까지 포함해 builder 4대의 정리를 조회했다. 실제 AMI 버전은 Redis 7.2.17·MQ 4.3.8/Erlang 27.3.4.15·MongoDB 7.0.48이다. 앞선 Docker MQ 4.3.7과 패치가 다르며, 두 환경을 동일한 실행 검증으로 취급하지 않는다.

## 1. AWS 없이 검사

cloud 저장소 루트에서 실행한다. 호스트 Python 3와 Packer가 필요하다. 이 환경에서는 공식 배포의 SHA-256을 대조한 Packer 1.16.2 Windows amd64를 사용했다.

이 PC에서 Packer가 PATH에 없으면 `--packer ../tools/packer-1.16.2/packer.exe`를 지정한다. 빌드에는 검토한 AWS profile 환경을 사용한다. 이번에는 해당 프로세스에만 `AWS_PROFILE=default`와 로컬 `PACKER_PLUGIN_PATH`를 지정했고 영구 환경 설정·credential 파일은 변경하지 않았다.

```powershell
python scripts/data-ha/images.py check --packer packer
python -m unittest discover -s scripts/data-ha -p test_images.py -v
```

`check`는 공통 variables와 데이터 HCL 세 개만 임시 폴더로 복사한다. 다른 frontend/K8s/dev AMI 템플릿을 실행하지 않는다. 격리 사본의 Amazon plugin 요구 버전은 1.8.4로 고정한다. `fmt -check`, `validate -syntax-only`만 실행하며 plugin 다운로드·AWS 자격 증명/리전 조회·builder schema 검증을 하지 않는다. 실제 설정 전체가 유효하다고 판정한 결과가 아니다.

## 2. 실제 AMI 만들기

아래 build 명령은 실제 AWS 리소스를 만든다. 사용할 AWS 계정·리전·임시 builder 비용/권한·네트워크·Ubuntu base AMI·버전을 검토한다. 현재 builder는 t4g.small ARM64, public subnet·public IP, runner의 public IP에 제한한 임시 SSH SG를 사용한다. EBS root는 12 GiB gp3·암호화·종료 시 삭제로 설정한다. 로컬 Docker x86_64 결과로 ARM64 패키지 가용성·호환성을 대신하지 않는다.

```powershell
Copy-Item packer/data-ha/build.pkrvars.hcl.example packer/data-ha/build.pkrvars.hcl
# build.pkrvars.hcl의 placeholder를 검토한 실제 값으로 교체한다.
python scripts/data-ha/images.py build --service all `
  --var-file packer/data-ha/build.pkrvars.hcl --execute-cloud
```

`--service all`은 **Redis → RabbitMQ → MongoDB**를 순서대로 빌드하고 첫 실패에서 멈춘다. 하나만 만들려면 `--service redis`, `rabbitmq`, `mongodb`를 사용한다. plugin init과 build는 이 분기에서만 수행한다. 자격 증명은 표준 AWS 환경/SSO profile 체인을 사용하며 파일에 access key를 쓰지 않는다. 실행기는 `PKR_VAR_*`와 `HCP_PACKER_*` 환경 override를 자식 프로세스에서 제외한다. build 이름과 임시 자원에는 고유 run ID를 넣는다. 이번 실행은 `default` 프로필에서 STS로 확인한 개인 IAM 사용자와 기존 기본 VPC/subnet ID를 명시했다. VPC/subnet 태그·경로를 변경하지 않았다.

출력은 `.runtime/<UTC-time>-<id>/manifests/`에 격리한다. 실패 시 이전 run의 manifest를 성공 결과로 재사용하지 않는다. `-on-error=cleanup`은 Packer의 builder 정리를 요청하지만, 실패·취소 후 실제 잔여 EC2/EBS·완성된 AMI/snapshot 정리는 AWS에서 확인해야 한다. 이전 단계에서 이미 완성된 AMI를 자동 삭제하거나 공유·배포하지 않는다.

## 이미지와 부팅 설정의 경계

- Redis 7.2 계열과 Sentinel, RabbitMQ 4.3/Erlang 27 계열, MongoDB 7.0 계열, Alloy·AWS CLI·SSM Agent를 설치한다. 계열 내 실제 apt 패치 버전은 빌드 시 저장소에 따라 선택된다. 전체 공급망·정확한 패치 재현성을 고정한 구성이 아니다.
- `data_ha_source_ami`로 검토한 Ubuntu 22.04 ARM64 base를 고정한다. ID 형태만 검사하며 실제 owner·OS·architecture·보안 상태는 빌드 전/후 검토가 필요하다. 원래 템플릿의 빈 값 fallback 검색은 기존 호출자 호환용이고 새 runner는 구체 ID를 요구한다.
- package 설치·초기 정리 후 [finalizer](../scripts/data-ha-finalize.sh)가 DB/Sentinel·Alloy를 중지하고 자동 시작을 끈다. runtime bootstrap이 auth·peer·설정을 넣고 enable/restart한다. 이미지의 Redis/Mongo는 package loopback bind를 유지한다.
- 노드 데이터·Rabbit cookie는 기존 setup cleanup에서 제거한다. finalizer는 SSH host key·machine identity를 정리하고 `/opt/doktori/image-build.json`에 실제 설치 패키지 목록을 남긴다. 앱 비밀번호·Sentinel 비밀번호·replica keyfile·node identity는 이미지에 넣지 않는다.
- `ami_name`의 버전 tag나 manifest custom_data는 실제 프로그램 실행·부팅 성공 증거가 아니다. 최종 AMI의 package metadata, cloud-init·systemd와 서비스/관측 readiness를 나중에 확인해야 한다.

## 3. Terraform 입력으로 인계

세 서비스가 성공한 **하나의 run의** manifest 폴더를 사용한다. 단일 서비스만 빌드한 run으로 세 서비스를 내보내면 실패한다. 별도 run의 결과를 조합하려면 provenance와 승인 버전을 검토한 뒤 manifest 폴더를 명시적으로 준비한다.

```powershell
python scripts/data-ha/images.py export `
  --manifests packer/data-ha/.runtime/REVIEWED_RUN/manifests `
  --region ap-northeast-2 --through mongodb `
  --output packer/data-ha/.runtime/ha-reviewed.tfvars.json
```

`--through redis`는 Redis만, `rabbitmq`는 Redis+MQ, `mongodb`는 세 서비스 HA flag와 `ha_ami_ids`를 내보낸다. 각 manifest의 `last_run_uuid`·builder type·서비스·architecture·base AMI·artifact region/AMI 형식을 검사한다. 잘못된 입력, 서비스 간 같은 AMI, `.auto.tfvars.json`, 기존 출력 덮어쓰기는 거부한다. AWS에서 artifact 존재·소유권·보안·부팅을 확인하는 검사는 아니다.

기존 [update-ami-ids.sh](../../scripts/ami/update-ami-ids.sh)는 default AMI 값을 바꾸는 기존 경로다. HA는 `ha_ami_ids`를 쓰므로 새 exporter를 사용한다. 출력은 명시적으로 선택할 검토 파일이며 Terraform을 실행하지 않는다. 기존 variables.tf를 자동 수정하지 않는다.

`allow_redis_initial_primary`는 false로 내보낸다. **처음 만드는 빈 Redis 집합만** 초기 bootstrap 허용을 별도 검토한다. 이미 운영 중인 집합의 flag·AMI·user_data 변경은 stop/start·교체·데이터 영향 검토가 필요하다. [전환 조건](../../docs/design/data-ha-configuration-2026-11-17.md)을 함께 읽는다.

## 4. 빌드 후 임시 자원 확인

run ID는 `.runtime/<run>/` 이름이다. 아래 읽기 전용 도구는 AWS CLI v2로 지정한 계정과 run tag만 조회한다. 실행 중인 EC2·볼륨·SG·키·ENI 또는 보존 AMI에 연결되지 않은 tagged snapshot이 있으면 실패를 반환한다. `--build-log`를 주면 Packer가 출력한 임시 SG/key 이름도 별도 조회해 tag 누락 가능성을 보완한다. 결과 AMI와 연결된 snapshot은 삭제 대상에서 제외한다. `temporary_resources_clean` 결과만으로 다른 계정/리전·tag 없는 자원 전체를 정리했다고 주장하지 않는다.

```powershell
python scripts/data-ha/image_resources.py --profile default `
  --region ap-northeast-2 --account YOUR_CONFIRMED_ACCOUNT_ID --run YOUR_BUILD_RUN_ID
```

## 적용한 스킬과 검사

| 스킬 | 실제 적용 구간 | 검토 결과 |
| --- | --- | --- |
| deliver-task | 데이터 전용 Packer 실행기·최종 정리·artifact 인계와 승인된 실제 빌드 | fmt·syntax-only·Bash/embedded Python 구문, 인계/실행 제한 10개 검사 통과. 실제 artifact와 정리 결과는 작업 기록에 분리 |
| technical-writer | 이 사용법과 구성 기록 | 로컬/AMI/EC2 기동 경계·실행 여부·버전 고정 한계를 구분 |

AI가 작성·검사했으며 독립 수행 성과로 평가하지 않는다. 최초 `.example` 파일 직접 fmt는 Packer의 확장자 제한으로 실패했다. 검사할 때 임시 `.pkrvars.hcl` 사본을 사용해 수정했다.

## 공식 근거

- [Packer validate](https://developer.hashicorp.com/packer/docs/commands/validate): syntax-only와 전체 validation의 차이.
- [Amazon EBS builder](https://developer.hashicorp.com/packer/integrations/hashicorp/amazon/latest/components/builder/ebs): 임시 builder·AMI·source AMI·SSH SG 설정. 이 문서의 plugin 선택은 1.8.4다.
- [Manifest post-processor](https://developer.hashicorp.com/packer/docs/post-processors/manifest): artifact_id·run UUID·custom_data.
- [Packer 1.16.2 공식 배포](https://releases.hashicorp.com/packer/1.16.2/): 이 환경 도구와 checksum 출처.
- [RabbitMQ 4.3 Debian/Ubuntu 설치](https://www.rabbitmq.com/docs/4.3/install-debian): ARM64용 Erlang PPA와 저장소 서명·설치 경로.
