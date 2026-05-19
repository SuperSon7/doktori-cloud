/**
 * RabbitMQ 집중 부하 - 카오스 엔지니어링용
 *
 * RabbitMQ 사용 경로:
 *   Producer: RabbitMQNotificationQueue.enqueue()
 *     - 모임 참여 신청 (POST /meetings/{id}/participations)
 *       → 모임장에게 "참여 신청이 들어왔습니다" 알림 enqueue
 *
 *   Consumer: NotificationDeliveryConsumer
 *     - RabbitMQ 큐에서 꺼내 SSE/FCM으로 알림 전달
 *
 * 카오스 시나리오:
 *   RabbitMQ 강제 종료 후 관찰:
 *   - Producer: enqueue 실패 → API가 500을 반환하는지, 아니면 graceful하게 처리하는지
 *   - Consumer: 알림이 쌓이다가 RabbitMQ 복구 후 재처리되는지
 *
 * 실행 전 확인:
 *   export BASE_URL=...
 *   export JWT_TOKENS=token1,token2,...    (멀티 유저 토큰)
 *   export TEST_MEETING_IDS=id1,id2,...    (참여 가능한 모임 ID 목록)
 *
 * 주의: 모임 참여 신청이 실제로 생성됨. 테스트 후 정리 필요.
 */
import { group, check, sleep } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';
import { config } from '../config.js';
import {
  apiGet, checkResponse, thinkTime,
  fetchMultiTokens, pickToken,
  apiGetWithToken, apiPostWithToken, randomInt, randomItem, extractData,
} from '../helpers.js';

const participationDuration = new Trend('rmq_participation_duration', true);
const notificationReadDuration = new Trend('rmq_notification_read_duration', true);
const participationSuccess = new Counter('rmq_participation_success');
const participationErrors = new Counter('rmq_participation_errors');
const notificationDeliveryRate = new Rate('rmq_notification_delivery_rate');

export const options = {
  scenarios: {
    participation_trigger: {
      // 모임 참여 신청 → RabbitMQ enqueue 집중
      executor: 'ramping-vus',
      startVUs: 5,
      stages: [
        { duration: '2m', target: 30 },
        { duration: '5m', target: 60 },
        { duration: '2m', target: 30 },
        { duration: '1m', target: 0 },
      ],
      exec: 'triggerParticipation',
    },
    notification_observe: {
      // 알림 수신 확인 — Consumer 쪽 처리 관찰
      executor: 'constant-vus',
      vus: 10,
      duration: '10m',
      exec: 'observeNotification',
    },
  },
  thresholds: {
    rmq_participation_duration: ['p(95)<2000'],
    rmq_notification_read_duration: ['p(95)<500'],
    rmq_notification_delivery_rate: ['rate>0.5'],  // 알림이 절반 이상 전달되어야 함
    http_req_failed: ['rate<0.1'],
  },
};

const MEETING_IDS = (__ENV.TEST_MEETING_IDS || __ENV.TEST_MEETING_ID || config.testData.meetingId)
  .toString().split(',').map(Number);

export function setup() {
  const tokens = fetchMultiTokens();
  if (tokens.length === 0) {
    console.error('JWT_TOKENS 환경변수에 쉼표 구분 토큰 목록이 필요합니다.');
  }
  return { tokens };
}

// 모임 참여 신청 — RabbitMQ producer 경로 집중 호출
export function triggerParticipation(data) {
  const token = pickToken(data.tokens);
  if (!token) return;

  // 랜덤 모임에 참여 신청 (이미 참여 중이면 409, 정원 초과면 409)
  const meetingId = randomItem(MEETING_IDS);

  group('모임 참여 신청 (RabbitMQ enqueue)', function () {
    // 참여 신청 전 모임 상태 확인
    const detailRes = apiGet(`/meetings/${meetingId}`);
    if (detailRes.status !== 200) return;

    thinkTime(1, 2);

    const start = Date.now();
    const res = apiPostWithToken(`/meetings/${meetingId}/participations`, {}, token);
    participationDuration.add(Date.now() - start);

    // 200/201: 신청 성공 (→ RabbitMQ enqueue 발생)
    // 409: 이미 신청했거나 정원 초과 (정상 비즈니스 에러)
    const ok = res.status === 200 || res.status === 201 || res.status === 409;
    if (res.status === 200 || res.status === 201) participationSuccess.add(1);
    if (!ok) participationErrors.add(1);

    check(res, {
      'participation 200/201/409': (r) => [200, 201, 409].includes(r.status),
    });
  });

  sleep(randomInt(3, 8));
}

// 알림 수신 확인 — RabbitMQ consumer가 처리한 결과를 읽기
export function observeNotification(data) {
  const token = pickToken(data.tokens);
  if (!token) return;

  group('알림 수신 확인', function () {
    // 읽지 않은 알림 수 확인
    const unreadStart = Date.now();
    const unreadRes = apiGetWithToken('/notifications/unread', token);
    notificationReadDuration.add(Date.now() - unreadStart);

    const hasUnread = unreadRes.status === 200 && (() => {
      try {
        const body = unreadRes.json();
        const count = body?.data?.count ?? body?.data?.unreadCount ?? 0;
        return count > 0;
      } catch { return false; }
    })();

    // 알림 목록에서 최근 수신 확인
    const listRes = apiGetWithToken('/notifications', token);
    const listData = extractData(listRes);
    const recentNotifications = listData?.notifications ?? listData?.items ?? [];

    // 최근 1분 내 알림이 있으면 consumer 정상 동작
    const now = Date.now();
    const hasRecentNotification = recentNotifications.some(n => {
      try {
        return now - new Date(n.createdAt).getTime() < 60_000;
      } catch { return false; }
    });

    notificationDeliveryRate.add(hasRecentNotification || hasUnread ? 1 : 0);

    check(listRes, { 'notification list 200': (r) => r.status === 200 });
  });

  sleep(randomInt(5, 15));
}
