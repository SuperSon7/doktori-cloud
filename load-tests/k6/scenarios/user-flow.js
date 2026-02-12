/**
 * 시나리오 2: 로그인 후 일상 사용 흐름
 * 목적: 기존 회원의 핵심 사용 패턴 검증
 * 예상 비율: 전체 트래픽의 약 35%
 */
import { group, check } from 'k6';
import { config, thresholds, loadStages } from '../config.js';
import {
  apiGet, apiPut, apiPost,
  checkResponse, extractData, thinkTime, randomItem,
  initAuth
} from '../helpers.js';

export const options = {
  stages: loadStages.load,
  thresholds: {
    http_req_duration: [`p(95)<${thresholds.read.p95}`],
    'http_req_duration{name:/users/me}': ['p(95)<300'],
    'http_req_duration{name:/users/me/meetings}': ['p(95)<500'],
    'http_req_duration{name:/users/me/meetings/today}': ['p(95)<500'],
    'http_req_duration{name:/notifications}': ['p(95)<300'],
    errors: [`rate<${thresholds.errorRate}`],
  },
};

// 사전 조건: JWT 토큰 또는 Refresh 토큰 필수
export function setup() {
  const hasAuth = initAuth();
  if (!hasAuth) {
    console.warn('인증 토큰이 없습니다. JWT_TOKEN 또는 REFRESH_TOKEN 환경변수를 설정하세요.');
  }
  return { hasAuth };
}

export default function (data) {
  if (!data.hasAuth) {
    console.log('토큰 없음 - 테스트 건너뜀');
    return;
  }

  group('로그인 사용자 일상 흐름', function () {
    // 1. 내 프로필 조회
    group('내 프로필', function () {
      const res = apiGet('/users/me', {}, true);
      checkResponse(res, 200, 'My Profile');

      const data = extractData(res);
      if (data) {
        console.log(`사용자: ${data.nickname}`);
      }
    });

    thinkTime(3, 8);

    // 2. 개인화 추천 모임 조회
    group('개인화 추천', function () {
      const res = apiGet('/recommendations/meetings', {}, true);
      checkResponse(res, 200, 'Personalized Recommendations');

      const data = extractData(res);
      if (data && Array.isArray(data)) {
        console.log(`개인화 추천 ${data.length}개`);
      }
    });

    thinkTime(3, 8);

    // 3. 내 활성 모임 목록
    let myMeetingIds = [];
    group('내 모임 목록', function () {
      const res = apiGet('/users/me/meetings?status=ACTIVE&size=10', {}, true);
      checkResponse(res, 200, 'My Meetings');

      const data = extractData(res);
      if (data && data.items) {
        myMeetingIds = data.items.map(m => m.meetingId);
        console.log(`내 활성 모임 ${myMeetingIds.length}개`);
      }
    });

    thinkTime(3, 8);

    // 4. 오늘의 모임 확인
    group('오늘의 모임', function () {
      const res = apiGet('/users/me/meetings/today', {}, true);
      checkResponse(res, 200, 'Today Meetings');

      const data = extractData(res);
      if (data && data.items) {
        console.log(`오늘 모임 ${data.items.length}개`);
      }
    });

    thinkTime(3, 8);

    // 5. 모임 상세 조회 (참여 중인 모임)
    if (myMeetingIds.length > 0) {
      group('내 모임 상세', function () {
        const meetingId = randomItem(myMeetingIds);
        const res = apiGet(`/users/me/meetings/${meetingId}`, {}, true);
        checkResponse(res, 200, 'My Meeting Detail');

        const data = extractData(res);
        if (data) {
          console.log(`모임 상세: ${data.title}, 현재 ${data.currentRoundNo}회차`);
        }
      });
    }

    thinkTime(3, 8);

    // 6. 읽지 않은 알림 확인
    group('알림 확인', function () {
      const res = apiGet('/notifications/unread', {}, true);
      checkResponse(res, 200, 'Unread Check');

      const data = extractData(res);
      if (data) {
        console.log(`읽지 않은 알림: ${data.hasUnread}`);
      }
    });

    thinkTime(3, 8);

    // 7. 알림 목록 조회
    let notificationIds = [];
    group('알림 목록', function () {
      const res = apiGet('/notifications', {}, true);
      checkResponse(res, 200, 'Notifications');

      const data = extractData(res);
      if (data && data.notifications) {
        notificationIds = data.notifications
          .filter(n => !n.isRead)
          .map(n => n.notificationId);
        console.log(`알림 ${data.notifications.length}개, 미읽음 ${notificationIds.length}개`);
      }
    });

    thinkTime(3, 8);

    // 8. 알림 읽음 처리 (있을 경우)
    if (notificationIds.length > 0) {
      group('알림 읽음 처리', function () {
        const notificationId = notificationIds[0];
        const res = apiPut(`/notifications/${notificationId}`, {}, true);
        check(res, {
          'Mark as read - status 204': (r) => r.status === 204,
        });
      });
    }
  });
}
