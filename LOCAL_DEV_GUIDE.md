# Doktori 로컬 개발 환경

Docker Compose로 전체 스택을 로컬에서 실행하는 환경입니다.

## 사전 준비

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) 설치 후 실행
- Git, Make (Mac 기본 내장 / Windows: `choco install make`)

## 최초 세팅

```bash
git clone -b local-dev https://github.com/100-hours-a-week/5-team-service-cloud.git doktori
cd doktori
make setup
```

`make setup` 실행 후 **.env 파일 3개**를 수정해야 합니다:

| 파일                                                             | 내용                                             |
|----------------------------------------------------------------|------------------------------------------------|
| `.env`                                                         | DB 비밀번호 (`DB_PASSWORD`), DB 유저 (`DB_USERNAME`) |
| `Backend/.env`                                                 | JWT, Kakao OAuth, Zoom, S3 등                   |
| `Backend/api/main/src/resources/firebase-service-account.json` | 파이어베이스                                         |
| `AI/.env`                                                      | Gemini API key 등                               |

> 값은 팀 노션 참고

## 실행

```bash
make up       # 전체 빌드 + 시작 (첫 실행 시 5~10분 소요)
make down     # 중지 (데이터 유지)
make clean    # 중지 + 데이터 삭제 (주의!)
```

## 접속

| 서비스 | URL |
|--------|-----|
| Frontend | http://localhost |
| Backend API | http://localhost/api |
| Chat (WebSocket) | http://localhost/api/chat |
| AI | http://localhost/ai |
| MySQL | localhost:3307 (Workbench 등) |
| Redis | localhost:6379 |

## 개발 워크플로우

### 내 브랜치 코드를 Docker로 확인하고 싶을 때

`make up`은 **디스크에 있는 코드 그대로** 빌드합니다. git 브랜치를 신경 쓰지 않습니다.

```bash
cd Backend
git checkout feature/my-feature   # 내 브랜치로 이동
cd ..
make up                           # → feature/my-feature 코드로 전체 스택 실행
```

다른 서비스(Frontend, AI)도 마찬가지입니다. 각 폴더에서 원하는 브랜치를 체크아웃한 뒤 `make up`하면 그 코드로 빌드됩니다.

### develop 최신으로 동기화하고 싶을 때

```bash
make pull    # develop 브랜치인 레포만 pull → 재빌드 → 재시작
```

`make pull`은 **develop 브랜치에 있는 레포만** pull합니다. 다른 브랜치에서 작업 중인 레포는 자동으로 스킵되므로 안전합니다.

```
  Frontend: pulling develop...       ← develop이므로 pull
  Backend: on 'feature/auth' → skipped  ← 작업 중이므로 스킵
  AI: pulling develop...             ← develop이므로 pull
```

### 개별 레포만 pull하고 싶을 때

```bash
make pull-fe   # Frontend 현재 브랜치 pull
make pull-be   # Backend 현재 브랜치 pull
make pull-ai   # AI 현재 브랜치 pull
```

현재 체크아웃된 브랜치를 그대로 pull합니다. 재빌드는 하지 않으므로 필요하면 `make up`을 별도로 실행하세요.

### 모든 레포를 현재 브랜치 기준으로 동기화

```bash
make sync    # 모든 레포의 현재 브랜치 pull → 재빌드 → 재시작
```

`make pull`과 달리 develop 여부와 관계없이 각 레포의 현재 브랜치를 pull합니다.

### IDE로 개발할 때 (권장)

Docker 안에서는 IDE 디버깅(breakpoint 등)이 안 됩니다. 평소 개발은 DB만 Docker로 띄우고 서비스는 IDE에서 직접 실행하세요.

```bash
make deps    # MySQL(localhost:3307) + Redis(localhost:6379)만 실행
```

이후 IDE에서 Backend/Frontend/AI를 평소처럼 실행하면 됩니다. 전체 통합 테스트가 필요할 때만 `make up`을 사용하세요.

## 로그 & 디버깅

```bash
make logs          # 전체
make logs-be       # Backend (API)
make logs-chat     # Backend (Chat)
make logs-fe       # Frontend
make logs-ai       # AI
make ps            # 서비스 상태
make redis-cli     # Redis CLI
make mysql-cli     # MySQL CLI
make help          # 전체 명령어 목록
```

## 주의사항

- `make down` → 데이터 유지 / `make clean` → **데이터 삭제**
- Frontend 소스 변경 후 재빌드: `make clean && make up`
- 80 포트 충돌 시: `lsof -i :80`으로 확인 후 종료
- `make up`은 현재 디스크의 코드를 빌드 (브랜치 무관)
- `make pull`은 develop 브랜치인 레포만 pull (작업 중인 레포는 자동 스킵)
