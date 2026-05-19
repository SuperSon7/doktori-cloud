/**
 * Redis 집중 부하 - 카오스 엔지니어링용
 *
 * Redis 사용 경로:
 *   1. 모임 상세 캐시 (MeetingCacheService) — GET /meetings/{id} 반복
 *   2. SSE 연결 상태 + pub/sub (SseEmitterService) — /notifications/subscribe
 *   3. 채팅 메시지 Redis pub/sub (ChatRoomRedisPublisher) — WS 메시지 브로드캐스트
 *   4. Refresh Token (RefreshTokenRedisRepository) — POST /auth/tokens
 *
 * 카오스 시나리오:
 *   Redis 강제 종료 후 각 경로의 실패/fallback 관찰
 *   - 캐시 미스 → DB 직접 폭격 (RDS 과부하)
 *   - SSE 연결 실패 / 알림 전달 불가
 *   - 채팅 메시지 브로드캐스트 실패
 *
 * 실행 전 확인:
 *   export BASE_URL=...
 *   export JWT_TOKEN=... (또는 REFRESH_TOKEN)
 *   export TEST_MEETING_ID=...   (캐시 테스트용 실존 모임 ID)
 *   export TEST_ROOM_ID=...      (채팅방 ID)
 */
import http from 'k6/http';
import { group, check, sleep } from 'k6';
import { Trend, Counter, Rate, Gauge } from 'k6/metrics';
import { config } from '../config.js';
import {
  apiGet, checkResponse, thinkTime,
  initAuth, fetchMultiTokens, pickToken,
  apiGetWithToken, randomInt, randomItem,
} from '../helpers.js';

const meetingCacheDuration = new Trend('redis_meeting_cache_duration', true);
const sseConnectDuration = new Trend('redis_sse_connect_duration', true);
const cacheHitRate = new Rate('redis_cache_hit_rate');
const sseActiveConns = new Gauge('redis_sse_active_connections');
const meetingCacheErrors = new Counter('redis_meeting_cache_errors');
const sseErrors = new Counter('redis_sse_errors');

export const options = {
  scenarios: {
    cache_stress: {
      // 모임 상세 캐시 집중 호출
      executor: 'constant-vus',
      vus: 50,
      duration: '10m',
      exec: 'stressMeetingCache',
    },
    sse_stress: {
      // SSE 연결 유지 (Redis pub/sub 채널 열어두기)
      executor: 'constant-vus',
      vus: 30,
      duration: '10m',
      exec: 'stressSseConnection',
      startTime: '10s',
    },
  },
  thresholds: {
    redis_meeting_cache_duration: ['p(95)<500'],
    redis_sse_connect_duration: ['p(95)<1000'],
    http_req_failed: ['rate<0.1'],
  },
};

const MEETING_IDS = (__ENV.TEST_MEETING_IDS || __ENV.TEST_MEETING_ID || config.testData.meetingId)
  .toString().split(',').map(Number);

export function setup() {
  const hasAuth = initAuth();
  const tokens = fetchMultiTokens();
  return { hasAuth, tokens };
}

// 모임 상세 캐시 집중 호출 — 동일 ID 반복으로 캐시 HIT, 가끔 다른 ID로 캐시 MISS 유도
export function stressMeetingCache(data) {
  // 80% 동일 ID (캐시 HIT 경로), 20% 랜덤 ID (캐시 MISS → DB)
  const useFixed = randomInt(1, 10) <= 8;
  const meetingId = useFixed
    ? MEETING_IDS[0]
    : MEETING_IDS[randomInt(0, MEETING_IDS.length - 1)];

  group('모임 상세 캐시', function () {
    const start = Date.now();
    const res = apiGet(`/meetings/${meetingId}`);
    const duration = Date.now() - start;
    meetingCacheDuration.add(duration);

    // 50ms 이하면 캐시 HIT 추정
    cacheHitRate.add(duration < 50 ? 1 : 0);

    if (res.status !== 200) {
      meetingCacheErrors.add(1);
    }
    check(res, { 'meeting cache 200': (r) => r.status === 200 });
  });

  sleep(0.2);
}

// SSE 연결 유지 — Redis pub/sub 채널을 지속적으로 열어둠
export function stressSseConnection(data) {
  if (!data.hasAuth) return;

  const token = data.tokens.length > 0 ? pickToken(data.tokens) : null;
  if (!token) return;

  group('SSE 연결', function () {
    const start = Date.now();
    const res = http.get(`${config.baseUrl}/notifications/subscribe`, {
      headers: {
        'Authorization': `Bearer ${token}`,
        'Accept': 'text/event-stream',
        'Cache-Control': 'no-cache',
      },
      timeout: '30s',
      tags: { name: '/notifications/subscribe' },
    });
    sseConnectDuration.add(Date.now() - start);
    sseActiveConns.add(1);

    const ok = res.status === 200 || res.status === 204;
    if (!ok) sseErrors.add(1);
    check(res, { 'SSE connect 200': () => ok });

    sseActiveConns.add(-1);
  });

  sleep(randomInt(5, 15));
}
