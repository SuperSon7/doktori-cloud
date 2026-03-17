# ArgoCD setup and access

Last updated: 2026-03-17
Author: jbdev

ArgoCD 설치 후 Git 저장소 연결, Application 배포, UI 접근 방법.

## Before you begin

- K8s 클러스터 부트스트랩 완료 (`k8s-bootstrap.md` Step 1~6)
- `install-argocd.sh` 실행 완료 (Helm으로 ArgoCD 설치됨)
- GitHub Classic PAT (repo 스코프) 준비
- AWS CLI + Session Manager Plugin 설치 (로컬 UI 접근 시)

## Step 1: Run initial setup

1. 마스터 노드에서 setup 스크립트를 실행한다.

   ```bash
   ./setup-argocd.sh --skip-etcd --skip-kubelet
   ```

   프롬프트에 다음을 입력:
   - Git 저장소 URL: `https://github.com/100-hours-a-week/5-team-service-cloud.git`
   - Git Username: GitHub 계정명
   - Git PAT: Classic PAT (repo 스코프)
   - 새 비밀번호: 원하는 admin 비밀번호 (빈 값이면 건너뜀)

   > **Note:** config.env에 `GIT_REPO_URL`, `GIT_USERNAME` 값을 미리 넣어두면 프롬프트를 줄일 수 있다. `GIT_PAT`은 보안상 프롬프트로 입력 권장.

2. Application 배포를 확인한다.

   ```bash
   kubectl get applications -n argocd
   ```

   기대 결과:
   ```
   NAME                 SYNC STATUS   HEALTH STATUS
   doktori-workloads    Synced        Healthy
   doktori-hpa          Synced        Healthy
   ```

## Step 2: ArgoCD Application 구조

ArgoCD는 Git 레포의 **특정 폴더만** 감시한다:

| Application | Git path | Target namespace |
|-------------|----------|-----------------|
| doktori-workloads | `k8s/manifests/workloads/` | prod |
| doktori-hpa | `k8s/manifests/hpa/` | prod |

- `syncPolicy.automated`: prune + selfHeal 활성화 → Git 변경 시 자동 배포
- monitoring, security 매니페스트는 ArgoCD 관리 대상 아님 (스크립트로 관리)

## Step 3: Access ArgoCD UI (SSM port forwarding)

1. 로컬에서 접근 스크립트를 실행한다.

   ```bash
   ./scripts/argocd-ui.sh
   ```

   또는 수동으로 **터미널 2개**를 사용한다.

2. **터미널 1** — 마스터에서 port-forward:

   ```bash
   aws ssm start-session --target <MASTER_INSTANCE_ID>
   # 접속 후:
   sudo -u ubuntu bash
   export KUBECONFIG=/home/ubuntu/.kube/config
   kubectl port-forward svc/argocd-server -n argocd 8443:443 --address=127.0.0.1
   ```

3. **터미널 2** — 로컬에서 SSM 포트포워딩:

   ```bash
   aws ssm start-session \
     --target <MASTER_INSTANCE_ID> \
     --document-name AWS-StartPortForwardingSession \
     --parameters '{"portNumber":["8443"],"localPortNumber":["8443"]}'
   ```

4. 브라우저에서 접속한다.

   ```
   http://localhost:8443
   ```

   > **Note:** helm values에 `server.insecure: true` 설정이므로 **http://**로 접속. https://는 ERR_CONNECTION_CLOSED 발생.

   - Username: `admin`
   - Password: setup-argocd.sh에서 설정한 비밀번호

## Step 4: GitOps workflow (배포 흐름)

현재 수동 흐름:

1. `k8s/manifests/workloads/` 내 manifest 수정 (이미지 태그 등)
2. commit → push → PR → merge to main
3. ArgoCD가 main 변경 감지 → 자동 sync

향후 자동화 (CI 이미지 태그 업데이트):

1. BE팀 코드 push → CI 빌드 → ECR에 `prod-backend-api:<git-sha>` push
2. CI가 `chat-deployment.yaml`의 image 태그를 `<git-sha>`로 업데이트 → 자동 commit
3. ArgoCD auto-sync → 배포 완료

## Verify

```bash
# Application 상태
kubectl get applications -n argocd

# 최근 sync 이력
kubectl describe application doktori-workloads -n argocd | grep -A5 "Events:"

# ArgoCD 서버 Pod 상태
kubectl get pods -n argocd
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Application OutOfSync 유지 | auto-sync 비활성화 | UI에서 SYNC 버튼 또는 `syncPolicy.automated` 확인 |
| repo connection failed | PAT 만료 또는 권한 부족 | `kubectl get secret private-repo-creds -n argocd -o yaml` → PAT 재생성 |
| Progressing 상태 지속 | Pod ImagePullBackOff | 이미지 태그 확인, ECR 토큰 갱신 |
| UI ERR_CONNECTION_CLOSED | https://로 접속 | http://localhost:8443으로 변경 |
| SSM 포트포워딩 destination failed | 마스터에서 port-forward 안 띄움 | 터미널 1에서 kubectl port-forward 먼저 실행 |
| `resources-finalizer` warning | K8s 권장 경고 | 무시 가능, ArgoCD 공식 설정 |

## What's next

- [K8s hardening](../security/k8s-hardening.md)
