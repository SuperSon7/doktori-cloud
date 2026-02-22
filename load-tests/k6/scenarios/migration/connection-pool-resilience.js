/**
 * DB 커넥션 풀 복원력 테스트
 *
 * 목적: DB 엔드포인트 전환 시 HikariCP 커넥션 풀이
 *       에러 → 드레인 → 재연결되는 과정을 관찰한다.
 *
 * 시나리오:
 *   Phase 1 (0~3분):  정상 트래픽 — baseline 수집
 *   Phase 2 (3~5분):  DB 엔드포인트 전환 시점 — 에러 발생 관찰
 *   Phase 3 (5~10분): 복구 후 — 커넥션 풀 안정화 관찰
 *
 * 관찰 포인트:
 *   - 에러 발생 시점과 복구 시점의 정확한 시간 차이
 *   - 커넥션 풀 드레인 후 새 커넥션이 맺어지는 시간
 *   - HikariCP maxLifetime(30분) / connectionTimeout(3초)의 실제 동작
 *
 * 포트폴리오 핵심:
 *   "커넥션 풀 복구 시간 X초, 자동 재연결 성공" 정량 데이터
 *
 * 실행:
 *   k6 run --env BASE_URL=https://doktori.kr/api \
 *          --env JWT_TOKEN=<토큰> \
 *          connection-pool-resilience.js
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend, Counter, Gauge } from 'k6/metrics';
import { config } from '../../config.js';
import { getHeaders, initAuth } from '../../helpers.js';

// ── 메트릭 ──
const dbReadSuccess = new Rate('connpool_db_read_success');
const dbWriteSuccess = new Rate('connpool_db_write_success');
const dbReadLatency = new Trend('connpool_db_read_latency', true);
const dbWriteLatency = new Trend('connpool_db_write_latency', true);
const connectionErrors = new Counter('connpool_connection_errors');
const recoveryDetected = new Counter('connpool_recovery_detected');

// 연속 실패/성공 추적 (복구 시점 감지)
let consecutiveFailures = 0;
let wasInFailureState = false;

export const options = {
  scenarios: {
    // DB 의존 요청만 집중적으로 (커넥션 풀 동작 관찰)
    db_heavy_reads: {
      executor: 'constant-vus',
      vus: 10,
      duration: '10m',
      exec: 'dbHeavyRead',
    },
    db_writes: {
      executor: 'constant-vus',
      vus: 5,
      duration: '10m',
      exec: 'dbWrite',
    },
    // 1초 간격 정밀 모니터링
    precise_monitor: {
      executor: 'constant-vus',
      vus: 1,
      duration: '10m',
      exec: 'preciseMonitor',
    },
  },

  thresholds: {
    // DB 읽기는 전환 후 95% 이상 복구
    'connpool_db_read_success': ['rate>0.95'],
    // 커넥션 에러는 제한적이어야 함
    'connpool_connection_errors': ['count<100'],
  },
};

export function setup() {
  initAuth();
  console.log('=== 커넥션 풀 복원력 테스트 시작 ===');
  console.log(`대상: ${config.baseUrl}`);
  console.log('');
  console.log('Phase 1 (0~3분): baseline 수집 중...');
  console.log('Phase 2 (3~5분): 이 구간에서 DB 엔드포인트를 전환하세요.');
  console.log('Phase 3 (5~10분): 복구 관찰');
  console.log('====================================');
}

// ── DB 읽기 집중 (모임 목록, 검색 — DB SELECT 쿼리) ──
export function dbHeavyRead() {
  const timestamp = new Date().toISOString();

  // 모임 목록 (JOIN + pagination — DB 커넥션 확실히 사용)
  const res = http.get(`${config.baseUrl}/meetings?size=20`, {
    headers: getHeaders(false),
    tags: { name: 'GET /meetings', type: 'db_read' },
    timeout: '10s',
  });

  const ok = res.status === 200;
  dbReadSuccess.add(ok);

  if (ok) {
    dbReadLatency.add(res.timings.duration);
  } else {
    connectionErrors.add(1);
    // 에러 내용에서 커넥션 관련 에러 식별
    const body = res.body ? res.body.substring(0, 200) : '';
    console.log(
      `[${timestamp}] DB_READ FAIL: ${res.status} ` +
      `(${res.timings.duration}ms) ${body}`
    );
  }

  sleep(0.3);
}

// ── DB 쓰기 (UPDATE 쿼리 — 알림 설정 토글) ──
export function dbWrite() {
  const timestamp = new Date().toISOString();

  const res = http.put(
    `${config.baseUrl}/users/me/notifications`,
    JSON.stringify({ pushNotificationAgreed: true }),
    {
      headers: getHeaders(true),
      tags: { name: 'PUT /users/me/notifications', type: 'db_write' },
      timeout: '10s',
    }
  );

  // 401은 인증 문제, 5xx가 DB 문제
  const isServerError = res.status >= 500;
  const ok = res.status >= 200 && res.status < 300;

  dbWriteSuccess.add(ok);

  if (ok) {
    dbWriteLatency.add(res.timings.duration);
  }

  if (isServerError) {
    connectionErrors.add(1);
    console.log(
      `[${timestamp}] DB_WRITE FAIL: ${res.status} ` +
      `(${res.timings.duration}ms)`
    );
  }

  sleep(0.5);
}

// ── 1초 간격 정밀 모니터링 (복구 시점 정확히 잡기) ──
export function preciseMonitor() {
  const timestamp = new Date().toISOString();
  const startTime = Date.now();

  // 헬스체크 + DB 의존 요청 동시 실행
  const healthRes = http.get(`${config.baseUrl}/health`, {
    tags: { name: 'GET /health', type: 'monitor' },
    timeout: '5s',
  });

  const dbRes = http.get(`${config.baseUrl}/meetings?size=1`, {
    headers: getHeaders(false),
    tags: { name: 'GET /meetings (monitor)', type: 'monitor' },
    timeout: '5s',
  });

  const healthOk = healthRes.status === 200;
  const dbOk = dbRes.status === 200;

  // 상태 변화 감지
  if (!dbOk) {
    consecutiveFailures++;
    if (!wasInFailureState && consecutiveFailures >= 3) {
      wasInFailureState = true;
      console.log(`[${timestamp}] ⚠️ 장애 상태 진입 (연속 ${consecutiveFailures}회 실패)`);
    }
  } else {
    if (wasInFailureState) {
      console.log(`[${timestamp}] ✅ 복구 감지! (${consecutiveFailures}회 실패 후 성공)`);
      recoveryDetected.add(1);
      wasInFailureState = false;
    }
    consecutiveFailures = 0;
  }

  // 상태 로그 (1초마다)
  const status = dbOk ? 'OK' : 'FAIL';
  const hStatus = healthOk ? 'OK' : 'FAIL';

  // 장애 구간에서만 상세 로그
  if (!dbOk || !healthOk) {
    console.log(
      `[${timestamp}] health=${hStatus} db=${status} ` +
      `latency=${dbRes.timings.duration}ms`
    );
  }

  sleep(1);
}

export function teardown(data) {
  console.log('=== 커넥션 풀 복원력 테스트 종료 ===');
  console.log('');
  console.log('포트폴리오 핵심 지표:');
  console.log('  - connpool_connection_errors: 총 커넥션 에러 수');
  console.log('  - connpool_recovery_detected: 복구 감지 횟수');
  console.log('  - connpool_db_read_latency: 전환 전후 레이턴시 비교');
  console.log('  - 로그에서 "장애 상태 진입" ~ "복구 감지" 시간 차이 = 커넥션 풀 복구 시간');
}
