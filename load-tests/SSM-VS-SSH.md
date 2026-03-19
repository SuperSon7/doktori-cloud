# SSM Run Command vs SSH: 원격 명령 실행 시 주의사항

> 이 문서는 분산 부하테스트 인프라 구축 중 SSM RunCommand로 명령 실행이 반복 실패한 경험을 정리한 것이다.
> 최종적으로 SSH 방식으로 전환하여 해결했다.

## SSM RunCommand가 실패하는 이유

### 1. JSON 이스케이프 문제

SSM `send-command`는 명령어를 JSON으로 전달한다:

```bash
aws ssm send-command \
  --parameters '{"commands":["echo hello"]}'
```

명령어에 특수문자가 포함되면 JSON 파싱이 깨진다:

```bash
# 이런 명령은 실패한다
export BASE_URL='https://api.doktori.kr/api'   # ://' 때문에 JSON 깨짐
export K6_PROMETHEUS_RW_SERVER_URL='http://...' # 동일
cmd1 && cmd2                                     # && 도 문제될 수 있음
```

**증상:** `Status: Failed`, `StandardOutputContent: None`, `StandardErrorContent: None` — 출력 자체가 없음. 명령이 실행조차 안 된 것.

### 2. 환경변수 미설정 ($HOME)

SSM RunShellScript는 **root** 권한으로 실행되지만, 일부 환경변수가 비어있다:

```bash
# SSM 환경에서
echo $HOME   # → (빈 문자열)
echo $USER   # → root
whoami        # → root
```

이로 인해:
- `git config --global` 실패 (`$HOME not set`)
- `~/.gnupg` 경로 해석 실패

**해결:** 명령 앞에 `export HOME=/root` 추가... 하지만 이것도 JSON 안에서 이스케이프 문제를 만든다.

### 3. 파일 소유권 (dubious ownership)

SSM은 root로 실행되는데, 레포가 ubuntu 유저로 clone됐으면:

```
fatal: detected dubious ownership in repository at '/home/ubuntu/...'
```

**해결:** `git config --global --add safe.directory /path/to/repo` — 하지만 이것도 `$HOME` 문제에 걸린다.

### 4. heredoc이 안 된다

SSM commands 배열 안에서 heredoc 문법이 동작하지 않는다:

```bash
# 이런 건 안 됨
commands=["cat > /tmp/file.yml <<EOF\nkey: value\nEOF"]
```

YAML, docker-compose 파일을 생성해야 할 때 치명적이다.

**우회:** base64 인코딩으로 전달 → 디코딩 → 파일 생성. 하지만 이것도 JSON 안에서 깨질 수 있다.

### 5. 출력 길이 제한

SSM RunCommand 출력은 **24,000자**로 제한된다. k6 결과처럼 긴 출력은 잘린다.

## SSH는 왜 문제가 없는가

SSH는 **직접 셸 세션**을 열기 때문에:

| 항목 | SSM RunCommand | SSH |
|------|---------------|-----|
| 명령 전달 | JSON 문자열 파싱 | 셸에 직접 전달 |
| 특수문자 | JSON 이스케이프 필요 | 셸 문법 그대로 동작 |
| 환경변수 | 비어있을 수 있음 | 로그인 셸 환경 로드 |
| heredoc | 안 됨 | 정상 동작 |
| 출력 제한 | 24,000자 | 없음 (터미널 그대로) |
| 인증 | IAM + SSM Agent | SSH 키 |
| 포트 | 필요 없음 (443 아웃바운드만) | 22 인바운드 필요 |

```bash
# SSH에서는 그냥 된다
ssh ubuntu@ip "
  cd /home/ubuntu/repo && \
  git pull && \
  export BASE_URL=https://api.doktori.kr/api && \
  k6 run scenario.js
"
```

## SSM이 유용한 경우

SSH가 만능은 아니다. SSM이 더 나은 경우도 있다:

- **SG에 22번 포트를 열 수 없는 환경** (보안 정책)
- **키 관리가 번거로운 경우** (IAM만으로 접근 통제)
- **단순 명령** (`echo`, `systemctl`, `docker ps` 등 특수문자 없는 명령)
- **다수 인스턴스에 동시 명령** (태그 기반 타겟팅)

## 결론: 언제 뭘 쓸까

| 상황 | 추천 |
|------|------|
| 단순 명령 (특수문자 없음) | SSM RunCommand |
| 복잡한 셸 스크립트, URL, heredoc | **SSH** |
| 포트 못 여는 환경 | SSM |
| 인터랙티브 작업 | SSH 또는 SSM Session Manager |
| 부하테스트처럼 긴 실행 + 긴 출력 | **SSH** |

이 프로젝트에서는 SSM RunCommand를 SSH로 전환한 후 한 번에 성공했다.