/**
 * 시나리오 7: 오늘의 모임 조회 - DATE() 함수 인덱스 무효화 테스트
 *
 * 병목 타겟: MeetingRepositoryImpl.findMyTodayMeetings()
 * - cb.function("DATE", LocalDate.class, roundRoot.get("startAt"))
 * - DATE() 함수 적용으로 startAt 컬럼 인덱스 사용 불가
 * - MeetingMember 서브쿼리와 결합된 이중 서브쿼리
 *
 * 코드 위치: MeetingRepositoryImpl.java:345
 */
import { group, check } from 'k6';
import { Trend, Counter } from 'k6/metrics';
import { config, thresholds } from '../config.js';
import { apiGet, checkResponse, thinkTime, initAuth } from '../helpers.js';

// 커스텀 메트릭
const todayMeetingsDuration = new Trend('today_meetings_duration', true);
const todayMeetingsRequests = new Counter('today_meetings_requests');

export const options = {
  scenarios: {
    // 모임 집중 시간대 시뮬레이션 (19:00 ~ 21:00)
    evening_peak: {
      executor: 'ramping-vus',
      startVUs: 10,
      stages: [
        { duration: '1m', target: 100 },
        { duration: '3m', target: 300 },
        { duration: '3m', target: 500 },
        { duration: '2m', target: 100 },
        { duration: '1m', target: 0 },
      ],
    },
  },
  thresholds: {
    today_meetings_duration: ['p(95)<500', 'p(99)<1000'],
    http_req_failed: ['rate<0.01'],
  },
};

export function setup() {
  const hasAuth = initAuth();
  if (!hasAuth) {
    console.error('JWT_TOKEN 또는 REFRESH_TOKEN 환경변수가 필요합니다.');
  }
  return { hasAuth };
}

export default function (data) {
  if (!data.hasAuth) {
    return;
  }

  group('오늘의 모임 조회', function () {
    const start = Date.now();

    const res = apiGet('/users/me/meetings/today', {}, true);

    const duration = Date.now() - start;
    todayMeetingsDuration.add(duration);
    todayMeetingsRequests.add(1);

    check(res, {
      'Today meetings - status 200': (r) => r.status === 200,
      'Today meetings - under 500ms': (r) => r.timings.duration < 500,
      'Today meetings - under 1s': (r) => r.timings.duration < 1000,
    });
  });

  thinkTime(1, 3);
}
