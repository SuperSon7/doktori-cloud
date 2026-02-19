# Log & Metric Reliability Guide

Last updated: 2026-02-19
Author: jbdev

현재 로그/메트릭 수집 파이프라인의 신뢰성 한계와 환경별 대응 방안을 정리한다.

## 현재 아키텍처 (dev)

```
Container stdout ──→ Alloy (loki.source.docker) ──→ Loki (모니터링 서버)
Nginx log files  ──→ Alloy (loki.source.file)   ──→ Loki
Host/MySQL/App   ──→ Alloy (prometheus.scrape)   ──→ Prometheus (모니터링 서버)
```

## Dev 환경 현재 한계

### 1. Alloy → Loki 네트워크 장애 시 로그 유실

`loki.write`에 WAL(Write-Ahead Log)이 설정되어 있지 않다.
모니터링 서버가 일시 다운되면 Alloy가 로그를 버퍼링하지 못하고 **드랍**한다.

반면 `prometheus.remote_write`는 기본 WAL이 활성화되어 있어 메트릭은 복구 시 재전송된다.

| 구간 | 장애 시 메트릭 | 장애 시 로그 |
|------|:-----------:|:---------:|
| 모니터링 서버 다운 | WAL 버퍼링 → 복구 | **유실** |
| Alloy 재시작 (짧은) | WAL 복구 | Docker 소켓 재연결, 소량 유실 가능 |
| Alloy 장시간 다운 | WAL 복구 | Docker 로그 로테이션으로 유실 |

### 2. Loki 기본 rate limit

`limits_config`에 ingestion rate를 명시하지 않아 Loki 기본값이 적용된다.

| 항목 | 기본값 |
|------|-------|
| `ingestion_rate_mb` | 4 MB/s |
| `ingestion_burst_size_mb` | 6 MB |
| `per_stream_rate_limit` | 3 MB/s |

에러 폭주(스택 트레이스 무한 반복 등) 시 429 응답으로 드랍 가능.

### 3. Docker 로그 로테이션

Docker json-file 드라이버: `max-size: 10m`, `max-file: 3` (서비스당 최대 30MB).
Alloy가 장시간 중단되면 로테이션으로 밀린 로그가 유실될 수 있다.

### 4. Loki 저장소: 로컬 파일시스템

```yaml
storage_config:
  filesystem:
    directory: /loki/chunks
```

모니터링 서버 디스크 장애 시 30일치 로그 전체 유실.

### Dev 환경 판단

위 한계는 dev 환경에서는 허용 가능한 수준이다.
- 짧은 네트워크 끊김에도 메트릭은 안전
- 로그는 디버깅 용도이므로 소량 유실 허용

---

## Prod / Staging 환경 대응 방안

### 1. Alloy WAL 활성화 (로그 유실 방지)

`config.alloy`의 `loki.write` 블록에 WAL을 추가한다.

```alloy
loki.write "monitoring" {
  endpoint {
    url = "http://" + env("MONITORING_IP") + ":3100/loki/api/v1/push"
  }
  wal {
    enabled    = true
    max_segment_age = "1m"
  }
}
```

- 네트워크 장애 시 로그를 디스크에 버퍼링
- 복구 후 자동 재전송
- WAL 디렉토리 볼륨 마운트 필요 (`/var/lib/alloy/wal`)

docker-compose 추가 볼륨:
```yaml
volumes:
  - alloy-wal:/var/lib/alloy/wal
```

### 2. Loki S3 백엔드 (저장소 내구성)

로컬 파일시스템 → S3로 전환하여 디스크 장애에도 로그를 보존한다.

```yaml
schema_config:
  configs:
    - from: "2026-02-17"
      store: tsdb
      object_store: s3
      schema: v13
      index:
        prefix: index_
        period: 24h

storage_config:
  tsdb_shipper:
    active_index_directory: /loki/index
    cache_location: /loki/index_cache
  aws:
    s3: s3://<region>/<bucket-name>
    # EC2 instance profile (IAM role) 사용 시 credentials 불필요
```

필요 리소스:
- S3 버킷 (Terraform으로 생성)
- IAM role with `s3:PutObject`, `s3:GetObject`, `s3:ListBucket`, `s3:DeleteObject`
- 버킷 lifecycle policy로 장기 보관 비용 관리 (예: 90일 후 Glacier)

### 3. Loki rate limit 명시 설정

기본값에 의존하지 않고 워크로드에 맞게 설정한다.

```yaml
limits_config:
  ingestion_rate_mb: 10
  ingestion_burst_size_mb: 20
  per_stream_rate_limit: 5MB
  per_stream_rate_limit_burst: 20MB
  retention_period: 30d
```

### 4. Alloy 리소스 상향

WAL 사용 시 메모리/CPU 여유 필요.

```yaml
# docker-compose (prod)
deploy:
  resources:
    limits:
      memory: 512M   # dev: 256M → prod: 512M
      cpus: '0.5'    # dev: 0.25 → prod: 0.5
```

### 5. Docker 로그 보관량 확대 (선택)

Alloy 장시간 다운 대비.

```yaml
logging:
  driver: "json-file"
  options:
    max-size: "50m"   # dev: 10m → prod: 50m
    max-file: "5"     # dev: 3 → prod: 5
```

---

## 환경별 설정 요약

| 항목 | Dev | Staging | Prod |
|------|:---:|:-------:|:----:|
| Alloy WAL | off | on | on |
| Loki 저장소 | filesystem | filesystem | **S3** |
| Rate limit | 기본값 | 명시 설정 | 명시 설정 |
| Alloy 메모리 | 256M | 512M | 512M |
| Docker log max-size | 10m | 50m | 50m |
| Loki retention | 30d | 30d | 90d |

## 관련 문서

- [Alloy push monitoring deploy](../deployment/monitoring-deploy.md)
- [Observability Roadmap](../../OBSERVABILITY-ROADMAP.md)