# 인프라 마이그레이션 가이드

## 1. 스크립트 사용법

### scripts/db/setup_app_user.sh — DB 앱 유저 생성
```bash
# rds_monitoring 인스턴스에서 실행 (SSM 접속)
aws ssm start-session --target <rds_monitoring_instance_id>

# 실행 (Parameter Store에서 자격증명 자동 읽음)
bash setup_app_user.sh
```
- admin(master): DB 관리 전용
- doktori_app: 앱 런타임 + Flyway (SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES)
- 비밀번호: SSM `/doktori/prod/DB_PASSWORD`

### scripts/db/init_app_user.sql — 수동 실행용
```bash
# <APP_PASSWORD>를 실제 값으로 교체 후 실행
mysql -h <RDS_ENDPOINT> -u admin -p < init_app_user.sql
```

### terraform/prod/compute/scripts/nginx_user_data.sh — Nginx 자동 프로비저닝
- `terraform apply` 시 자동 실행 (user_data)
- nginx 설치 + 설정 파일 배포 + certbot SSL + 시작
- 설정 파일은 base64로 인코딩되어 주입됨 (nginx $ 변수 이스케이핑 회피)

---

## 2. 무중단 마이그레이션 체크리스트

### Phase 1: 사전 준비
- [ ] 새 인프라 전체 프로비저닝 완료 (`terraform apply`)
- [ ] DB 앱 유저 생성 (`setup_app_user.sh`)
- [ ] 모든 서비스 health check 통과 확인
  - `curl http://<nginx_ip>/api/health` → 200
  - `curl http://<nginx_ip>/ai/health` → 200
  - `curl http://<nginx_ip>/nginx-health` → 200
  - `curl http://<nginx_ip>/` → 200 (frontend)
- [ ] DB 데이터 마이그레이션/동기화 완료

### Phase 2: DNS 전환 (무중단 핵심)
- [ ] Route53 A 레코드 TTL을 60초로 미리 낮추기 (최소 기존 TTL 만큼 대기 후 전환)
- [ ] 새 nginx EIP로 A 레코드 변경
- [ ] TTL 전파 대기 (60초)
- [ ] DNS 전파 확인: `dig doktori.kr +short` → 새 EIP

### Phase 3: SSL 활성화
```bash
# nginx 인스턴스에서 (SSM 접속)
certbot certonly --webroot -w /var/www/certbot \
  -d doktori.kr \
  --non-interactive --agree-tos --email admin@doktori.kr

# sites-available/default를 HTTPS 버전으로 교체
# (로컬 repo의 nginx/prod/sites-available/default가 최종 버전)
nginx -t && nginx -s reload
```

### Phase 4: 검증
- [ ] HTTPS 접속 확인: `curl -s https://doktori.kr/nginx-health`
- [ ] HTTP → HTTPS 리다이렉트 확인: `curl -s -o /dev/null -w "%{http_code}" http://doktori.kr/` → 301
- [ ] 전체 서비스 E2E 테스트
- [ ] 모니터링 지표 정상 확인

### Phase 5: 정리
- [ ] 로컬 /etc/hosts 정리: `sudo sed -i '' '/doktori.kr/d' /etc/hosts`
- [ ] 구 서버 트래픽 0 확인 후 종료
- [ ] Route53 TTL 원복 (300초)

---

## 3. 모니터링 지표 (마이그레이션 중 반드시 확인)

### 인프라 레벨
| 지표 | 확인 방법 | 정상 기준 |
|------|----------|----------|
| nginx 응답 코드 | access.log, `/nginx_status` | 5xx < 1% |
| upstream 응답 시간 | `urt=` in access.log | API < 1s, AI < 5s |
| 연결 실패 | error.log `connect() failed` | 0 |
| CPU/Memory | CloudWatch, `htop` | CPU < 80%, Mem < 80% |
| 디스크 | `df -h` | > 20% free |

### 서비스 레벨
| 지표 | 확인 방법 | 정상 기준 |
|------|----------|----------|
| API health | `/api/health` | 200 |
| Chat health | `/api/chat/health` | 401 (인증 필요 = 도달 확인) |
| AI health | `/ai/health` | 200 |
| Frontend | `/` | 200 |
| DB 연결 | API 로그에 `Access denied` 없음 | Flyway 마이그레이션 성공 |

### 네트워크 레벨
| 지표 | 확인 방법 | 정상 기준 |
|------|----------|----------|
| DNS 전파 | `dig doktori.kr +short` | 새 EIP |
| SSL 인증서 | `curl -vI https://doktori.kr 2>&1 \| grep expire` | 유효기간 확인 |
| nginx → backend | nginx에서 `curl http://<private_ip>:<port>/health` | 200 |

---

## 4. Route 53 Hosted Zone 이전 (계정 간 DNS 이동)

> 도메인이 **가비아 등록**이므로 "Route 53 도메인 이전"(계정 간 도메인 소유권 이전)은 **불필요**.
> 필요한 건 **Hosted Zone(레코드 관리)만 새 AWS 계정으로 옮기고, 가비아 NS를 변경**하는 것.

### 전제 조건
- 구 계정(A): 기존 Route 53 Hosted Zone에 레코드 운영 중
- 새 계정(B): 인프라 이전 완료, 새 EIP/ALB 등 엔드포인트 확보
- 도메인 등록: 가비아 (AWS Route 53 Domains 아님)

### Step 1: 사전 TTL 낮추기 (전환 24시간 전)

```bash
# 구 계정(A)에서 실행 — 모든 레코드 TTL을 300초로 낮추기
# 기존 TTL이 3600이면, 변경 후 최소 3600초(1시간) 대기해야 캐시 만료
aws route53 list-resource-record-sets --hosted-zone-id <OLD_ZONE_ID> \
  --query "ResourceRecordSets[?Type != 'NS' && Type != 'SOA']"
```
- NS, SOA 레코드는 건드리지 않음
- A, CNAME, TXT 등 서비스 레코드만 TTL 300으로 변경

### Step 2: 새 Hosted Zone 생성 (새 계정 B)

```bash
# 새 계정(B)에서 실행
aws route53 create-hosted-zone \
  --name doktori.kr \
  --caller-reference "migration-$(date +%Y%m%d%H%M%S)"
```
- 응답에서 `NameServers` 4개 확인 (나중에 가비아에 등록할 NS)
- `HostedZone.Id` 메모

### Step 3: 레코드 복사

```bash
# 구 계정(A)에서 레코드 export
aws route53 list-resource-record-sets --hosted-zone-id <OLD_ZONE_ID> \
  --output json > old-records.json

# NS, SOA 레코드 제거 후 새 계정(B)에 import
# jq로 필터링
cat old-records.json | jq '{
  Changes: [
    .ResourceRecordSets[]
    | select(.Type != "NS" and .Type != "SOA")
    | {Action: "UPSERT", ResourceRecordSet: .}
  ]
}' > changeset.json

# 새 계정(B)에서 실행
aws route53 change-resource-record-sets \
  --hosted-zone-id <NEW_ZONE_ID> \
  --change-batch file://changeset.json
```

- IP가 달라진 레코드(A 레코드 등)는 새 EIP로 수정 후 import
- ACM 검증용 CNAME은 **새 계정에서 새로 발급**해야 함 (인증서는 계정 바인딩)

### Step 4: 새 Hosted Zone 검증

```bash
# 새 NS 서버에 직접 질의해서 응답 확인
dig @ns-xxx.awsdns-xx.com doktori.kr A +short
dig @ns-xxx.awsdns-xx.com doktori.kr ANY +short

# 구 NS와 비교
dig @ns-yyy.awsdns-yy.com doktori.kr A +short
```
- 모든 레코드가 동일하게 응답하는지 확인

### Step 5: ACM 인증서 발급 (새 계정 B)

```bash
# 새 계정(B)에서 인증서 요청
aws acm request-certificate \
  --domain-name doktori.kr \
  --subject-alternative-names "*.doktori.kr" \
  --validation-method DNS \
  --region ap-northeast-2

# 검증용 CNAME 확인
aws acm describe-certificate --certificate-arn <NEW_CERT_ARN> \
  --query "Certificate.DomainValidationOptions[].ResourceRecord"
```
- 검증 CNAME을 **새 Hosted Zone에 추가**
- 단, NS 전환 전이므로 아직 검증 안 됨 → Step 6 이후 자동 검증

### Step 6: 가비아 네임서버 변경

1. [가비아 도메인 관리](https://dns.gabia.com) → doktori.kr → 네임서버 설정
2. 기존 NS 4개를 **새 Hosted Zone의 NS 4개**로 교체
3. 네임서버 전파 대기 (최대 48시간, 보통 1~2시간)

```bash
# 전파 확인
dig doktori.kr NS +short
# → 새 Hosted Zone의 NS 4개가 나오면 완료
```

### Step 7: 검증 및 정리

```bash
# DNS 전파 확인
dig doktori.kr A +short        # → 새 EIP
dig doktori.kr NS +short       # → 새 NS

# ACM 인증서 상태 확인 (DNS 검증 자동 완료)
aws acm describe-certificate --certificate-arn <NEW_CERT_ARN> \
  --query "Certificate.Status"  # → "ISSUED"

# HTTPS 확인
curl -vI https://doktori.kr 2>&1 | grep "subject\|expire"
```

- 구 Hosted Zone은 **며칠간 유지** (바로 삭제 금지 — 캐시에 구 NS 남아있을 수 있음)
- 전파 완전 확인 후 구 Hosted Zone 삭제

### 주의사항

| 항목 | 설명 |
|------|------|
| NS 전파 시간 | 가비아 NS 변경 후 최대 48시간, 그 사이 구/신 NS가 **섞여서 응답** |
| ACM 인증서 | 계정 바인딩이므로 새 계정에서 **새로 발급** 필수 (구 계정 인증서 사용 불가) |
| TTL 낮추기 | 반드시 **전환 전**에 해야 롤백이 빠름 |
| 구 Zone 유지 | NS 전파 완료까지 구 Zone 삭제 금지 — 캐시 만료 전 구 NS로 질의하는 클라이언트 있음 |
| 롤백 | 가비아에서 NS를 구 값으로 되돌리면 됨 (구 Zone이 살아있어야 가능) |

### 타임라인 요약

```
D-1일  : 구 계정 TTL 300초로 낮추기
D-day  : 새 Hosted Zone 생성 → 레코드 복사 → 검증
         ACM 인증서 요청 + 검증 CNAME 추가
         가비아 NS 변경
D+1시간: dig으로 NS 전파 확인, ACM ISSUED 확인
D+3일  : 구 Hosted Zone 삭제
```

---

## 5. 롤백 계획

### DNS 롤백 (가장 빠름, 1분 이내)
```bash
# Route53에서 A 레코드를 구 서버 IP로 원복
# TTL 60초이므로 1분 내 반영
```

### 서비스 롤백
```bash
# 특정 서비스만 이전 이미지로 롤백
docker stop <container>
docker run -d --name <container> <old_image>
```

### 판단 기준
- 5xx 에러 비율 > 5% → 즉시 DNS 롤백
- 특정 서비스만 문제 → 해당 서비스만 롤백
- DB 마이그레이션 문제 → Flyway 롤백 스크립트 또는 스냅샷 복원

---

## 6. 주의사항

### DNS TTL
- 전환 최소 24시간 전에 TTL을 300 → 60으로 낮출 것
- TTL이 높은 상태에서 전환하면 구 서버로 트래픽이 계속 갈 수 있음

### DB 동기화
- 마이그레이션 중 양쪽 DB에 쓰기가 발생하면 데이터 불일치
- 읽기 전용 모드 전환 → DNS 전환 → 새 DB에 쓰기 활성화 순서 권장

### Certbot
- DNS가 완전히 전파된 후에 실행해야 함
- Let's Encrypt는 HTTP-01 challenge를 사용하므로 80 포트 필수
- 인증서 발급 실패 시 rate limit 주의 (주당 5회)

### SG(Security Group)
- nginx SG → backend SG 참조 기반이므로 nginx 인스턴스 교체 시 SG 연결 확인
- 새 인스턴스가 올바른 SG에 연결되어 있는지 반드시 확인

### Flyway 마이그레이션
- 첫 기동 시 Flyway가 DDL을 실행하므로 앱 유저에 DDL 권한 필수
- 마이그레이션 실패 시 `flyway_schema_history` 테이블 확인