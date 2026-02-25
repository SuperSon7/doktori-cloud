# DB 무중단 마이그레이션 연습 스크립트

> Lightsail MySQL(Master) → RDS MySQL(Slave) 복제 + 컷오버 연습

## 스크립트 실행 순서

```
01-check-master-status.sh   Master binlog/복제 설정 점검
        ↓
02-mysqldump.sh             Master DB 덤프 (binlog position 포함)
        ↓
   [수동] 덤프 파일을 RDS에 적재
        ↓
03-setup-replication.sh     RDS에서 복제 설정 (rds_set_external_master)
        ↓
04-monitor-replication.sh   복제 상태 실시간 모니터링 (Ctrl+C로 종료)
        ↓
05-verify-data.sh           Master ↔ Slave 데이터 정합성 검증
        ↓
05.5-setup-db-proxy.sh      Nginx stream DB 프록시 구성 (1회, 컷오버 전 사전 작업)
        ↓
06-cutover-rehearsal.sh     컷오버 리허설 (read_only → 승격 → nginx upstream 전환)
        ↓
07-cutover-rollback.sh      롤백 연습 (nginx upstream → 구 Master로 원복)
```

## 아키텍처: Nginx Stream DB 프록시

컷오버 시 **앱 재시작 없이** DB를 전환하기 위해 Nginx stream TCP 프록시를 사용합니다.

```
앱 (DB_URL=127.0.0.1:3307)
        ↓
  Nginx stream (listen 3307)
        ↓
  upstream db_backend
    ├─ 평소:    127.0.0.1:3306 (로컬 MySQL)
    └─ 컷오버:  RDS_HOST:3306  (nginx reload만으로 전환)
```

**왜 이 방식인가?**
- 앱 설정(Parameter Store) 변경 + 재시작 = 다운타임 발생
- Nginx stream은 `reload`로 무중단 upstream 전환 가능
- DNS 방식은 Java/JDBC DNS 캐시 때문에 전환 즉시성이 떨어짐
- 단일 서버에서 가장 예측 가능하고 현실적인 방법

**컷오버 시 커넥션 풀 갱신 흐름:**
1. `read_only = 1` → 기존 커넥션으로 쓰기 실패
2. nginx upstream → RDS로 전환 + reload
3. HikariCP가 실패한 커넥션을 무효화하고 새 커넥션 생성
4. 새 커넥션은 nginx 프록시를 통해 RDS로 연결됨

## 사전 준비

### 1. Master(dev MySQL) binlog 활성화

Docker MySQL이라면 docker-compose에 command 추가:

```yaml
mysql:
  image: mysql:8.0.39
  command: --log-bin=mysql-bin --binlog-format=ROW --server-id=1
  ports:
    - "3306:3306"
```

변경 후 MySQL 재시작 필요 (이것이 유일한 계획된 다운타임)

### 2. 복제 전용 유저 생성 (Master에서)

```sql
CREATE USER 'repl_user'@'%' IDENTIFIED BY '<비밀번호>';
GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'%';
FLUSH PRIVILEGES;
```

### 3. 테스트용 RDS 생성

- MySQL 8.0 호환
- Public Subnet에 임시 배치 (dev 서버에서 접근 가능하게)
- 보안그룹: dev 서버 IP에서 3306 인바운드 허용
- 프리티어 또는 최소 인스턴스 사용 (연습용)

### 4. 네트워크 확인

```bash
# dev 서버 → RDS 연결 확인
mysql -h <RDS_ENDPOINT> -u admin -p

# RDS → dev MySQL 연결 확인 (복제에 필요)
# dev 서버의 보안그룹에서 RDS IP 또는 VPC CIDR의 3306 인바운드 허용
```

### 5. Nginx stream DB 프록시 구성 (컷오버 전 사전 작업)

```bash
# dev 서버에서 실행 (sudo 필요)
sudo bash 05.5-setup-db-proxy.sh

# 이후 Parameter Store DB_URL 변경
# jdbc:mysql://127.0.0.1:3307/doktoridb?...

# 앱 1회 재시작 (이후 컷오버 때는 재시작 불필요)
```

## 환경변수

각 스크립트에서 사용하는 환경변수:

```bash
# Master (dev MySQL)
export MASTER_HOST=localhost    # dev 서버에서 실행 시
export MASTER_PORT=3306
export MASTER_USER=root
export MASTER_PASS=<비밀번호>

# Slave (RDS)
export RDS_HOST=<RDS_ENDPOINT>
export RDS_PORT=3306
export RDS_USER=admin
export RDS_PASS=<비밀번호>

# 공통
export DB_NAME=doktoridb
export REPL_USER=repl_user
export REPL_PASS=<비밀번호>
```

## 성공 기준 (2회 연속 달성 필요)

| 항목 | 기준 |
|------|------|
| 쓰기 불가 구간 | 60초 이내 |
| 사용자 체감 에러 | 0건 |
| 롤백 소요 시간 | 3분 이내 |
| 데이터 정합성 | 100% 일치 |
