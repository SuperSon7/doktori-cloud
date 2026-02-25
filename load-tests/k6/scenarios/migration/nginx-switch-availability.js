/**
 * Nginx 라우팅 전환 가용성 테스트
 *
 * 목적: Nginx upstream 전환 (구 서버 → 새 VPC) 시 서비스 무중단을 검증한다.
 *       nginx -s reload의 graceful 동작과 keep-alive 연결 유지를 확인한다.
 *
 * 대상 Unit: Unit 10 (Nginx 라우팅 전환)
 *
 * 시나리오:
 *   Phase 1 (0~3분):  baseline — 구 upstream 응답 확인
 *   Phase 2 (3~5분):  switch — nginx upstream 변경 + reload
 *   Phase 3 (5~10분): verify — 새 upstream 안정성
 *
 * 관찰 포인트:
 *   - nginx -s reload 시 기존 연결 처리 방식
 *   - reload 전후 응답 끊김 여부
 *   - upstream 변경 시 X-Server-ID 헤더 변화 (서버 식별)
 *
 * 포트폴리오 핵심:
 *   "Nginx reload 기반 무중단 라우팅 전환, 에러 0건"
 *
 * 실행:
 *   k6 run --env BASE_URL=https://doktori.kr/api \
 *          --env JWT_TOKEN=<토큰> \
 *          nginx-switch-availability.js
 */

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter, Gauge } from 'k6/metrics';
import { config } from '../../config.js';
import { getHeaders, initAuth, randomItem, thinkTime } from '../../helpers.js';

// ── 메트릭 ──
const nginxAvailability = new Rate('nginx_availability');
const nginxLatency = new Trend('nginx_latency', true);
const nginxErrors = new Counter('nginx_errors');
const nginxTimeouts = new Counter('nginx_timeouts');

// 서버 전환 감지
const serverSwitchDetected = new Counter('nginx_server_switch_detected');
const connectionResets = new Counter('nginx_connection_resets');

// Phase별
const baselineSuccess = new Rate('nginx_baseline_success');
const switchPhaseSuccess = new Rate('nginx_switch_phase_success');
const verifySuccess = new Rate('nginx_verify_success');

// 연속 실패 추적
let consecutiveErrors = 0;
let maxConsecutiveErrors = 0;

export const options = {
  scenarios: {
    // 고빈도 요청 (전환 순간 포착)
    rapid_requests: {
      executor: 'constant-vus',
      vus: 15,
      duration: '10m',
      exec: 'rapidRequests',
    },
    // keep-alive 장기 연결 (reload 시 끊김 관찰)
    keepalive_connections: {
      executor: 'constant-vus',
      vus: 3,
      duration: '10m',
      exec: 'keepaliveConnection',
    },
    // 혼합 트래픽 (실제 사용자 패턴)
    mixed_traffic: {
      executor: 'constant-vus',
      vus: 5,
      duration: '10m',
      exec: 'mixedTraffic',
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
    'nginx_availability': ['rate>0.999'],
    'nginx_latency': ['p(95)<1000'],
    'nginx_errors': ['count<5'],
  },
};

let testStartTime = 0;
let lastServerId = '';

export function setup() {
  initAuth();
  testStartTime = Date.now();

  console.log('=== Nginx 라우팅 전환 가용성 테스트 시작 ===');
  console.log(`대상: ${config.baseUrl}`);
  console.log('');
  console.log('Phase 1 (0~3분):  baseline 수집');
  console.log('Phase 2 (3~5분):  이 구간에서 nginx upstream을 변경하세요');
  console.log('  sudo vi /etc/nginx/conf.d/upstream.conf');
  console.log('  sudo nginx -t && sudo nginx -s reload');
  console.log('Phase 3 (5~10분): 전환 후 안정성 확인');
  console.log('=============================================');
}

function getPhase() {
  const elapsed = (Date.now() - testStartTime) / 1000;
  if (elapsed < 180) return 'baseline';
  if (elapsed < 300) return 'switch';
  return 'verify';
}

// ── 고빈도 요청 (전환 순간 포착) ──
export function rapidRequests() {
  const timestamp = new Date().toISOString();
  const phase = getPhase();

  const res = http.get(`${config.baseUrl}/meetings?size=5`, {
    headers: getHeaders(false),
    tags: { name: 'GET /meetings (rapid)', phase },
    timeout: '5s',
  });

  const ok = res.status === 200;
  nginxAvailability.add(ok);

  if (ok) {
    nginxLatency.add(res.timings.duration);
    consecutiveErrors = 0;

    // 서버 전환 감지 (응답 헤더에서 서버 ID 확인)
    const serverId = res.headers['X-Server-Id'] ||
                     res.headers['X-Upstream'] ||
                     res.headers['Server'] || '';
    if (lastServerId && serverId && serverId !== lastServerId) {
      serverSwitchDetected.add(1);
      console.log(
        `[${timestamp}] [${phase}] SERVER SWITCH: ${lastServerId} → ${serverId}`
      );
    }
    lastServerId = serverId;
  } else {
    nginxErrors.add(1);
    consecutiveErrors++;
    if (consecutiveErrors > maxConsecutiveErrors) {
      maxConsecutiveErrors = consecutiveErrors;
    }

    if (res.status === 0) {
      nginxTimeouts.add(1);
      connectionResets.add(1);
      console.log(`[${timestamp}] [${phase}] CONNECTION RESET/TIMEOUT`);
    } else {
      console.log(
        `[${timestamp}] [${phase}] FAIL: ${res.status} ` +
        `(${res.timings.duration}ms) consecutive=${consecutiveErrors}`
      );
    }
  }

  // Phase별 메트릭
  if (phase === 'baseline') baselineSuccess.add(ok);
  else if (phase === 'switch') switchPhaseSuccess.add(ok);
  else verifySuccess.add(ok);

  sleep(0.2); // 200ms 간격 (초당 5회)
}

// ── Keep-alive 장기 연결 ──
export function keepaliveConnection() {
  const timestamp = new Date().toISOString();
  const phase = getPhase();

  // 같은 세션에서 연속 요청 (keep-alive 연결 재사용)
  for (let i = 0; i < 5; i++) {
    const res = http.get(`${config.baseUrl}/health`, {
      tags: { name: 'GET /health (keepalive)', phase },
      timeout: '5s',
    });

    const ok = res.status === 200;
    nginxAvailability.add(ok);

    if (!ok) {
      console.log(
        `[${timestamp}] [${phase}] KEEPALIVE FAIL (${i+1}/5): ${res.status} ` +
        `→ nginx reload 시 기존 연결 끊김 가능`
      );
    }

    sleep(0.5);
  }

  sleep(2);
}

// ── 혼합 트래픽 ──
export function mixedTraffic() {
  const timestamp = new Date().toISOString();
  const phase = getPhase();

  const requests = [
    () => http.get(`${config.baseUrl}/meetings?size=10`, {
      headers: getHeaders(false),
      tags: { name: 'GET /meetings (mixed)', phase },
      timeout: '10s',
    }),
    () => http.get(
      `${config.baseUrl}/meetings/search?keyword=${encodeURIComponent(randomItem(config.searchKeywords))}&size=5`,
      {
        headers: getHeaders(false),
        tags: { name: 'GET /meetings/search (mixed)', phase },
        timeout: '10s',
      }
    ),
    () => http.get(`${config.baseUrl}/recommendations/meetings`, {
      headers: getHeaders(false),
      tags: { name: 'GET /recommendations (mixed)', phase },
      timeout: '10s',
    }),
    () => http.get(`${config.baseUrl}/meetings/${config.testData.meetingId}`, {
      headers: getHeaders(false),
      tags: { name: 'GET /meetings/:id (mixed)', phase },
      timeout: '10s',
    }),
  ];

  const res = randomItem(requests)();
  const ok = res.status === 200;
  nginxAvailability.add(ok);

  if (ok) {
    nginxLatency.add(res.timings.duration);
  } else {
    nginxErrors.add(1);
    console.log(`[${timestamp}] [${phase}] MIXED FAIL: ${res.status}`);
  }

  thinkTime(1, 3);
}

// ── 1초 간격 정밀 모니터링 ──
export function preciseMonitor() {
  const timestamp = new Date().toISOString();
  const phase = getPhase();
  const elapsed = Math.floor((Date.now() - testStartTime) / 1000);

  const healthRes = http.get(`${config.baseUrl}/health`, {
    tags: { name: 'GET /health (monitor)', phase },
    timeout: '3s',
  });

  const dbRes = http.get(`${config.baseUrl}/meetings?size=1`, {
    headers: getHeaders(false),
    tags: { name: 'GET /meetings (monitor)', phase },
    timeout: '5s',
  });

  const hOk = healthRes.status === 200;
  const dOk = dbRes.status === 200;

  // 전환 구간(3~5분)에서만 상세 로그
  if (phase === 'switch' || (!hOk || !dOk)) {
    console.log(
      `[${timestamp}] [${elapsed}s] health=${hOk ? 'OK' : 'FAIL'} ` +
      `db=${dOk ? 'OK' : 'FAIL'} ` +
      `h_latency=${healthRes.timings.duration}ms ` +
      `d_latency=${dbRes.timings.duration}ms`
    );
  }

  sleep(1);
}

export function teardown(data) {
  console.log('=== Nginx 라우팅 전환 가용성 테스트 종료 ===');
  console.log('');
  console.log('포트폴리오 핵심 지표:');
  console.log('  - nginx_availability: 전체 가용성 (목표 99.9%+)');
  console.log('  - nginx_baseline_success: 전환 전 baseline 성공률');
  console.log('  - nginx_switch_phase_success: 전환 중 성공률 (핵심!)');
  console.log('  - nginx_verify_success: 전환 후 안정 성공률');
  console.log('  - nginx_errors: 총 에러 수 (목표 0~5건)');
  console.log('  - nginx_timeouts: 타임아웃 수');
  console.log('  - nginx_connection_resets: 연결 리셋 수');
  console.log('  - nginx_server_switch_detected: 서버 전환 감지 횟수');
  console.log(`  - 최대 연속 에러: ${maxConsecutiveErrors}건`);
  console.log('');
  console.log('Phase별 비교:');
  console.log('  baseline vs switch → nginx reload 영향 측정');
  console.log('  switch vs verify → 전환 후 안정화 확인');
}
