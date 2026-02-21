/**
 * DNS 전환 가용성 테스트
 *
 * 목적: Route 53 DNS를 새 VPC로 변경할 때 사용자 체감 무중단을 검증한다.
 *
 * 원리:
 *   DNS 전환 시 양쪽 서버(Lightsail + 새 VPC)가 같은 RDS를 바라보므로,
 *   어느 쪽으로 요청이 가든 동일한 결과를 반환해야 한다.
 *   이 테스트는 그것을 증명한다.
 *
 * 시나리오:
 *   1. DNS 변경 전: 모든 요청 정상
 *   2. DNS 변경 직후: 일부 요청은 구 서버, 일부는 새 서버 → 모두 정상이어야 함
 *   3. DNS 전파 완료: 모든 요청이 새 서버로 → 정상
 *
 * 포트폴리오 핵심:
 *   "DNS 전환 전후로 에러율 0%, 레이턴시 변동 없음"을 정량적으로 증명
 *
 * 실행:
 *   # DNS 변경 5분 전에 시작, 변경 후 25분간 관찰 (총 30분)
 *   k6 run --env BASE_URL=https://doktori.kr/api \
 *          --env JWT_TOKEN=<토큰> \
 *          dns-switch-availability.js
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';
import { config } from '../../config.js';
import { getHeaders, initAuth, randomItem } from '../../helpers.js';

// ── 메트릭 ──
const availability = new Rate('dns_availability');
const readLatency = new Trend('dns_read_latency', true);
const writeLatency = new Trend('dns_write_latency', true);
const healthLatency = new Trend('dns_health_latency', true);
const totalRequests = new Counter('dns_total_requests');
const failedRequests = new Counter('dns_failed_requests');
const serverHeader = new Counter('dns_server_responses');

export const options = {
  scenarios: {
    // 실제 사용자 패턴: 지속적인 혼합 트래픽
    mixed_traffic: {
      executor: 'constant-vus',
      vus: 20,
      duration: '30m',
      exec: 'mixedUserFlow',
    },
    // 헬스체크: 0.5초 간격으로 빈틈없이 확인
    continuous_health: {
      executor: 'constant-vus',
      vus: 2,
      duration: '30m',
      exec: 'continuousHealth',
    },
  },

  thresholds: {
    // DNS 전환 중에도 99.9% 가용성 (무중단 증명)
    'dns_availability': ['rate>0.999'],
    // 읽기 P95 500ms 이내
    'dns_read_latency': ['p(95)<500'],
    // 실패 요청 0건에 가까워야 함
    'dns_failed_requests': ['count<5'],
  },
};

export function setup() {
  initAuth();
  console.log('=== DNS 전환 가용성 테스트 시작 ===');
  console.log(`대상: ${config.baseUrl}`);
  console.log('5분 후 DNS 변경을 시작하세요.');
  console.log('총 30분간 관찰합니다.');
  console.log('==================================');
}

export function mixedUserFlow() {
  const timestamp = new Date().toISOString();

  // ── 1. 모임 목록 (읽기, Public) ──
  const listRes = http.get(`${config.baseUrl}/meetings?size=10`, {
    headers: getHeaders(false),
    tags: { name: 'GET /meetings', type: 'read' },
    timeout: '10s',
  });
  totalRequests.add(1);
  const listOk = listRes.status === 200;
  availability.add(listOk);
  readLatency.add(listRes.timings.duration);
  if (!listOk) {
    failedRequests.add(1);
    console.log(`[${timestamp}] FAIL GET /meetings: ${listRes.status} ${listRes.timings.duration}ms`);
  }

  sleep(0.3);

  // ── 2. 모임 상세 (읽기, Public) ──
  const detailRes = http.get(`${config.baseUrl}/meetings/${config.testData.meetingId}`, {
    headers: getHeaders(false),
    tags: { name: 'GET /meetings/:id', type: 'read' },
    timeout: '10s',
  });
  totalRequests.add(1);
  const detailOk = detailRes.status === 200;
  availability.add(detailOk);
  readLatency.add(detailRes.timings.duration);
  if (!detailOk) {
    failedRequests.add(1);
    console.log(`[${timestamp}] FAIL GET /meetings/:id: ${detailRes.status}`);
  }

  sleep(0.3);

  // ── 3. 검색 (읽기, Public) ──
  const keyword = randomItem(config.searchKeywords);
  const searchRes = http.get(
    `${config.baseUrl}/meetings/search?keyword=${encodeURIComponent(keyword)}&size=5`,
    {
      headers: getHeaders(false),
      tags: { name: 'GET /meetings/search', type: 'read' },
      timeout: '10s',
    }
  );
  totalRequests.add(1);
  availability.add(searchRes.status === 200);
  readLatency.add(searchRes.timings.duration);
  if (searchRes.status !== 200) failedRequests.add(1);

  sleep(0.3);

  // ── 4. 내 정보 조회 (읽기, 인증 필요) ──
  const meRes = http.get(`${config.baseUrl}/users/me`, {
    headers: getHeaders(true),
    tags: { name: 'GET /users/me', type: 'read' },
    timeout: '10s',
  });
  totalRequests.add(1);
  // 401은 토큰 문제이지 서버 문제가 아니므로 구분
  const meOk = meRes.status === 200 || meRes.status === 401;
  availability.add(meOk);
  if (meRes.status === 200) readLatency.add(meRes.timings.duration);
  if (!meOk) {
    failedRequests.add(1);
    console.log(`[${timestamp}] FAIL GET /users/me: ${meRes.status}`);
  }

  sleep(0.3);

  // ── 5. 알림 읽음 처리 (쓰기, 인증 필요) ──
  const writeRes = http.put(`${config.baseUrl}/notifications`, null, {
    headers: getHeaders(true),
    tags: { name: 'PUT /notifications', type: 'write' },
    timeout: '10s',
  });
  totalRequests.add(1);
  const writeOk = writeRes.status >= 200 && writeRes.status < 300;
  availability.add(writeOk || writeRes.status === 401);
  if (writeOk) writeLatency.add(writeRes.timings.duration);
  if (!writeOk && writeRes.status !== 401) {
    failedRequests.add(1);
    console.log(`[${timestamp}] FAIL PUT /notifications: ${writeRes.status}`);
  }

  sleep(randomItem([1, 1.5, 2, 2.5, 3]));
}

export function continuousHealth() {
  const timestamp = new Date().toISOString();

  const res = http.get(`${config.baseUrl}/health`, {
    tags: { name: 'GET /health', type: 'health' },
    timeout: '5s',
  });

  totalRequests.add(1);
  const ok = res.status === 200;
  availability.add(ok);
  healthLatency.add(res.timings.duration);

  if (!ok) {
    failedRequests.add(1);
    console.log(`[${timestamp}] HEALTH FAIL: ${res.status} (${res.timings.duration}ms)`);
  }

  sleep(0.5);
}

export function teardown(data) {
  console.log('=== DNS 전환 가용성 테스트 종료 ===');
  console.log('');
  console.log('포트폴리오 핵심 지표:');
  console.log('  - dns_availability: 전체 가용성 (목표 99.9%+)');
  console.log('  - dns_failed_requests: 실패 요청 수 (목표 0건)');
  console.log('  - dns_read_latency / dns_write_latency: 전환 전후 비교');
  console.log('  - 시간축 그래프에서 DNS 전환 시점 전후 변동 없음 = 무중단 증명');
}
