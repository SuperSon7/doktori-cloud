/**
 * DB 컷오버 부하 테스트
 *
 * 목적: Master → RDS 컷오버 중 읽기/쓰기 트래픽의 동작을 검증한다.
 *
 * 시나리오:
 *   1. read_only=1 전에: 읽기/쓰기 모두 정상
 *   2. read_only=1 후:   읽기 정상, 쓰기 실패 시작
 *   3. 엔드포인트 전환 후: 읽기/쓰기 모두 정상 복구
 *
 * 실행 방법:
 *   k6 run --env BASE_URL=https://doktori.kr/api \
 *          --env JWT_TOKEN=<토큰> \
 *          db-cutover-traffic.js
 *
 * 컷오버 절차:
 *   1. 이 스크립트 실행 (10분간 부하)
 *   2. 2~3분 후 Master에 SET GLOBAL read_only = 1
 *   3. 동기화 확인 후 RDS 승격
 *   4. 앱 DB 엔드포인트 전환 + 재시작
 *   5. 쓰기 복구 확인
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend, Counter, Gauge } from 'k6/metrics';
import { config } from '../../config.js';
import {
  apiGet, apiPost, getHeaders, initAuth,
  randomItem, randomInt, thinkTime,
} from '../../helpers.js';

// ── 마이그레이션 전용 메트릭 ──

// 읽기
const readSuccess = new Rate('migration_read_success');
const readLatency = new Trend('migration_read_latency', true);
const readErrors = new Counter('migration_read_errors');

// 쓰기
const writeSuccess = new Rate('migration_write_success');
const writeLatency = new Trend('migration_write_latency', true);
const writeErrors = new Counter('migration_write_errors');
const writeFailedDuringCutover = new Counter('migration_write_failed_during_cutover');

// 헬스체크
const healthSuccess = new Rate('migration_health_success');
const healthLatency = new Trend('migration_health_latency', true);

// 전체
const overallAvailability = new Rate('migration_overall_availability');

export const options = {
  scenarios: {
    // 읽기 트래픽 (전체의 70% — 실제 서비스 비율 반영)
    readers: {
      executor: 'constant-vus',
      vus: 14,
      duration: '10m',
      exec: 'readTraffic',
    },
    // 쓰기 트래픽 (전체의 20%)
    writers: {
      executor: 'constant-vus',
      vus: 4,
      duration: '10m',
      exec: 'writeTraffic',
    },
    // 헬스체크 (지속 모니터링)
    health_monitor: {
      executor: 'constant-vus',
      vus: 2,
      duration: '10m',
      exec: 'healthCheck',
    },
  },

  thresholds: {
    // 읽기는 컷오버 중에도 99% 이상 성공해야 함
    'migration_read_success': ['rate>0.99'],
    // 헬스체크는 99% 이상
    'migration_health_success': ['rate>0.99'],
    // 읽기 P95 500ms 이내
    'migration_read_latency': ['p(95)<500'],
    // 전체 가용성 95% 이상 (쓰기 실패 구간 감안)
    'migration_overall_availability': ['rate>0.95'],
  },
};

export function setup() {
  initAuth();
  console.log('=== DB 컷오버 부하 테스트 시작 ===');
  console.log(`대상: ${config.baseUrl}`);
  console.log('2~3분 후 컷오버를 시작하세요.');
  console.log('================================');
}

// ── 읽기 트래픽 ──
export function readTraffic() {
  const timestamp = new Date().toISOString();

  // 1. 모임 목록 조회 (Public, DB SELECT)
  const listRes = http.get(`${config.baseUrl}/meetings?size=10`, {
    headers: getHeaders(false),
    tags: { name: 'GET /meetings', type: 'read' },
    timeout: '10s',
  });

  const listOk = listRes.status === 200;
  readSuccess.add(listOk);
  readLatency.add(listRes.timings.duration);
  overallAvailability.add(listOk);
  if (!listOk) {
    readErrors.add(1);
    console.log(`[${timestamp}] READ FAIL /meetings: ${listRes.status} (${listRes.timings.duration}ms)`);
  }

  sleep(0.5);

  // 2. 모임 검색 (Public, DB SELECT with search)
  const keyword = randomItem(config.searchKeywords);
  const searchRes = http.get(
    `${config.baseUrl}/meetings/search?keyword=${encodeURIComponent(keyword)}&size=5`,
    {
      headers: getHeaders(false),
      tags: { name: 'GET /meetings/search', type: 'read' },
      timeout: '10s',
    }
  );

  const searchOk = searchRes.status === 200;
  readSuccess.add(searchOk);
  readLatency.add(searchRes.timings.duration);
  overallAvailability.add(searchOk);
  if (!searchOk) {
    readErrors.add(1);
    console.log(`[${timestamp}] READ FAIL /meetings/search: ${searchRes.status}`);
  }

  sleep(0.5);

  // 3. 추천 모임 (Public, DB SELECT)
  const recoRes = http.get(`${config.baseUrl}/recommendations/meetings`, {
    headers: getHeaders(false),
    tags: { name: 'GET /recommendations/meetings', type: 'read' },
    timeout: '10s',
  });

  const recoOk = recoRes.status === 200;
  readSuccess.add(recoOk);
  readLatency.add(recoRes.timings.duration);
  overallAvailability.add(recoOk);
  if (!recoOk) readErrors.add(1);

  thinkTime(1, 2);
}

// ── 쓰기 트래픽 ──
export function writeTraffic() {
  const timestamp = new Date().toISOString();

  // 1. 알림 설정 토글 (PUT — DB UPDATE on users table)
  const settingsRes = http.put(
    `${config.baseUrl}/users/me/notifications`,
    JSON.stringify({ pushNotificationAgreed: true }),
    {
      headers: getHeaders(true),
      tags: { name: 'PUT /users/me/notifications', type: 'write' },
      timeout: '10s',
    }
  );

  const writeOk = settingsRes.status >= 200 && settingsRes.status < 300;
  writeSuccess.add(writeOk);
  overallAvailability.add(writeOk);

  if (writeOk) {
    writeLatency.add(settingsRes.timings.duration);
  } else {
    writeErrors.add(1);
    writeFailedDuringCutover.add(1);
    console.log(
      `[${timestamp}] WRITE FAIL PUT /users/me/notifications: ${settingsRes.status} ` +
      `(${settingsRes.timings.duration}ms) — ${settingsRes.body ? settingsRes.body.substring(0, 100) : 'no body'}`
    );
  }

  sleep(1);

  // 2. 내 프로필 조회 → 수정 (GET + PUT — DB SELECT + UPDATE)
  const profileRes = http.get(`${config.baseUrl}/users/me`, {
    headers: getHeaders(true),
    tags: { name: 'GET /users/me', type: 'read' },
    timeout: '10s',
  });

  if (profileRes.status === 200) {
    readSuccess.add(true);
    readLatency.add(profileRes.timings.duration);
    overallAvailability.add(true);

    // 알림 설정 토글 (쓰기)
    const notiRes = http.put(
      `${config.baseUrl}/users/me/notifications`,
      JSON.stringify({ pushNotificationAgreed: true }),
      {
        headers: getHeaders(true),
        tags: { name: 'PUT /users/me/notifications', type: 'write' },
        timeout: '10s',
      }
    );

    const notiOk = notiRes.status >= 200 && notiRes.status < 300;
    writeSuccess.add(notiOk);
    overallAvailability.add(notiOk);
    if (notiOk) {
      writeLatency.add(notiRes.timings.duration);
    } else {
      writeErrors.add(1);
      writeFailedDuringCutover.add(1);
      console.log(`[${timestamp}] WRITE FAIL PUT /users/me/notifications: ${notiRes.status}`);
    }
  } else {
    readSuccess.add(false);
    readErrors.add(1);
    overallAvailability.add(false);
  }

  thinkTime(2, 4);
}

// ── 헬스체크 (0.5초 간격) ──
export function healthCheck() {
  const timestamp = new Date().toISOString();

  // API 헬스체크
  const apiHealth = http.get(`${config.baseUrl}/health`, {
    tags: { name: 'GET /health', type: 'health' },
    timeout: '5s',
  });

  const apiOk = apiHealth.status === 200;
  healthSuccess.add(apiOk);
  healthLatency.add(apiHealth.timings.duration);
  overallAvailability.add(apiOk);

  if (!apiOk) {
    console.log(`[${timestamp}] HEALTH FAIL: ${apiHealth.status} (${apiHealth.timings.duration}ms)`);
  }

  sleep(0.5);
}

export function teardown(data) {
  console.log('=== DB 컷오버 부하 테스트 종료 ===');
  console.log('결과 확인: k6 summary 또는 Grafana 대시보드');
  console.log('');
  console.log('포트폴리오 핵심 지표:');
  console.log('  - migration_read_success: 읽기 가용성 (목표 99%+)');
  console.log('  - migration_write_failed_during_cutover: 컷오버 중 쓰기 실패 수');
  console.log('  - migration_health_success: 헬스체크 가용성');
  console.log('  - migration_read_latency: 컷오버 중 읽기 레이턴시 변화');
}
