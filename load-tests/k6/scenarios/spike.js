/**
 * Spike 테스트
 * 목적: 급격한 트래픽 증가에 대한 시스템 대응력 검증
 */
import { sleep } from 'k6';
import { config, loadStages } from '../config.js';
import { apiGet, randomItem, randomInt, initAuth, getAccessToken } from '../helpers.js';

export function setup() {
  const hasAuth = initAuth();
  return { hasAuth };
}

export const options = {
  stages: loadStages.spike,
  thresholds: {
    http_req_duration: ['p(95)<1500', 'p(99)<3000'],
    http_req_failed: ['rate<0.1'],  // 10% 에러 허용 (스파이크 상황)
  },
};

export default function (data) {
  // 빠른 요청 패턴 (스파이크 시뮬레이션)
  const apis = [
    '/health',
    '/recommendations/meetings',
    '/meetings?size=10',
    `/meetings/search?keyword=${encodeURIComponent(randomItem(config.searchKeywords))}&size=10`,
  ];

  // 랜덤 API 호출
  const api = randomItem(apis);
  apiGet(api);

  // 인증 API (토큰 있을 경우)
  if (data.hasAuth && Math.random() > 0.5) {
    const authApis = [
      '/users/me',
      '/users/me/meetings?status=ACTIVE&size=5',
      '/notifications/unread',
    ];
    apiGet(randomItem(authApis), {}, true);
  }

  sleep(randomInt(0, 1) * 0.5);  // 0~0.5초 랜덤 대기
}
