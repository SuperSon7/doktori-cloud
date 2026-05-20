/**
 * 시나리오 2: 로그인 후 일상 사용 흐름
 * 목적: 기존 회원의 핵심 사용 패턴 검증
 * 예상 비율: 전체 트래픽의 약 35%
 */
import { group, check } from 'k6';
import { config, thresholds, loadStages } from '../config.js';
import {
  apiGetWithToken, apiPutWithToken,
  checkResponse, extractData, thinkTime, randomItem,
  fetchMultiTokens, pickToken,
} from '../helpers.js';

export const options = {
  stages: loadStages.load,
  thresholds: {
    http_req_duration: [`p(95)<${thresholds.read.p95}`],
    'http_req_duration{name:/users/me}': ['p(95)<500'],
    'http_req_duration{name:/users/me/meetings}': ['p(95)<1000'],
    'http_req_duration{name:/users/me/meetings/today}': ['p(95)<1000'],
    'http_req_duration{name:/notifications}': ['p(95)<500'],
    'http_req_duration{name:/reviews}': ['p(95)<1000'],
    errors: [`rate<${thresholds.errorRate}`],
  },
};

export function setup() {
  const tokens = fetchMultiTokens();
  if (tokens.length === 0) {
    console.error('Dev token 발급에 실패했습니다.');
  }
  return { tokens };
}

export default function (data) {
  const token = pickToken(data.tokens);
  if (!token) {
    return;
  }

  group('로그인 사용자 일상 흐름', function () {
    // 1. 내 프로필 조회
    group('내 프로필', function () {
      const res = apiGetWithToken('/users/me', token);
      checkResponse(res, 200, 'My Profile');

      // 프로필 조회 완료
    });

    thinkTime(3, 8);

    // 2. 개인화 추천 모임 조회
    group('개인화 추천', function () {
      const res = apiGetWithToken('/recommendations/meetings', token);
      checkResponse(res, 200, 'Personalized Recommendations');

      // 개인화 추천 조회 완료
    });

    thinkTime(3, 8);

    // 3. 내 활성 모임 목록
    let myMeetingIds = [];
    group('내 모임 목록', function () {
      const res = apiGetWithToken('/users/me/meetings?status=ACTIVE&size=10', token);
      checkResponse(res, 200, 'My Meetings');

      const data = extractData(res);
      if (data && data.items) {
        myMeetingIds = data.items.map(m => m.meetingId);
      }
    });

    thinkTime(3, 8);

    // 4. 오늘의 모임 확인
    group('오늘의 모임', function () {
      const res = apiGetWithToken('/users/me/meetings/today', token);
      checkResponse(res, 200, 'Today Meetings');

      // 오늘의 모임 조회 완료
    });

    thinkTime(3, 8);

    // 5. 모임 상세 조회 (참여 중인 모임)
    if (myMeetingIds.length > 0) {
      group('내 모임 상세', function () {
        const meetingId = randomItem(myMeetingIds);
        const res = apiGetWithToken(`/users/me/meetings/${meetingId}`, token);
        checkResponse(res, 200, 'My Meeting Detail');

        // 내 모임 상세 조회 완료
      });
    }

    thinkTime(3, 8);

    // 6. 읽지 않은 알림 확인
    group('알림 확인', function () {
      const res = apiGetWithToken('/notifications/unread', token);
      checkResponse(res, 200, 'Unread Check');

      // 읽지 않은 알림 확인 완료
    });

    thinkTime(3, 8);

    // 7. 알림 목록 조회
    let notificationIds = [];
    group('알림 목록', function () {
      const res = apiGetWithToken('/notifications', token);
      checkResponse(res, 200, 'Notifications');

      const data = extractData(res);
      if (data && data.notifications) {
        notificationIds = data.notifications
          .filter(n => !n.isRead)
          .map(n => n.notificationId);
      }
    });

    thinkTime(3, 8);

    // 8. 알림 읽음 처리 (있을 경우)
    if (notificationIds.length > 0) {
      group('알림 읽음 처리', function () {
        const notificationId = notificationIds[0];
        const res = apiPutWithToken(`/notifications/${notificationId}`, {}, token);
        check(res, {
          'Mark as read - status 204': (r) => r.status === 204,
        });
      });
    }

    thinkTime(3, 8);

    // 9. 모임 리뷰 조회
    if (myMeetingIds.length > 0) {
      group('모임 리뷰 조회', function () {
        const meetingId = randomItem(myMeetingIds);
        const res = apiGetWithToken(`/reviews/meetings/${meetingId}`, token);
        checkResponse(res, 200, 'Meeting Reviews');
      });
    }
  });
}
