/**
 * MongoDB 집중 부하 - 카오스 엔지니어링용
 *
 * MongoDB 사용 경로:
 *   1. 채팅 메시지 조회 (MessageRepository) — GET /chat-rooms/{roomId}/messages
 *   2. 행동 로그 배치 저장 (UserBehaviorLogRepository) — POST /analytics/behavior-logs
 *
 * 카오스 시나리오:
 *   MongoDB 강제 종료 후 각 경로의 실패 관찰
 *   - 채팅 메시지 히스토리 조회 실패
 *   - 행동 로그 저장 실패 (→ API 전체가 실패하는지 graceful degradation 하는지)
 *
 * 실행 전 확인:
 *   export BASE_URL=...
 *   export JWT_TOKEN=...
 *   export TEST_ROOM_IDS=roomId1,roomId2,roomId3   (메시지가 있는 채팅방 ID 목록)
 *   export TEST_MEETING_IDS=id1,id2,id3             (행동 로그용 모임 ID 목록)
 */
import { group, check, sleep } from 'k6';
import { Trend, Counter } from 'k6/metrics';
import { config } from '../config.js';
import {
  apiPost, checkResponse, thinkTime,
  initAuth, fetchMultiTokens, pickToken,
  apiGetWithToken, randomInt, randomItem,
} from '../helpers.js';

const messageReadDuration = new Trend('mongo_message_read_duration', true);
const behaviorLogDuration = new Trend('mongo_behavior_log_duration', true);
const messageReadErrors = new Counter('mongo_message_read_errors');
const behaviorLogErrors = new Counter('mongo_behavior_log_errors');

export const options = {
  scenarios: {
    message_read: {
      // 채팅 메시지 히스토리 읽기 집중
      executor: 'ramping-vus',
      startVUs: 10,
      stages: [
        { duration: '2m', target: 60 },
        { duration: '5m', target: 100 },
        { duration: '2m', target: 60 },
        { duration: '1m', target: 0 },
      ],
      exec: 'stressMessageRead',
    },
    behavior_log_write: {
      // 행동 로그 배치 쓰기 집중
      executor: 'ramping-vus',
      startVUs: 5,
      stages: [
        { duration: '2m', target: 30 },
        { duration: '5m', target: 50 },
        { duration: '2m', target: 30 },
        { duration: '1m', target: 0 },
      ],
      exec: 'stressBehaviorLog',
    },
  },
  thresholds: {
    mongo_message_read_duration: ['p(95)<1000'],
    mongo_behavior_log_duration: ['p(95)<2000'],
    http_req_failed: ['rate<0.1'],
  },
};

const ROOM_IDS = (__ENV.TEST_ROOM_IDS || '1,2,3').split(',').map(Number);
const MEETING_IDS = (__ENV.TEST_MEETING_IDS || __ENV.TEST_MEETING_ID || config.testData.meetingId)
  .toString().split(',').map(Number);

export function setup() {
  const hasAuth = initAuth();
  const tokens = fetchMultiTokens();
  return { hasAuth, tokens };
}

// 채팅 메시지 히스토리 조회 — MongoDB MessageRepository 직접 호출
export function stressMessageRead(data) {
  if (!data.hasAuth) return;

  const token = data.tokens.length > 0 ? pickToken(data.tokens) : null;
  if (!token) return;

  const roomId = randomItem(ROOM_IDS);

  group('채팅 메시지 히스토리 조회', function () {
    const start = Date.now();
    const res = apiGetWithToken(`/chat-rooms/${roomId}/messages?size=50`, token);
    messageReadDuration.add(Date.now() - start);

    if (res.status !== 200) messageReadErrors.add(1);
    check(res, { 'messages 200': (r) => r.status === 200 });
  });

  sleep(randomInt(1, 3) * 0.1);
}

// 행동 로그 배치 저장 — MongoDB UserBehaviorLogRepository 직접 호출
export function stressBehaviorLog(data) {
  if (!data.hasAuth) return;

  const meetingIds = MEETING_IDS.slice(0, randomInt(1, Math.min(5, MEETING_IDS.length)));
  const sessionId = `chaos-${__VU}-${__ITER}-${Date.now()}`;

  const payload = {
    sessionId,
    sentAt: new Date().toISOString(),
    items: meetingIds.map(meetingId => ({
      meetingId,
      impressionCount: randomInt(1, 10),
      detailClickCount: randomInt(0, 3),
      detailDwellTimeMs: randomInt(500, 30000),
    })),
  };

  group('행동 로그 배치 저장', function () {
    const start = Date.now();
    const res = apiPost('/analytics/behavior-logs', payload, true);
    behaviorLogDuration.add(Date.now() - start);

    if (res.status !== 200) behaviorLogErrors.add(1);
    check(res, { 'behavior log 200': (r) => r.status === 200 });
  });

  sleep(randomInt(5, 15) * 0.1);
}
