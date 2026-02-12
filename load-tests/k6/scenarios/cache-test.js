/**
 * 캐시 HIT 테스트
 *
 * 목적: Nginx 캐시 효과 검증
 * - 동일 URL 반복 호출로 캐시 HIT 유도
 * - 인증 헤더 없이 공개 API만 테스트
 */
import { group, check, sleep } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';
import { config } from '../config.js';
import http from 'k6/http';

// 커스텀 메트릭
const cacheHitDuration = new Trend('cache_hit_duration', true);
const cacheMissDuration = new Trend('cache_miss_duration', true);
const fastResponses = new Rate('fast_responses');  // 50ms 이하 = 캐시 HIT 추정

export const options = {
  scenarios: {
    cache_warmup: {
      // 먼저 캐시 워밍업 (1명이 모든 URL 1번씩)
      executor: 'per-vu-iterations',
      vus: 1,
      iterations: 1,
      exec: 'warmup',
      startTime: '0s',
    },
    cache_test: {
      // 워밍업 후 동일 URL 반복 호출
      executor: 'constant-vus',
      vus: 100,
      duration: '3m',
      exec: 'cacheTest',
      startTime: '10s',  // 워밍업 후 시작
    },
  },
  thresholds: {
    fast_responses: ['rate>0.8'],  // 80% 이상이 빠른 응답이면 캐시 효과 있음
    cache_hit_duration: ['p(95)<100'],
  },
};

// 캐시 테스트할 고정 URL들 (쿼리스트링 고정)
const CACHE_URLS = [
  '/health',
  '/recommendations/meetings',
  '/meetings?size=10',
  '/meetings/1',  // 고정 ID
  '/meetings/2',
  '/meetings/3',
  '/meetings/search?keyword=소설&size=10',  // 고정 키워드
  '/meetings/search?keyword=에세이&size=10',
  '/policies/reading-genres',
];

// 캐시 워밍업 (각 URL 1번씩 호출)
export function warmup() {
  console.log('캐시 워밍업 시작...');

  for (const path of CACHE_URLS) {
    const url = `${config.baseUrl}${path}`;
    const res = http.get(url, {
      headers: {
        'Accept': 'application/json',
        // 인증 헤더 없음 = 캐시 가능
      },
      tags: { name: path.split('?')[0] },
    });

    console.log(`워밍업: ${path} → ${res.status}`);
    sleep(0.5);
  }

  console.log('캐시 워밍업 완료');
}

// 캐시 테스트 (동일 URL 반복)
export function cacheTest() {
  // 고정 URL 중 하나 선택 (라운드로빈)
  const index = __ITER % CACHE_URLS.length;
  const path = CACHE_URLS[index];
  const url = `${config.baseUrl}${path}`;

  const res = http.get(url, {
    headers: {
      'Accept': 'application/json',
      // 인증 헤더 없음!
      // 쿠키도 없음!
    },
    tags: { name: path.split('?')[0] },
  });

  const duration = res.timings.duration;

  // 50ms 이하면 캐시 HIT로 추정
  const isFast = duration < 50;
  fastResponses.add(isFast);

  if (isFast) {
    cacheHitDuration.add(duration);
  } else {
    cacheMissDuration.add(duration);
  }

  // 응답 헤더에서 캐시 상태 확인 (Nginx 설정에 따라)
  const cacheStatus = res.headers['X-Cache-Status'];
  if (cacheStatus) {
    check(res, {
      [`Cache ${cacheStatus}`]: () => true,
    });
  }

  check(res, {
    'status 200': (r) => r.status === 200,
  });

  sleep(0.1);
}

export default function() {
  cacheTest();
}
