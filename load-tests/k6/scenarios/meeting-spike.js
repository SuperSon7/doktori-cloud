/**
 * 모임 시작 시간 스파이크 시나리오
 *
 * 시뮬레이션:
 *   모임 시작 5분 전 → 참여자들이 동시 접속 → 채팅방 입장 → 토론 시작
 *   "20시 모임" 시나리오: 19:55 접속 시작 → 20:00 토론 시작 → 20:30 종료
 *
 * VU 패턴:
 *   0→200 (1분, 급격한 접속) → 200 유지 (5분, 토론) → 200→0 (1분, 종료)
 *
 * 트래픽 구성 (토론 시간):
 *   - 30%: 채팅방 REST (메시지 조회, 투표 등)
 *   - 30%: 모임/사용자 API (내 모임, 모임 상세)
 *   - 20%: 알림 (실시간 알림 확인)
 *   - 20%: 모임 참여/독후감 (쓰기)
 *
 * 핵심 검증:
 *   - 동시 접속 스파이크에서 HPA 반응 속도
 *   - 토론 중 채팅+API 동시 부하에서 P95 유지 여부
 *   - 가용성 (서비스가 죽지 않는지)
 */
import http from 'k6/http';
import { group, check, sleep } from 'k6';
import { Trend, Counter } from 'k6/metrics';
import { config, thresholds } from '../config.js';
import {
  apiGet, extractData, thinkTime, randomItem, randomInt,
  fetchMultiTokens, pickToken,
  apiGetWithToken, apiPostWithToken, apiPutWithToken,
} from '../helpers.js';

const meetingJoinDuration = new Trend('meeting_join_duration', true);
const chatActionDuration = new Trend('chat_action_duration', true);

export const options = {
  scenarios: {
    meeting_spike: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '1m', target: 200 },   // 급격한 접속 (모임 시작 전)
        { duration: '5m', target: 200 },   // 토론 진행 (sustained)
        { duration: '1m', target: 0 },     // 종료
      ],
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<1000', 'p(99)<2000'],
    http_req_failed: ['rate<0.01'],  // 가용성 중요: 1% 미만
    meeting_join_duration: ['p(95)<1000'],
    chat_action_duration: ['p(95)<1000'],
  },
};

export function setup() {
  const tokens = fetchMultiTokens();
  return { tokens };
}

export default function (data) {
  const token = pickToken(data.tokens);
  const scenario = randomInt(1, 100);

  if (scenario <= 30) {
    // 30%: 채팅방 REST (토론 중 핵심)
    group('채팅방 활동', function () {
      const start = Date.now();
      const listRes = apiGet('/chat-rooms?size=10');
      const listData = extractData(listRes);

      if (token && listData && listData.items && listData.items.length > 0) {
        const roomId = randomItem(listData.items).chatRoomId || randomItem(listData.items).id;
        if (roomId) {
          // 채팅방 상세 조회
          apiGetWithToken(`/chat-rooms/${roomId}`, token);
          thinkTime(1, 2);

          // 채팅방 입장 시도
          apiPostWithToken(`/chat-rooms/${roomId}/members`, {
            position: randomItem(['AGREE', 'DISAGREE']),
          }, token);
        }
      }
      chatActionDuration.add(Date.now() - start);
    });

  } else if (scenario <= 60 && token) {
    // 30%: 모임/사용자 API
    group('모임 확인', function () {
      apiGetWithToken('/users/me', token);
      thinkTime(1, 2);
      apiGetWithToken('/users/me/meetings?status=ACTIVE&size=10', token);
      thinkTime(1, 2);
      apiGetWithToken('/users/me/meetings/today', token);
    });

  } else if (scenario <= 80 && token) {
    // 20%: 알림
    group('알림 확인', function () {
      apiGetWithToken('/notifications/unread', token);
      thinkTime(1, 2);
      const res = apiGetWithToken('/notifications', token);
      const notifData = extractData(res);
      if (notifData && notifData.notifications && notifData.notifications.length > 0) {
        const unread = notifData.notifications.filter(n => !n.isRead);
        if (unread.length > 0) {
          apiPutWithToken(`/notifications/${unread[0].notificationId}`, {}, token);
        }
      }
    });

  } else if (token) {
    // 20%: 모임 참여
    group('모임 참여', function () {
      const start = Date.now();
      const listRes = apiGet('/meetings?size=20');
      const meetingData = extractData(listRes);

      if (meetingData && meetingData.items && meetingData.items.length > 0) {
        const meetingId = randomItem(meetingData.items).meetingId;
        apiPostWithToken(`/meetings/${meetingId}/participations`, {}, token);
      }
      meetingJoinDuration.add(Date.now() - start);
    });
  }

  thinkTime(1, 3);
}