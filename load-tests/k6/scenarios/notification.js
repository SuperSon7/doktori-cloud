/**
 * 알림 부하 테스트
 *
 * 테스트 항목:
 * 1. SSE 연결 유지 (장시간 연결)
 * 2. 알림 목록 조회
 * 3. 읽지 않은 알림 확인
 * 4. 알림 읽음 처리
 * 5. FCM 토큰 등록
 *
 * 테스트 포인트:
 * - SSE 동시 연결 수 한계
 * - ConcurrentHashMap 기반 emitters 관리
 * - 알림 조회 성능 (최근 3일)
 */
import http from 'k6/http';
import { group, check, sleep } from 'k6';
import { Trend, Counter, Gauge } from 'k6/metrics';
import { config } from '../config.js';
import {
  apiGet, apiPut, apiPost, checkResponse, extractData,
  initAuth, getAccessToken, randomInt, thinkTime
} from '../helpers.js';

// 커스텀 메트릭
const sseConnectDuration = new Trend('sse_connect_duration', true);
const notificationListDuration = new Trend('notification_list_duration', true);
const sseActiveConnections = new Gauge('sse_active_connections');
const sseConnectSuccess = new Counter('sse_connect_success');
const sseConnectFailed = new Counter('sse_connect_failed');

export const options = {
  scenarios: {
    // SSE 연결 유지 테스트
    sse_connections: {
      executor: 'ramping-vus',
      startVUs: 10,
      stages: [
        { duration: '1m', target: 50 },
        { duration: '3m', target: 100 },
        { duration: '2m', target: 200 },
        { duration: '2m', target: 100 },
        { duration: '1m', target: 0 },
      ],
      exec: 'sseTest',
    },
    // 알림 API 테스트
    notification_api: {
      executor: 'ramping-vus',
      startVUs: 5,
      stages: [
        { duration: '1m', target: 20 },
        { duration: '3m', target: 50 },
        { duration: '2m', target: 20 },
        { duration: '1m', target: 0 },
      ],
      exec: 'notificationApiTest',
    },
  },
  thresholds: {
    sse_connect_duration: ['p(95)<1000'],
    notification_list_duration: ['p(95)<300'],
    http_req_failed: ['rate<0.05'],
  },
};

export function setup() {
  const hasAuth = initAuth();
  if (!hasAuth) {
    console.error('알림 테스트는 인증이 필요합니다.');
  }
  return { hasAuth };
}

// SSE 연결 테스트
export function sseTest(data) {
  if (!data.hasAuth) {
    sleep(1);
    return;
  }

  const token = getAccessToken();
  if (!token) {
    sleep(1);
    return;
  }

  group('SSE 연결', function () {
    const start = Date.now();

    // SSE 연결 시도
    const res = http.get(`${config.baseUrl}/notifications/subscribe`, {
      headers: {
        'Authorization': `Bearer ${token}`,
        'Accept': 'text/event-stream',
        'Cache-Control': 'no-cache',
      },
      tags: { name: '/notifications/subscribe' },
      timeout: '30s',  // SSE는 장시간 연결
    });

    const duration = Date.now() - start;
    sseConnectDuration.add(duration);

    // SSE 연결은 200으로 시작하고 스트림 유지
    const success = check(res, {
      'SSE connect - status 200': (r) => r.status === 200,
    });

    if (success) {
      sseConnectSuccess.add(1);
      sseActiveConnections.add(1);
    } else {
      sseConnectFailed.add(1);
      console.log(`SSE 연결 실패: ${res.status}`);
    }
  });

  // 연결 유지 시뮬레이션 (실제 SSE는 k6에서 완전 지원 안됨)
  sleep(randomInt(10, 30));
  sseActiveConnections.add(-1);
}

// 알림 API 테스트
export function notificationApiTest(data) {
  if (!data.hasAuth) {
    sleep(1);
    return;
  }

  group('알림 API', function () {
    // 1. 읽지 않은 알림 확인
    group('읽지 않은 알림 확인', function () {
      const res = apiGet('/notifications/unread', {}, true);
      checkResponse(res, 200, 'Unread check');
    });

    thinkTime(1, 2);

    // 2. 알림 목록 조회
    let notificationIds = [];
    group('알림 목록 조회', function () {
      const start = Date.now();
      const res = apiGet('/notifications', {}, true);
      notificationListDuration.add(Date.now() - start);

      if (res.status === 200) {
        const resData = extractData(res);
        if (resData && resData.notifications) {
          notificationIds = resData.notifications
            .filter(n => !n.isRead)
            .slice(0, 3)  // 최대 3개만
            .map(n => n.notificationId);
        }
      }
    });

    thinkTime(1, 2);

    // 3. 알림 읽음 처리 (있으면)
    if (notificationIds.length > 0) {
      group('알림 읽음 처리', function () {
        const notificationId = notificationIds[0];
        const res = apiPut(`/notifications/${notificationId}`, {}, true);
        check(res, {
          'Mark as read - status 204': (r) => r.status === 204,
        });
      });
    }

    thinkTime(2, 4);

    // 4. 전체 읽음 처리 (10% 확률)
    if (Math.random() < 0.1) {
      group('전체 알림 읽음', function () {
        const res = apiPut('/notifications', {}, true);
        check(res, {
          'Mark all as read - status 204': (r) => r.status === 204,
        });
      });
    }
  });

  thinkTime(2, 5);
}

// 기본 함수 (scenarios에서 exec 지정 안 한 경우)
export default function (data) {
  notificationApiTest(data);
}
