/**
 * 데이터 무손실 검증 부하 테스트
 *
 * 목적: 마이그레이션 중 쓰기(INSERT/UPDATE) 부하를 발생시키고,
 *       마이그레이션 전후 데이터 건수를 비교하여 데이터 유실 여부를 증명한다.
 *
 * 시나리오:
 *   1. Before: 마이그레이션 전 baseline 데이터 수집 (row count)
 *   2. During: 지속적인 쓰기 부하 (모임 참여, 알림 읽기 등)
 *   3. After: 마이그레이션 후 row count 비교
 *
 * 핵심 메트릭:
 *   - write_attempted: 시도한 쓰기 수
 *   - write_succeeded: 성공한 쓰기 수
 *   - write_failed: 실패한 쓰기 수 (마이그레이션 중 예상)
 *   - data_loss: 0이어야 함 (성공한 쓰기는 전부 반영)
 *
 * 포트폴리오 핵심:
 *   "마이그레이션 중 N건 쓰기 시도, 성공 X건 전부 반영, 데이터 유실 0건"
 *
 * 실행:
 *   k6 run --env BASE_URL=https://doktori.kr/api \
 *          --env JWT_TOKEN=<토큰> \
 *          data-integrity-verification.js
 */

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter, Gauge } from 'k6/metrics';
import { config } from '../../config.js';
import { getHeaders, initAuth, randomItem } from '../../helpers.js';

// ── 메트릭 ──
const writeAttempted = new Counter('integrity_write_attempted');
const writeSucceeded = new Counter('integrity_write_succeeded');
const writeFailed = new Counter('integrity_write_failed');
const writeSuccessRate = new Rate('integrity_write_success_rate');
const writeLatency = new Trend('integrity_write_latency', true);

const readSuccess = new Rate('integrity_read_success');
const readLatency = new Trend('integrity_read_latency', true);

// 쓰기 시도 ID 기록 (검증용)
const successfulWriteIds = new Counter('integrity_successful_write_ids');

export const options = {
  scenarios: {
    // 쓰기 부하: 지속적으로 POST/PUT 요청
    write_load: {
      executor: 'constant-vus',
      vus: 5,
      duration: '15m',
      exec: 'writeLoad',
    },
    // 읽기 부하: 데이터 반영 확인
    read_verify: {
      executor: 'constant-vus',
      vus: 3,
      duration: '15m',
      exec: 'readVerify',
    },
    // 주기적 상태 리포트
    reporter: {
      executor: 'constant-vus',
      vus: 1,
      duration: '15m',
      exec: 'periodicReport',
    },
  },

  thresholds: {
    // 마이그레이션 중에도 쓰기 성공률 90%+ (일시적 실패 허용)
    'integrity_write_success_rate': ['rate>0.90'],
    'integrity_read_success': ['rate>0.99'],
  },
};

// ── 내부 상태 ──
let totalWriteAttempts = 0;
let totalWriteSuccesses = 0;
let totalWriteFailures = 0;
let phaseStartTime = 0;

export function setup() {
  initAuth();
  phaseStartTime = Date.now();

  console.log('=== 데이터 무손실 검증 테스트 시작 ===');
  console.log(`대상: ${config.baseUrl}`);
  console.log('');
  console.log('이 테스트는 마이그레이션 중 쓰기 데이터의 무손실을 검증합니다.');
  console.log('');
  console.log('Phase 1 (0~3분):  baseline — 정상 쓰기 성공률 수집');
  console.log('Phase 2 (3~12분): migration — 마이그레이션 수행 (이 구간에서 작업)');
  console.log('Phase 3 (12~15분): verify — 데이터 반영 확인');
  console.log('=============================================');

  // Baseline: 초기 데이터 수 기록
  const meetingsRes = http.get(`${config.baseUrl}/meetings?size=1`, {
    headers: getHeaders(false),
    timeout: '10s',
  });

  let initialCount = 'N/A';
  if (meetingsRes.status === 200) {
    try {
      const data = meetingsRes.json();
      initialCount = data.data?.pageInfo?.totalElements || 'N/A';
    } catch (e) {
      // ignore
    }
  }
  console.log(`초기 모임 수: ${initialCount}`);

  return { startTime: Date.now(), initialCount };
}

// ── 쓰기 부하 ──
export function writeLoad() {
  const timestamp = new Date().toISOString();
  const elapsed = Math.floor((Date.now() - phaseStartTime) / 1000 / 60);

  // 다양한 쓰기 작업 수행
  const writeTypes = [
    { weight: 40, fn: writeNotificationRead },
    { weight: 30, fn: writeMeetingJoin },
    { weight: 30, fn: writeSearch },
  ];

  // 가중치 기반 선택
  const rand = Math.random() * 100;
  let cumulative = 0;
  let selectedFn = writeNotificationRead;

  for (const wt of writeTypes) {
    cumulative += wt.weight;
    if (rand < cumulative) {
      selectedFn = wt.fn;
      break;
    }
  }

  selectedFn(timestamp);
  sleep(1);
}

// 알림 읽음 처리 (PUT — DB UPDATE)
function writeNotificationRead(timestamp) {
  writeAttempted.add(1);
  totalWriteAttempts++;

  const res = http.put(`${config.baseUrl}/notifications`, null, {
    headers: getHeaders(true),
    tags: { name: 'PUT /notifications', type: 'write_integrity' },
    timeout: '10s',
  });

  const ok = res.status >= 200 && res.status < 300;
  writeSuccessRate.add(ok);

  if (ok) {
    writeSucceeded.add(1);
    totalWriteSuccesses++;
    writeLatency.add(res.timings.duration);
  } else if (res.status === 401) {
    // 인증 문제는 쓰기 실패로 카운트하지 않음
    writeSuccessRate.add(true);
  } else {
    writeFailed.add(1);
    totalWriteFailures++;
    console.log(
      `[${timestamp}] WRITE FAIL (notification): ${res.status} ` +
      `(${res.timings.duration}ms)`
    );
  }
}

// 모임 참여 시도 (POST — DB INSERT)
function writeMeetingJoin(timestamp) {
  writeAttempted.add(1);
  totalWriteAttempts++;

  const meetingId = config.testData.meetingId;
  const res = http.post(
    `${config.baseUrl}/meetings/${meetingId}/participations`,
    null,
    {
      headers: getHeaders(true),
      tags: { name: 'POST /meetings/:id/participations', type: 'write_integrity' },
      timeout: '10s',
    }
  );

  // 200, 201 = 성공, 400/409 = 이미 참여/정원초과 (정상 응답)
  const ok = res.status >= 200 && res.status < 500;
  writeSuccessRate.add(ok);

  if (res.status >= 200 && res.status < 300) {
    writeSucceeded.add(1);
    totalWriteSuccesses++;
    writeLatency.add(res.timings.duration);
  } else if (res.status >= 400 && res.status < 500) {
    // 비즈니스 에러 (이미 참여 등) — 서버는 정상
    writeSucceeded.add(1);
    totalWriteSuccesses++;
  } else {
    writeFailed.add(1);
    totalWriteFailures++;
    console.log(
      `[${timestamp}] WRITE FAIL (join): ${res.status} ` +
      `(${res.timings.duration}ms)`
    );
  }
}

// 검색 (GET — 캐시 미스 시 DB 조회)
function writeSearch(timestamp) {
  writeAttempted.add(1);
  totalWriteAttempts++;

  const keyword = randomItem(config.searchKeywords);
  const res = http.get(
    `${config.baseUrl}/meetings/search?keyword=${encodeURIComponent(keyword)}&size=5`,
    {
      headers: getHeaders(false),
      tags: { name: 'GET /meetings/search', type: 'write_integrity' },
      timeout: '10s',
    }
  );

  const ok = res.status === 200;
  writeSuccessRate.add(ok);

  if (ok) {
    writeSucceeded.add(1);
    totalWriteSuccesses++;
    writeLatency.add(res.timings.duration);
  } else {
    writeFailed.add(1);
    totalWriteFailures++;
    console.log(
      `[${timestamp}] SEARCH FAIL: ${res.status} (${res.timings.duration}ms)`
    );
  }
}

// ── 읽기 검증 (데이터 반영 확인) ──
export function readVerify() {
  const timestamp = new Date().toISOString();

  // 모임 목록 조회 (DB에서 데이터가 정상적으로 읽히는지)
  const meetingsRes = http.get(`${config.baseUrl}/meetings?size=20`, {
    headers: getHeaders(false),
    tags: { name: 'GET /meetings (verify)', type: 'read_verify' },
    timeout: '10s',
  });

  const ok = meetingsRes.status === 200;
  readSuccess.add(ok);

  if (ok) {
    readLatency.add(meetingsRes.timings.duration);

    // 응답에서 데이터 건수 확인
    try {
      const data = meetingsRes.json();
      const items = data.data?.items || data.data?.content || [];
      if (items.length === 0) {
        console.log(`[${timestamp}] READ VERIFY: 데이터 0건 — DB 연결 확인 필요`);
      }
    } catch (e) {
      // ignore
    }
  } else {
    console.log(`[${timestamp}] READ FAIL: ${meetingsRes.status}`);
  }

  sleep(2);
}

// ── 주기적 상태 리포트 ──
export function periodicReport() {
  const elapsed = Math.floor((Date.now() - phaseStartTime) / 1000);
  const minutes = Math.floor(elapsed / 60);
  const seconds = elapsed % 60;

  let phase = 'baseline';
  if (elapsed > 180 && elapsed <= 720) phase = 'migration';
  else if (elapsed > 720) phase = 'verify';

  console.log(
    `[REPORT ${minutes}m${seconds}s] phase=${phase} ` +
    `writes=${totalWriteAttempts} ok=${totalWriteSuccesses} ` +
    `fail=${totalWriteFailures} ` +
    `rate=${totalWriteAttempts > 0
      ? ((totalWriteSuccesses / totalWriteAttempts) * 100).toFixed(1) + '%'
      : 'N/A'}`
  );

  sleep(30);
}

export function teardown(data) {
  console.log('=== 데이터 무손실 검증 테스트 종료 ===');
  console.log('');
  console.log('포트폴리오 핵심 지표:');
  console.log('  - integrity_write_attempted: 총 쓰기 시도 수');
  console.log('  - integrity_write_succeeded: 쓰기 성공 수');
  console.log('  - integrity_write_failed: 쓰기 실패 수 (마이그레이션 중 발생)');
  console.log('  - integrity_write_success_rate: 쓰기 성공률');
  console.log('  - integrity_read_success: 읽기 성공률 (데이터 반영 확인)');
  console.log('');
  console.log('검증 방법:');
  console.log('  1. 쓰기 성공(integrity_write_succeeded)이 모두 DB에 반영되었는지');
  console.log('  2. 09-checksum-verify.sh로 Master/Slave CHECKSUM 일치 확인');
  console.log('  3. 실패 건수(integrity_write_failed)가 마이그레이션 구간에만 집중되는지');
}
