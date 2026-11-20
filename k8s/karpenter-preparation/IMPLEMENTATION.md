# Karpenter 1차 구현 — self-managed canary

2026-11-20 · `feature/karpenter-self-managed` · 클라우드 미적용

이번 변경은 고정 ASG를 유지하며 Karpenter worker 한 대의 생성·가입을 검증하기 위한 구현이다. controller 인증 설정, 역할별 IAM, 짧은 수명 join 발급·소비, NodePool/NodeClass와 시험 Pod를 만들었다. 운영 연결은 아직 하지 않았다. 기존 Kubernetes 점검의 12개 항목 전체를 수정한 작업이 아니다.

## 브랜치와 범위

기준 commit은 `88b501ec3835aff32a7e8a8913449b9a3a357fc9`다. 기존 `doktori-cloud`의 데이터 HA·APM 변경을 건드리지 않도록 `work/doktori-karpenter` worktree를 만들었다. 원본에 Windows가 체크아웃하지 못하는 `terraform/ ` 파일이 있어 sparse checkout에서 `/terraform/?`를 제외했다. 해당 한 글자 파일을 원본에서 삭제한 것은 아니다. Karpenter 조사 초안만 복사해 확장했다.

사용자 요청은 “이거 브랜치파서 작업들어가자”다. 직전 합의인 ASG 유지·self-managed Karpenter 최소 구성과 실제 배포하지 않기를 구현 범위로 삼았다. 이번에는 별도 학습 실험을 요청하지 않아 예측 질문을 추가하지 않았다. 코드·검사는 AI가 작성했으며 사용자 독립 수행으로 평가하지 않는다.

## 구현된 경로

| 구간 | 파일·동작 | 실패 처리 |
| --- | --- | --- |
| controller 인증 | [render.py](render.py)의 STS audience projected token, AWS role/token 환경변수, `EKS_CONTROL_PLANE=false`, 별도 API용 SA token | IMDS fallback 비활성. 실제 issuer·trust 검증은 후속 |
| IAM | [karpenter-identity module](../../terraform/modules/karpenter-identity/main.tf): controller·node·publisher 정책 | node는 지정 SSM 한 개 읽기만, controller의 PassRole은 전용 node role만 |
| 발급 | [join_runtime.py](join_runtime.py) `publish`: 고정 master에서 CA pin 확인 → 60분 kubeadm token → 3,500초 수명의 JSON을 SSM SecureString에 저장 | CA 불일치 시 token 생성 전 실패. SSM 실패는 성공으로 넘기지 않음 |
| 갱신 | [systemd timer](systemd/doktori-karpenter-publish.timer): 15분마다 한 master에서 발급 | 이전 token은 자연 만료. 발급 중단 시 유효기간 이후 신규 가입 중단; 기존 노드에는 영향 없음 |
| worker 가입 | userData에 비밀 없는 런타임·설정 포함 → IMDSv2로 EC2 identity → 지정 SSM 조회 → kubeadm JoinConfiguration | cluster·endpoint·CA pin·TTL·token 형식 확인. 임의 명령·추가 필드 거부 |
| 부분 실패 | 기존 `kubelet.conf`가 있으면 중단, join 정보 조회만 최대 10회 대기 | kubeadm reset/init·ASG health 호출·문자열 eval 없음. 부분 가입 실패는 운영자 점검 대상 |
| canary | ARM64 on-demand, 전용 taint, 자동 voluntary disruption budget 0, expire Never | 실제 비용 상한·강제 EC2 손실 방지를 의미하지 않음 |

worker 런타임은 Ubuntu 22.04 ARM64 기반의 기존 kubeadm AMI를 전제로 Python 3·AWS CLI·kubeadm 1.34.x·containerd·ECR credential provider를 요구한다. 부팅 중 패키지를 내려받거나 다른 버전으로 fallback하지 않는다. 새 Packer AMI를 빌드하지 않았고 실제 AMI의 Python·package manifest는 미확인이다.

가입 token은 userData·Terraform state·프로세스 인자에 넣지 않는다. root 전용 `/run` 임시 파일과 메모리로 전달하고 정상·예외 종료 시 임시 파일을 제거한다. 외부 명령 출력은 비밀을 포함할 수 있어 그대로 로그에 내보내지 않는다. 발급 성공 로그에는 만료 시각만 남긴다. host의 kubeadm 자체 파일·journal 등 운영 경로의 비밀 보존 여부는 실제 검증이 필요하다.

갱신기는 **지정된 master 한 대**에 설치하는 초기안이다. 로컬 flock은 여러 master 간 leader election이 아니다. 해당 master 장애 시 발급 복구 절차가 필요하며 이를 HA 발급기라고 부르지 않는다.

## IAM과 OIDC의 연결 경계

`identity.tf.example`은 global 레이어에서 기존 issuer provider를 재사용하거나 만드는 예시다. controller role을 중복 생성하던 초기 초안은 제거했다. 공개 HTTPS discovery/JWKS 호스팅, 실제 SA issuer/검증 키 전환은 기존 cluster identity를 확인한 뒤 별도 반영한다. 서명 개인키를 Terraform에 넣지 않는다. Calico 사용 여부가 OIDC 요구를 만드는 것은 아니다.

app 레이어는 global provider ARN을 `terraform_remote_state`로 받고 [IAM 모듈](../../terraform/modules/karpenter-identity/variables.tf)에 account·region·cluster name·issuer·join parameter·KMS key·AMI/subnet/SG·ECR repository를 명시적으로 전달한다. 현재 production root에는 연결하지 않았다. KMS key policy도 해당 역할의 SSM 사용을 허용해야 하며 IAM 정책만으로 실효 권한을 보장하지 않는다.

controller 정책은 [고정 upstream CloudFormation](upstream/cloudformation-v1.15.2.yaml)의 lifecycle/discovery 정책에서 파생했다. AMI·subnet·SG·account와 PassRole을 좁혔고 EKS 조회·동적 profile 생성/변경·SQS·reboot 권한을 넣지 않았다. 고정 AMI만 사용하므로 public SSM AMI 조회도 제외했다. 읽기용 instance profile 목록 조회는 upstream대로 남겼다. `eks:eks-cluster-name` tag 조건은 upstream의 자원 태그 계약으로 보존했으며 EKS 사용 권한을 부여하는 것은 아니다. Spot·예약 용량·추가 기능은 이번 정책 범위가 아니다.

publisher 정책은 지정 parameter에 `PutParameter`, 해당 Standard SecureString에 필요한 KMS Encrypt만 준다. worker에는 같은 parameter의 Get·KMS Decrypt와 선택한 private ECR pull을 준다. 앱 S3/SSM 권한·SSM remote management·master join 정보 접근을 승계하지 않는다. publisher 정책의 master role 연결은 아직 하지 않았다.

## 버전 정정

기존 조사 초안은 GitHub tag의 chart source를 보고 image tag를 1.15.2로 표기했지만 그 파일의 digest는 실제 1.15.2 OCI image와 달랐다. 이번에는 익명 공개 OCI registry에서 **배포된 chart 1.15.2와 controller 1.15.2 manifest**를 조회해 digest를 확인했다. AWS 계정 인증을 사용한 조회가 아니다.

[release-lock.json](upstream/release-lock.json)에 chart OCI digest·tgz SHA-256·controller digest와 Linux ARM64 지원 manifest를 보존했다. Helm은 이 chart archive를 렌더링하고 controller는 확인한 digest를 사용한다. 과거 [설계 기록](DESIGN-2026-11-18.md)의 “exit 78·7개 파일·trust only”는 당시 상태다. 현재는 실행 가능한 bootstrap과 9개 렌더 결과이며 production 적용은 여전히 미연결이다. 1.15.2의 운영 적합성·보안 공지·실제 1.34 patch 호환성 검증까지 끝났다는 뜻은 아니다.

## 로컬 검증 방법

cloud worktree 루트에서 Python의 [requirements.txt](requirements.txt), Helm 3.19.0, Terraform 1.14.8을 사용했다. 런타임 join 도구는 Python 표준 라이브러리만 사용한다. 다음 명령은 렌더·구조 검사이며 AWS·클러스터 접속을 하지 않는다.

```powershell
python -m unittest discover -s k8s/karpenter-preparation -p "test_*.py"
python k8s/karpenter-preparation/render.py --output k8s/karpenter-preparation/.generated-new
python k8s/karpenter-preparation/verify.py --helm <helm.exe-경로> --bash <bash.exe-경로>
terraform -chdir=terraform/modules/karpenter-identity validate
terraform -chdir=terraform/modules/karpenter-identity test
```

Terraform은 AWS provider 5.100.0을 기존 로컬 cache로 `init -backend=false`한 뒤 **mock_provider**로 검사했다. test의 `command=apply`는 mock 자원의 상태를 평가하며 AWS apply를 실행하지 않는다. 운영 root `plan-all.sh`, 실제 plan/apply/import/destroy는 실행하지 않았다. 새 설정이 운영 state와 충돌하지 않는다는 검증은 남아 있다.

Python 계약 검사 13개와 Terraform mock 검사 2개를 통과했다. token 만료·짧은 잔여 수명·미래 시각·CA/endpoint 불일치·명령 삽입·기존 node reset 방지·오류 출력의 token 비노출, SSM/kubeadm 실패 후 임시 파일 정리, IAM 역할 구분·OIDC 계정 불일치를 확인했다. Helm 전체 18문서 렌더와 CRD의 JSON 구조 schema, 생성 userData의 Bash 문법도 통과했다. CEL·admission·실제 kubeadm/STS/EC2 성공은 검증하지 않는다. 렌더 검사 결과는 [verification.json](verification.json)에 기록한다.

## 실제 적용 전에 채울 항목과 실행 순서

현재 입력은 전부 예시다. `000...` ID·가짜 CA·`.invalid` 주소로 적용하지 않는다. 실제 값을 받아도 이 renderer는 설치나 AWS 작업을 실행하지 않는다.

1. 실제 node/AMI/package 버전과 고정 system worker 두 대의 가용 자원을 확인한다. `doktori.io/node-role=system` label을 가진 노드가 없으면 controller는 Pending이 된다. ASG 교체 후에도 label이 유지되는 bootstrap 연결이 필요하다.
2. issuer의 discovery/JWKS·키 회전·API audience를 검증하고 global provider를 준비한다. 현재 API 서버 설정은 이 코드가 자동 변경하지 않는다.
3. app 레이어에서 IAM 모듈과 승인된 KMS policy를 연결한다. module output의 controller role·node profile을 입력 파일과 일치시킨다.
4. 지정 master에 `join_runtime.py`, publisher 설정, systemd unit을 설치하고 갱신을 확인한다. worker AMI는 Python·AWS CLI·kubeadm·ECR provider 전제조건을 만족해야 한다.
5. chart controller와 CRD, NodeClass/NodePool을 차례로 적용한 뒤 canary Deployment 한 개를 만든다. NodeClaim Launched → Registered → Initialized, Node Ready, Calico·DNS·image pull을 각각 확인한다.
6. ALB target은 기존 ASG에 유지한다. API/Chat·NGF를 새 노드로 옮기기 전에 새 Pod로의 실제 요청 경로와 앱 IAM 의존을 확인한다. 자동 축소·Chat drain·Spot은 다음 단계다.

[관측 조각](observability.alloy.example)은 단일 수집기에 붙이는 예시이며 기존 Alloy DaemonSet에 일괄 추가하지 않는다. Service target 하나는 두 controller replica 각각의 상태를 보장하지 않는다. 두 replica의 Pod readiness·leader 상태, NodeClaim 조건·기동 시간, publisher 마지막 성공/만료 시각, EC2↔Node↔NodeClaim 잔존 자원도 함께 확인해야 한다. 지금 수집기에 연결하거나 dashboard/alert를 실제 발화시키지는 않았다.

되돌릴 때는 canary workload 유입을 먼저 멈추고 고정 ASG 용량을 확인한다. NodePool 삭제는 노드 종료를 동반할 수 있다. controller를 먼저 제거해서 finalizer와 EC2가 남는 절차를 기본 rollback으로 쓰지 않는다. 자동 삭제 스크립트는 이번 변경에 넣지 않았다.

## 적용한 스킬과 남은 범위

| 스킬 | 적용 구간 | 결과·한계 |
| --- | --- | --- |
| `deliver-task` | 별도 worktree, 구현·오류 처리·관련 검사 | 배포 승인이나 학습 성과를 추정하지 않음 |
| `technical-writer` | 구성 경계·실행 순서·증거·미실행 | 소스와 실제 OCI artifact를 구분하고 과거 버전 설명 정정 |
| `korean-document-writing` | 한국어 구현 안내 | 구현 완료와 운영 적용·검증 완료의 의미 분리 |
| `token-usage-log` | 작업 사용량 기록 | 초기 지침 확인 이후부터 조회 시점까지 |

공식 근거는 [Karpenter Custom AMI](https://karpenter.sh/docs/concepts/nodeclasses/#custom), [kubeadm token](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-token/), [AWS self-hosted identity](https://github.com/aws/amazon-eks-pod-identity-webhook/blob/master/SELF_HOSTED_SETUP.md), [provider v1.15.2](https://github.com/aws/karpenter-provider-aws/tree/v1.15.2)다. 자체 검토이며 독립 agent·실제 클러스터 실험은 사용하지 않았다.
