/**
 * 롤백 무중단 검증 부하 테스트
 *
 * 목적: 롤백 수행 중에도 서비스가 무중단인지 검증한다.
 *       "롤백도 무중단" → 포트폴리오에서 가장 강력한 증거
 *
 * 사용법:
 *   ROLLBACK_TYPE=db      → DB 컷오버 롤백 (07-cutover-rollback.sh)
 *   ROLLBACK_TYPE=service  → 서비스 롤백 (10-service-rollback.sh)
 *   ROLLBACK_TYPE=nginx    → Nginx 롤백 (11-nginx-rollback.sh)
 *   ROLLBACK_TYPE=full     → 전체 (DB + 서비스 + Nginx 순차 롤백)
 *
 * 실행:
 *   k6 run --env BASE_URL=https://doktori.kr/api \
 *          --env JWT_TOKEN=<토큰> \
 *          --env ROLLBACK_TYPE=db \
 *          rollback-verification.js
 *
 * 포트폴리오 핵심:
 *   "DB 롤백 중 가용성 99.X%, 데이터 유실 0건"
 *   "서비스 롤백 X초 내 완료, 에러 0건"
 *   "Nginx 롤백 에러 0건, 서비스 중단 0초"
 */

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter, Gauge } from 'k6/metrics';
import { config } from '../../config.js';
import { getHeaders, initAuth, randomItem, thinkTime } from '../../helpers.js';

// ── 롤백 전용 메트릭 (forward와 구분) ──

// 가용성
const rollbackAvailability = new Rate('rollback_availability');
const rollbackReadSuccess = new Rate('rollback_read_success');
const rollbackWriteSuccess = new Rate('rollback_write_success');

// 에러
const rollbackErrors = new Counter('rollback_errors');
const rollbackTimeouts = new Counter('rollback_timeouts');
const rollbackConnectionResets = new Counter('rollback_connection_resets');

// 레이턴시
const rollbackLatency = new Trend('rollback_latency', true);
const rollbackReadLatency = new Trend('rollback_read_latency', true);
const rollbackWriteLatency = new Trend('rollback_write_latency', true);

// Phase별 (Before / During / After 롤백)
const beforeRollbackSuccess = new Rate('rollback_before_success');
const duringRollbackSuccess = new Rate('rollback_during_success');
const afterRollbackSuccess = new Rate('rollback_after_success');

// 롤백 특화
const rollbackDowntimeMs = new Gauge('rollback_downtime_ms');
const rollbackConsecutiveErrors = new Gauge('rollback_max_consecutive_errors');

// ── 설정 ──
const ROLLBACK_TYPE = __ENV.ROLLBACK_TYPE || 'db';

// 롤백 타입별 duration 설정
const DURATIONS = {
  db: '10m',       // DB 롤백: reverse replication sync 대기 포함
  service: '7m',   // 서비스 롤백: 컨테이너 교체 + 헬스체크
  nginx: '5m',     // Nginx 롤백: reload만이라 짧음
  full: '15m',     // 전체 순차 롤백
};

const duration = DURATIONS[ROLLBACK_TYPE] || '10m';

// 롤백 타입별 Phase 시간 (초)
const PHASES = {
  db:      { before: 120, during: 300, after: null },  // 2분 baseline, 5분 롤백
  service: { before: 90,  during: 180, after: null },  // 1.5분 baseline, 3분 롤백
  nginx:   { before: 60,  during: 120, after: null },  // 1분 baseline, 2분 롤백
  full:    { before: 120, during: 600, after: null },  // 2분 baseline, 10분 롤백
};

export const options = {
  scenarios: {
    // 읽기 가용성 (핵심 — 롤백 중에도 읽기는 되어야 함)
    rollback_reads: {
      executor: 'constant-vus',
      vus: 8,
      duration: duration,
      exec: 'rollbackReadCheck',
    },
    // 쓰기 확인 (DB 롤백 시 쓰기 불가 구간 측정)
    rollback_writes: {
      executor: 'constant-vus',
      vus: 3,
      duration: duration,
      exec: 'rollbackWriteCheck',
    },
    // 1초 간격 정밀 모니터링 (다운타임 정확 측정)
    rollback_monitor: {
      executor: 'constant-vus',
      vus: 1,
      duration: duration,
      exec: 'rollbackPreciseMonitor',
    },
    // 사용자 시나리오 (실제 체감 영향)
    rollback_user_scenario: {
      executor: 'constant-vus',
      vus: 3,
      duration: duration,
      exec: 'rollbackUserScenario',
    },
  },

  thresholds: {
    'rollback_availability': ['rate>0.99'],
    'rollback_read_success': ['rate>0.99'],
    'rollback_before_success': ['rate>0.999'],  // 롤백 전에는 거의 100%여야
    'rollback_errors': ['count<20'],
    'rollback_latency': ['p(95)<3000'],
  },
};

// ── 내부 상태 ──
let testStartTime = 0;
let consecutiveErrors = 0;
let maxConsecutiveErrors = 0;
let firstErrorTime = 0;
let lastErrorTime = 0;
let totalDowntimeMs = 0;

export function setup() {
  initAuth();
  testStartTime = Date.now();

  const phase = PHASES[ROLLBACK_TYPE] || PHASES.db;
  const beforeMin = Math.floor(phase.before / 60);
  const duringMin = Math.floor(phase.during / 60);

  console.log(`=== 롤백 검증 테스트 시작 (${ROLLBACK_TYPE}) ===`);
  console.log(`대상: ${config.baseUrl}`);
  console.log('');
  console.log(`Phase 1 (0~${beforeMin}분):   baseline — 롤백 전 정상 상태`);
  console.log(`Phase 2 (${beforeMin}~${beforeMin + duringMin}분): rollback — 이 구간에서 롤백을 수행하세요`);
  console.log(`Phase 3 (${beforeMin + duringMin}분~끝): verify — 롤백 후 안정 확인`);
  console.log('');

  if (ROLLBACK_TYPE === 'db') {
    console.log('DB 롤백: 07-cutover-rollback.sh 실행');
    console.log('  관찰 포인트: 읽기 유지 여부, 쓰기 복구 시점');
  } else if (ROLLBACK_TYPE === 'service') {
    console.log('서비스 롤백: 10-service-rollback.sh 실행');
    console.log('  관찰 포인트: 컨테이너 교체 중 에러, cold start 시간');
  } else if (ROLLBACK_TYPE === 'nginx') {
    console.log('Nginx 롤백: 11-nginx-rollback.sh 실행');
    console.log('  관찰 포인트: reload 시 연결 끊김, 에러 수');
  } else if (ROLLBACK_TYPE === 'full') {
    console.log('전체 롤백: Nginx → 서비스 → DB 순서로 롤백');
    console.log('  관찰 포인트: 각 단계별 에러 발생 시점');
  }

  console.log('================================================');
  return { startTime: Date.now() };
}

function getPhase() {
  const elapsed = (Date.now() - testStartTime) / 1000;
  const phase = PHASES[ROLLBACK_TYPE] || PHASES.db;

  if (elapsed < phase.before) return 'before';
  if (elapsed < phase.before + phase.during) return 'during';
  return 'after';
}

function getPhaseLabel() {
  const p = getPhase();
  if (p === 'before') return 'BEFORE_ROLLBACK';
  if (p === 'during') return 'DURING_ROLLBACK';
  return 'AFTER_ROLLBACK';
}

function recordResult(ok, latency) {
  rollbackAvailability.add(ok);
  if (ok) {
    rollbackLatency.add(latency);
    if (consecutiveErrors > 0) {
      // 복구 감지
      const recoveryGap = Date.now() - firstErrorTime;
      console.log(
        `[${new Date().toISOString()}] [${getPhaseLabel()}] ` +
        `RECOVERED after ${consecutiveErrors} errors (${recoveryGap}ms gap)`
      );
      if (lastErrorTime > firstErrorTime) {
        totalDowntimeMs += (lastErrorTime - firstErrorTime);
        rollbackDowntimeMs.add(totalDowntimeMs);
      }
    }
    consecutiveErrors = 0;
  } else {
    rollbackErrors.add(1);
    consecutiveErrors++;
    if (consecutiveErrors === 1) firstErrorTime = Date.now();
    lastErrorTime = Date.now();
    if (consecutiveErrors > maxConsecutiveErrors) {
      maxConsecutiveErrors = consecutiveErrors;
      rollbackConsecutiveErrors.add(maxConsecutiveErrors);
    }
  }

  // Phase별 기록
  const phase = getPhase();
  if (phase === 'before') beforeRollbackSuccess.add(ok);
  else if (phase === 'during') duringRollbackSuccess.add(ok);
  else afterRollbackSuccess.add(ok);
}

// ── 읽기 가용성 체크 ──
export function rollbackReadCheck() {
  const timestamp = new Date().toISOString();
  const phaseLabel = getPhaseLabel();

  const endpoints = [
    '/meetings?size=5',
    `/meetings/${config.testData.meetingId}`,
    '/recommendations/meetings',
  ];

  const path = randomItem(endpoints);
  const res = http.get(`${config.baseUrl}${path}`, {
    headers: getHeaders(false),
    tags: { name: `GET ${path.split('?')[0]}`, phase: phaseLabel },
    timeout: '10s',
  });

  const ok = res.status === 200;
  rollbackReadSuccess.add(ok);
  if (ok) rollbackReadLatency.add(res.timings.duration);

  recordResult(ok, res.timings.duration);

  if (!ok) {
    if (res.status === 0) {
      rollbackTimeouts.add(1);
      rollbackConnectionResets.add(1);
    }
    console.log(
      `[${timestamp}] [${phaseLabel}] READ FAIL: ${path} → ${res.status} ` +
      `(${res.timings.duration}ms) consecutive=${consecutiveErrors}`
    );
  }

  sleep(0.5);
}

// ── 쓰기 확인 (DB 롤백 시 쓰기 불가 구간 측정) ──
export function rollbackWriteCheck() {
  const timestamp = new Date().toISOString();
  const phaseLabel = getPhaseLabel();

  // 알림 설정 토글 (UPDATE users — 실제 DB 쓰기)
  const res = http.put(
    `${config.baseUrl}/users/me/notifications`,
    JSON.stringify({ pushNotificationAgreed: true }),
    {
      headers: getHeaders(true),
      tags: { name: 'PUT /users/me/notifications', phase: phaseLabel },
      timeout: '10s',
    }
  );

  const ok = res.status >= 200 && res.status < 300;
  const isAuthError = res.status === 401;

  // 401은 인증 문제라 쓰기 실패로 카운트하지 않음
  if (!isAuthError) {
    rollbackWriteSuccess.add(ok);
    if (ok) rollbackWriteLatency.add(res.timings.duration);
    recordResult(ok || isAuthError, res.timings.duration);
  }

  if (!ok && !isAuthError) {
    console.log(
      `[${timestamp}] [${phaseLabel}] WRITE FAIL: ${res.status} ` +
      `(${res.timings.duration}ms)`
    );
  }

  sleep(1);
}

// ── 1초 간격 정밀 모니터링 ──
export function rollbackPreciseMonitor() {
  const timestamp = new Date().toISOString();
  const phaseLabel = getPhaseLabel();
  const elapsed = Math.floor((Date.now() - testStartTime) / 1000);

  const healthRes = http.get(`${config.baseUrl}/health`, {
    tags: { name: 'GET /health (rollback)', phase: phaseLabel },
    timeout: '3s',
  });

  const dbRes = http.get(`${config.baseUrl}/meetings?size=1`, {
    headers: getHeaders(false),
    tags: { name: 'GET /meetings (rollback-monitor)', phase: phaseLabel },
    timeout: '5s',
  });

  const hOk = healthRes.status === 200;
  const dOk = dbRes.status === 200;

  // 에러 or 롤백 구간에서만 로그
  if (!hOk || !dOk || getPhase() === 'during') {
    const hLatency = healthRes.timings ? healthRes.timings.duration : 0;
    const dLatency = dbRes.timings ? dbRes.timings.duration : 0;
    console.log(
      `[${timestamp}] [${elapsed}s] [${phaseLabel}] ` +
      `health=${hOk ? 'OK' : 'FAIL'}(${Math.round(hLatency)}ms) ` +
      `db=${dOk ? 'OK' : 'FAIL'}(${Math.round(dLatency)}ms) ` +
      `consec_err=${consecutiveErrors}`
    );
  }

  sleep(1);
}

// ── 사용자 시나리오 (실제 체감 검증) ──
export function rollbackUserScenario() {
  const timestamp = new Date().toISOString();
  const phaseLabel = getPhaseLabel();
  let success = true;

  group('rollback_user_scenario', () => {
    // 1. 모임 목록
    const listRes = http.get(`${config.baseUrl}/meetings?size=10`, {
      headers: getHeaders(false),
      tags: { name: 'GET /meetings (user)', phase: phaseLabel },
      timeout: '10s',
    });
    if (listRes.status !== 200) {
      success = false;
      console.log(`[${timestamp}] [${phaseLabel}] USER: /meetings fail ${listRes.status}`);
    }
    sleep(1);

    // 2. 모임 상세
    const detailRes = http.get(`${config.baseUrl}/meetings/${config.testData.meetingId}`, {
      headers: getHeaders(false),
      tags: { name: 'GET /meetings/:id (user)', phase: phaseLabel },
      timeout: '10s',
    });
    if (detailRes.status !== 200) success = false;
    sleep(1);

    // 3. 검색
    const keyword = randomItem(config.searchKeywords);
    const searchRes = http.get(
      `${config.baseUrl}/meetings/search?keyword=${encodeURIComponent(keyword)}&size=5`,
      {
        headers: getHeaders(false),
        tags: { name: 'GET /meetings/search (user)', phase: phaseLabel },
        timeout: '10s',
      }
    );
    if (searchRes.status !== 200) success = false;
  });

  recordResult(success, 0);

  if (!success) {
    console.log(`[${timestamp}] [${phaseLabel}] USER SCENARIO FAIL`);
  }

  thinkTime(2, 4);
}

export function teardown(data) {
  console.log('');
  console.log(`=== 롤백 검증 테스트 종료 (${ROLLBACK_TYPE}) ===`);
  console.log('');
  console.log('┌─────────────────────────────────────────────┐');
  console.log('│          포트폴리오 핵심 지표                  │');
  console.log('├─────────────────────────────────────────────┤');
  console.log('│                                             │');
  console.log('│  rollback_availability     전체 가용성       │');
  console.log('│  rollback_before_success   롤백 전 성공률    │');
  console.log('│  rollback_during_success   롤백 중 성공률    │');
  console.log('│  rollback_after_success    롤백 후 성공률    │');
  console.log('│  rollback_errors           총 에러 수        │');
  console.log('│  rollback_downtime_ms      추정 다운타임(ms) │');
  console.log('│  rollback_max_consecutive_errors  최대 연속  │');
  console.log('│  rollback_read_success     읽기 성공률       │');
  console.log('│  rollback_write_success    쓰기 성공률       │');
  console.log('│                                             │');
  console.log('└─────────────────────────────────────────────┘');
  console.log('');
  console.log('포트폴리오 문장 예시:');

  if (ROLLBACK_TYPE === 'db') {
    console.log('  "DB 롤백 중 읽기 가용성 99.X%, 쓰기 복구 X초, 데이터 유실 0건"');
    console.log('  "Reverse Replication으로 롤백 시에도 데이터 정합성 100% 유지"');
  } else if (ROLLBACK_TYPE === 'service') {
    console.log('  "서비스 롤백 X초 내 완료, 에러 Y건, 가용성 99.X%"');
  } else if (ROLLBACK_TYPE === 'nginx') {
    console.log('  "Nginx 롤백 reload 기반 무중단, 에러 0건, 다운타임 0ms"');
  } else {
    console.log('  "전체 롤백(DB+서비스+Nginx) X분 내 완료, 가용성 99.X%"');
  }

  console.log('');
  console.log('비교 분석:');
  console.log('  before vs during → 롤백이 가용성에 미치는 영향');
  console.log('  during vs after  → 롤백 후 정상 복구 확인');
  console.log(`  추정 다운타임: ${totalDowntimeMs}ms`);
  console.log(`  최대 연속 에러: ${maxConsecutiveErrors}건`);
}
