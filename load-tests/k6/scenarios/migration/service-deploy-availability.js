/**
 * 서비스 배포(Blue/Green) 가용성 테스트
 *
 * 목적: 새 VPC에서 컨테이너 배포 시 서비스 가용성을 측정한다.
 *       구 서버에서 새 서버로 전환하는 과정에서의 영향을 관찰한다.
 *
 * 대상 Unit: Unit 9 (서비스 배포)
 *
 * 시나리오:
 *   Phase 1 (0~3분):  baseline — 구 서버 정상 응답 확인
 *   Phase 2 (3~7분):  deploy — 새 서버에 컨테이너 배포 (Blue/Green)
 *   Phase 3 (7~10분): verify — 배포 후 안정성 확인
 *
 * 관찰 포인트:
 *   - 구 서버에서 새 서버로 전환 시 응답 중단 여부
 *   - 새 컨테이너 기동 시간 (cold start)
 *   - HikariCP 초기 커넥션 풀 생성 시간
 *
 * 포트폴리오 핵심:
 *   "Blue/Green 배포 전환 중 가용성 99.9%+, cold start X초"
 *
 * 실행:
 *   k6 run --env BASE_URL=https://doktori.kr/api \
 *          --env JWT_TOKEN=<토큰> \
 *          service-deploy-availability.js
 */

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';
import { config } from '../../config.js';
import { getHeaders, initAuth, randomItem, thinkTime } from '../../helpers.js';

// ── 메트릭 ──
const deployAvailability = new Rate('deploy_availability');
const deployLatency = new Trend('deploy_latency', true);
const deployErrors = new Counter('deploy_errors');
const deploySlowResponses = new Counter('deploy_slow_responses');

// Phase별 구분
const baselineSuccess = new Rate('deploy_baseline_success');
const deployPhaseSuccess = new Rate('deploy_phase_success');
const verifySuccess = new Rate('deploy_verify_success');

// 컨테이너 기동 감지
const coldStartDetected = new Counter('deploy_cold_start_detected');

export const options = {
  scenarios: {
    // 지속적 API 호출 (가용성 측정)
    continuous_check: {
      executor: 'constant-vus',
      vus: 10,
      duration: '10m',
      exec: 'continuousCheck',
    },
    // 헬스체크 (1초 간격)
    health_monitor: {
      executor: 'constant-vus',
      vus: 1,
      duration: '10m',
      exec: 'healthMonitor',
    },
    // DB 의존 요청 (커넥션 풀 cold start 감지)
    db_request: {
      executor: 'constant-vus',
      vus: 5,
      duration: '10m',
      exec: 'dbRequest',
    },
  },

  thresholds: {
    'deploy_availability': ['rate>0.999'],
    'deploy_latency': ['p(95)<2000'],
    'deploy_errors': ['count<10'],
  },
};

let testStartTime = 0;

export function setup() {
  initAuth();
  testStartTime = Date.now();

  console.log('=== 서비스 배포 가용성 테스트 시작 ===');
  console.log(`대상: ${config.baseUrl}`);
  console.log('');
  console.log('Phase 1 (0~3분):  baseline 수집');
  console.log('Phase 2 (3~7분):  이 구간에서 컨테이너 배포를 수행하세요');
  console.log('Phase 3 (7~10분): 배포 후 안정성 확인');
  console.log('==========================================');
}

function getPhase() {
  const elapsed = (Date.now() - testStartTime) / 1000;
  if (elapsed < 180) return 'baseline';
  if (elapsed < 420) return 'deploy';
  return 'verify';
}

// ── 지속적 API 호출 ──
export function continuousCheck() {
  const timestamp = new Date().toISOString();
  const phase = getPhase();

  // 다양한 엔드포인트 혼합 요청
  const endpoints = [
    { path: '/meetings?size=5', auth: false },
    { path: '/recommendations/meetings', auth: false },
    { path: `/meetings/${config.testData.meetingId}`, auth: false },
  ];

  const endpoint = randomItem(endpoints);
  const startTime = Date.now();

  const res = http.get(`${config.baseUrl}${endpoint.path}`, {
    headers: getHeaders(endpoint.auth),
    tags: { name: `GET ${endpoint.path.split('?')[0]}`, phase },
    timeout: '10s',
  });

  const elapsed = Date.now() - startTime;
  const ok = res.status === 200;

  deployAvailability.add(ok);
  deployLatency.add(res.timings.duration);

  // Phase별 메트릭
  if (phase === 'baseline') baselineSuccess.add(ok);
  else if (phase === 'deploy') deployPhaseSuccess.add(ok);
  else verifySuccess.add(ok);

  if (!ok) {
    deployErrors.add(1);
    console.log(
      `[${timestamp}] [${phase}] FAIL: ${endpoint.path} → ${res.status} ` +
      `(${res.timings.duration}ms)`
    );
  }

  // Slow response 감지 (cold start 가능성)
  if (ok && res.timings.duration > 3000) {
    deploySlowResponses.add(1);
    coldStartDetected.add(1);
    console.log(
      `[${timestamp}] [${phase}] SLOW: ${endpoint.path} → ${res.timings.duration}ms ` +
      `(cold start 가능성)`
    );
  }

  thinkTime(1, 2);
}

// ── 1초 간격 헬스체크 ──
export function healthMonitor() {
  const timestamp = new Date().toISOString();
  const phase = getPhase();

  const res = http.get(`${config.baseUrl}/health`, {
    tags: { name: 'GET /health', phase },
    timeout: '5s',
  });

  const ok = res.status === 200;
  deployAvailability.add(ok);

  if (!ok) {
    console.log(
      `[${timestamp}] [${phase}] HEALTH FAIL: ${res.status} ` +
      `(${res.timings.duration}ms)`
    );
  }

  sleep(1);
}

// ── DB 의존 요청 (커넥션 풀 상태 관찰) ──
export function dbRequest() {
  const timestamp = new Date().toISOString();
  const phase = getPhase();

  // meetings 목록은 DB JOIN이 필요 → HikariCP 커넥션 사용
  const res = http.get(`${config.baseUrl}/meetings?size=20`, {
    headers: getHeaders(false),
    tags: { name: 'GET /meetings (db)', phase },
    timeout: '10s',
  });

  const ok = res.status === 200;

  if (!ok) {
    console.log(
      `[${timestamp}] [${phase}] DB_REQ FAIL: ${res.status} ` +
      `(${res.timings.duration}ms) → 커넥션 풀 문제 가능`
    );
  }

  // 새 컨테이너의 첫 DB 요청은 느림 (HikariCP 풀 초기화)
  if (ok && res.timings.duration > 5000 && phase === 'deploy') {
    console.log(
      `[${timestamp}] [${phase}] COLD START 감지: ${res.timings.duration}ms ` +
      `(HikariCP 초기 커넥션 생성 중)`
    );
    coldStartDetected.add(1);
  }

  sleep(0.5);
}

export function teardown(data) {
  console.log('=== 서비스 배포 가용성 테스트 종료 ===');
  console.log('');
  console.log('포트폴리오 핵심 지표:');
  console.log('  - deploy_availability: 전체 가용성 (목표 99.9%+)');
  console.log('  - deploy_baseline_success: 배포 전 baseline 성공률');
  console.log('  - deploy_phase_success: 배포 중 성공률 (핵심!)');
  console.log('  - deploy_verify_success: 배포 후 안정 성공률');
  console.log('  - deploy_errors: 총 에러 수');
  console.log('  - deploy_slow_responses: 느린 응답 수 (cold start)');
  console.log('  - deploy_cold_start_detected: cold start 감지 횟수');
  console.log('  - deploy_latency: 응답 시간 분포');
  console.log('');
  console.log('Phase별 비교:');
  console.log('  baseline vs deploy → 배포 중 영향 측정');
  console.log('  deploy vs verify → 배포 후 안정화 확인');
}
