# SSM을 통한 Dev DB 접속 가이드

Last updated: 2026-02-21
Author: jbdev

SSM 포트포워딩으로 Dev 서버 MySQL에 접속하는 방법. VPN 불필요.

## 1. 사전 준비 (최초 1회)

### AWS CLI 설치

```bash
# macOS
brew install awscli

# 설치 확인
aws --version
```

### SSM 플러그인 설치

```bash
# macOS
brew install --cask session-manager-plugin

# 설치 확인
session-manager-plugin --version
```

### AWS 자격증명 등록

클라우드 담당자에게 **Access Key ID**와 **Secret Access Key**를 전달받은 뒤:

```bash
aws configure
```

| 항목 | 값 |
|------|-----|
| Access Key ID | (전달받은 값) |
| Secret Access Key | (전달받은 값) |
| Default region | `ap-northeast-2` |
| Default output | `json` |

등록 확인:

```bash
aws sts get-caller-identity
```

본인 유저명이 나오면 정상.

## 2. Dev 인스턴스 ID 확인

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=doktori-dev-app" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text
```

나온 `i-xxxxxxxxxxxxxxxxx` 값을 기억해둔다.

## 3. MySQL Workbench 접속

### 터미널: 포트포워딩 시작

```bash
aws ssm start-session \
  --target <INSTANCE_ID> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3306"],"localPortNumber":["3306"]}'
```

`Waiting for connections...` 메시지가 나오면 성공. **이 터미널은 접속하는 동안 열어둬야 한다.**

### Workbench: 연결 설정

| 항목 | 값 |
|------|-----|
| Connection Method | Standard (TCP/IP) |
| Hostname | `127.0.0.1` |
| Port | `3306` |
| Username | (기존 MySQL 계정) |
| Password | (기존 MySQL 비밀번호) |

> SSH 터널 설정 필요 없음. SSM이 암호화 터널 역할을 한다.

### 접속 종료

Workbench 연결을 닫고, 터미널에서 `Ctrl+C`로 포트포워딩을 종료한다.

## Troubleshooting

| 증상 | 원인 | 해결 |
|------|------|------|
| `TargetNotConnected` | 인스턴스 중지 상태 또는 SSM Agent 미실행 | 클라우드 담당자에게 인스턴스 상태 확인 요청 |
| `AccessDeniedException` | IAM 권한 부족 | `aws sts get-caller-identity`로 유저 확인, 클라우드 담당자에게 문의 |
| 로컬 3306 포트 충돌 | 로컬 MySQL이 이미 3306 사용 중 | `localPortNumber`를 `"13306"`으로 변경, Workbench Port도 `13306` |
| `session-manager-plugin not found` | 플러그인 미설치 | 위 설치 가이드 참고 |
