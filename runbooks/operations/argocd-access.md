# ArgoCD UI 접근 가이드

Last updated: 2026-03-17
Author: jbdev

SSM을 통해 ArgoCD 웹 UI에 접근하는 방법. 터미널 2개 필요.

## Before you begin

- AWS CLI 설치 + `doktori-admin` 프로필 설정 완료
- [Session Manager Plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) 설치
- 마스터 인스턴스 ID 확인:
  ```bash
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=*k8s-master*" "Name=tag:Role,Values=k8s-cp" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].[InstanceId,PrivateIpAddress]' \
    --output table
  ```

## Step 1: 마스터에서 port-forward 실행

**터미널 1**을 열고 마스터에 SSM 접속한다.

```bash
aws ssm start-session --target <MASTER_INSTANCE_ID>
```

접속 후:

```bash
sudo -u ubuntu bash
export KUBECONFIG=/home/ubuntu/.kube/config
kubectl port-forward svc/argocd-server -n argocd 8443:443 --address=127.0.0.1
```

아래 로그가 나오면 성공:

```
Forwarding from 127.0.0.1:8443 -> 8080
```

> 이 터미널은 **열어둔 상태**로 유지한다.

## Step 2: 로컬에서 SSM 포트포워딩

**터미널 2**를 열고 실행한다.

```bash
aws ssm start-session \
  --target <MASTER_INSTANCE_ID> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8443"],"localPortNumber":["8443"]}'
```

아래 로그가 나오면 성공:

```
Port 8443 opened for sessionId ...
Waiting for connections...
```

## Step 3: 브라우저에서 접속

```
http://localhost:8443
```

- **http://** 로 접속 (https 아님)
- Username: `admin`
- Password: 클라우드 담당자에게 문의

## 종료

터미널 1, 2 모두 `Ctrl+C`로 종료.

## Troubleshooting

| 증상 | 원인 | 해결 |
|------|------|------|
| `ERR_CONNECTION_CLOSED` | https://로 접속 | **http://**localhost:8443 으로 변경 |
| `connection to destination port failed` | 터미널 1의 port-forward 안 띄움 | Step 1 먼저 실행 |
| `TargetNotConnected` | 인스턴스 SSM Agent 미동작 | 인스턴스 상태 확인 (Running인지) |
| `ExpiredTokenException` | AWS 세션 만료 | `aws sso login` 또는 credentials 갱신 |
