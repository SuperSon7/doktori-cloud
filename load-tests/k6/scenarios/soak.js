/**
 * Soak 테스트 (내구성 테스트)
 * 목적: 장시간 안정성 검증 (메모리 누수, 커넥션 누수, SSE 연결 누수 등)
 * 지속 시간: 1시간
 */
import { group, sleep } from 'k6';
import { Trend, Counter } from 'k6/metrics';
import { config, loadStages } from '../config.js';
import {
  apiGet, extractData, randomItem, randomInt, thinkTime, initAuth
} from '../helpers.js';

export function setup() {
  const hasAuth = initAuth();
  return { hasAuth };
}

// 장기 모니터링용 커스텀 메트릭
const memoryTrend = new Trend('estimated_memory_usage');
const connectionErrors = new Counter('connection_errors');
const timeoutErrors = new Counter('timeout_errors');

export const options = {
  stages: loadStages.soak,
  thresholds: {
    http_req_duration: ['p(95)<500', 'p(99)<1500'],
    http_req_failed: ['rate<0.01'],
    connection_errors: ['count<10'],
    timeout_errors: ['count<10'],
  },
};

export default function (data) {
  const iteration = __ITER;

  // 10분마다 상태 로깅
  if (iteration % 600 === 0) {
    console.log(`[Soak] Iteration ${iteration}, VU ${__VU}`);
  }

  group('Soak 테스트 - 일반 흐름', function () {
    // 1. 공개 API
    const healthRes = apiGet('/health');
    if (healthRes.status === 0) {
      connectionErrors.add(1);
    }
    if (healthRes.timings.duration > 5000) {
      timeoutErrors.add(1);
    }

    thinkTime(2, 5);

    // 2. 모임 목록 + 상세
    const listRes = apiGet('/meetings?size=10');
    const data = extractData(listRes);
    if (data && data.items && data.items.length > 0) {
      thinkTime(1, 3);
      const meetingId = randomItem(data.items).meetingId;
      apiGet(`/meetings/${meetingId}`);
    }

    thinkTime(2, 5);

    // 3. 검색
    const keyword = randomItem(config.searchKeywords);
    apiGet(`/meetings/search?keyword=${encodeURIComponent(keyword)}&size=10`);

    thinkTime(2, 5);

    // 4. 인증 API (토큰 있을 경우)
    if (data.hasAuth) {
      apiGet('/users/me', {}, true);
      thinkTime(2, 5);

      apiGet('/users/me/meetings?status=ACTIVE&size=10', {}, true);
      thinkTime(2, 5);

      apiGet('/notifications/unread', {}, true);
    }
  });

  // VU당 1분에 약 3~5회 반복 (낮은 부하 유지)
  sleep(randomInt(10, 20));
}

export function handleSummary(data) {
  console.log('\n=== Soak 테스트 요약 ===');
  console.log(`총 요청 수: ${data.metrics.http_reqs.values.count}`);
  console.log(`평균 응답시간: ${data.metrics.http_req_duration.values.avg.toFixed(2)}ms`);
  console.log(`P95 응답시간: ${data.metrics.http_req_duration.values['p(95)'].toFixed(2)}ms`);
  console.log(`에러율: ${(data.metrics.http_req_failed.values.rate * 100).toFixed(2)}%`);
  console.log(`연결 에러: ${data.metrics.connection_errors?.values.count || 0}`);
  console.log(`타임아웃 에러: ${data.metrics.timeout_errors?.values.count || 0}`);

  return {};
}
