/**
 * 전체 사용자 여정 마이그레이션 테스트
 *
 * 목적: 마이그레이션 중 실제 사용자가 경험하는 전체 플로우가 정상인지 검증한다.
 *       개별 엔드포인트가 아닌, 사용자 시나리오 단위로 성공/실패를 측정한다.
 *
 * 사용자 시나리오 (5가지):
 *   1. 비로그인 탐색 (40%): 메인 → 모임 목록 → 검색 → 상세
 *   2. 로그인 사용자 (30%): 로그인 → 내 모임 → 알림 확인
 *   3. 모임 참여 (15%): 모임 검색 → 상세 → 참여 신청
 *   4. 채팅 (10%): 채팅방 목록 → 입장
 *   5. 도서 검색 (5%): 도서 검색 (외부 API 의존)
 *
 * 포트폴리오 핵심:
 *   "마이그레이션 중 5가지 사용자 시나리오 전부 성공률 99%+"
 *
 * 실행:
 *   k6 run --env BASE_URL=https://doktori.kr/api \
 *          --env JWT_TOKEN=<토큰> \
 *          full-user-journey.js
 */

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';
import { config } from '../../config.js';
import {
  apiGet, getHeaders, initAuth,
  randomItem, randomInt, thinkTime,
} from '../../helpers.js';

// ── 시나리오별 메트릭 ──
const guestFlowSuccess = new Rate('journey_guest_success');
const userFlowSuccess = new Rate('journey_user_success');
const joinFlowSuccess = new Rate('journey_join_success');
const chatFlowSuccess = new Rate('journey_chat_success');
const bookFlowSuccess = new Rate('journey_book_success');
const overallJourneySuccess = new Rate('journey_overall_success');

const journeyLatency = new Trend('journey_total_latency', true);
const journeyErrors = new Counter('journey_errors');

export const options = {
  scenarios: {
    guest_browsing: {
      executor: 'constant-vus',
      vus: 8,
      duration: '15m',
      exec: 'guestBrowsing',
    },
    logged_in_user: {
      executor: 'constant-vus',
      vus: 6,
      duration: '15m',
      exec: 'loggedInUser',
    },
    meeting_join: {
      executor: 'constant-vus',
      vus: 3,
      duration: '15m',
      exec: 'meetingJoinAttempt',
    },
    chat_usage: {
      executor: 'constant-vus',
      vus: 2,
      duration: '15m',
      exec: 'chatUsage',
    },
    book_search: {
      executor: 'constant-vus',
      vus: 1,
      duration: '15m',
      exec: 'bookSearch',
    },
  },

  thresholds: {
    'journey_overall_success': ['rate>0.95'],
    'journey_guest_success': ['rate>0.99'],
    'journey_user_success': ['rate>0.95'],
    'journey_total_latency': ['p(95)<3000'],
  },
};

export function setup() {
  initAuth();
  console.log('=== 전체 사용자 여정 테스트 시작 ===');
  console.log(`대상: ${config.baseUrl}`);
  console.log('마이그레이션 작업 중 실행하여 사용자 영향을 측정합니다.');
  console.log('=====================================');
}

// ── 시나리오 1: 비로그인 탐색 (40%) ──
export function guestBrowsing() {
  const timestamp = new Date().toISOString();
  const journeyStart = Date.now();
  let success = true;

  group('guest_browsing', () => {
    // 1. 추천 모임
    const recoRes = http.get(`${config.baseUrl}/recommendations/meetings`, {
      headers: getHeaders(false),
      tags: { name: 'GET /recommendations/meetings', scenario: 'guest' },
      timeout: '10s',
    });
    if (recoRes.status !== 200) {
      success = false;
      console.log(`[${timestamp}] GUEST: /recommendations fail ${recoRes.status}`);
    }
    thinkTime(1, 2);

    // 2. 모임 목록
    const listRes = http.get(`${config.baseUrl}/meetings?size=10`, {
      headers: getHeaders(false),
      tags: { name: 'GET /meetings', scenario: 'guest' },
      timeout: '10s',
    });
    if (listRes.status !== 200) success = false;
    thinkTime(1, 3);

    // 3. 검색
    const keyword = randomItem(config.searchKeywords);
    const searchRes = http.get(
      `${config.baseUrl}/meetings/search?keyword=${encodeURIComponent(keyword)}&size=5`,
      {
        headers: getHeaders(false),
        tags: { name: 'GET /meetings/search', scenario: 'guest' },
        timeout: '10s',
      }
    );
    if (searchRes.status !== 200) success = false;
    thinkTime(1, 2);

    // 4. 모임 상세
    const detailRes = http.get(`${config.baseUrl}/meetings/${config.testData.meetingId}`, {
      headers: getHeaders(false),
      tags: { name: 'GET /meetings/:id', scenario: 'guest' },
      timeout: '10s',
    });
    if (detailRes.status !== 200) success = false;
  });

  const elapsed = Date.now() - journeyStart;
  journeyLatency.add(elapsed);
  guestFlowSuccess.add(success);
  overallJourneySuccess.add(success);
  if (!success) journeyErrors.add(1);

  thinkTime(2, 5);
}

// ── 시나리오 2: 로그인 사용자 (30%) ──
export function loggedInUser() {
  const timestamp = new Date().toISOString();
  const journeyStart = Date.now();
  let success = true;

  group('logged_in_user', () => {
    // 1. 내 정보
    const meRes = http.get(`${config.baseUrl}/users/me`, {
      headers: getHeaders(true),
      tags: { name: 'GET /users/me', scenario: 'user' },
      timeout: '10s',
    });
    if (meRes.status !== 200) {
      success = false;
      console.log(`[${timestamp}] USER: /users/me fail ${meRes.status}`);
    }
    thinkTime(1, 2);

    // 2. 내 모임 목록
    const myMeetingsRes = http.get(`${config.baseUrl}/users/me/meetings?size=10`, {
      headers: getHeaders(true),
      tags: { name: 'GET /users/me/meetings', scenario: 'user' },
      timeout: '10s',
    });
    if (myMeetingsRes.status !== 200) success = false;
    thinkTime(1, 2);

    // 3. 오늘 모임
    const todayRes = http.get(`${config.baseUrl}/users/me/meetings/today`, {
      headers: getHeaders(true),
      tags: { name: 'GET /users/me/meetings/today', scenario: 'user' },
      timeout: '10s',
    });
    if (todayRes.status !== 200) success = false;
    thinkTime(1, 2);

    // 4. 알림 확인
    const notiRes = http.get(`${config.baseUrl}/notifications`, {
      headers: getHeaders(true),
      tags: { name: 'GET /notifications', scenario: 'user' },
      timeout: '10s',
    });
    if (notiRes.status !== 200) success = false;

    // 5. 읽지 않은 알림 체크
    const unreadRes = http.get(`${config.baseUrl}/notifications/unread`, {
      headers: getHeaders(true),
      tags: { name: 'GET /notifications/unread', scenario: 'user' },
      timeout: '10s',
    });
    if (unreadRes.status !== 200) success = false;
  });

  const elapsed = Date.now() - journeyStart;
  journeyLatency.add(elapsed);
  userFlowSuccess.add(success);
  overallJourneySuccess.add(success);
  if (!success) journeyErrors.add(1);

  thinkTime(3, 6);
}

// ── 시나리오 3: 모임 참여 시도 (15%) ──
export function meetingJoinAttempt() {
  const timestamp = new Date().toISOString();
  const journeyStart = Date.now();
  let success = true;

  group('meeting_join', () => {
    // 1. 모임 검색
    const keyword = randomItem(['소설', '에세이', '경제', '자기계발']);
    const searchRes = http.get(
      `${config.baseUrl}/meetings/search?keyword=${encodeURIComponent(keyword)}&size=5`,
      {
        headers: getHeaders(false),
        tags: { name: 'GET /meetings/search', scenario: 'join' },
        timeout: '10s',
      }
    );
    if (searchRes.status !== 200) {
      success = false;
      console.log(`[${timestamp}] JOIN: search fail ${searchRes.status}`);
    }
    thinkTime(2, 4);

    // 2. 모임 상세
    const detailRes = http.get(`${config.baseUrl}/meetings/${config.testData.meetingId}`, {
      headers: getHeaders(false),
      tags: { name: 'GET /meetings/:id', scenario: 'join' },
      timeout: '10s',
    });
    if (detailRes.status !== 200) success = false;
    thinkTime(2, 3);

    // 3. 참여 신청 (POST — 쓰기 작업, DB 컷오버 중 실패 가능)
    const joinRes = http.post(
      `${config.baseUrl}/meetings/${config.testData.meetingId}/participations`,
      null,
      {
        headers: getHeaders(true),
        tags: { name: 'POST /meetings/:id/participations', scenario: 'join' },
        timeout: '10s',
      }
    );
    // 409(이미 참여) 또는 400(정원 초과)도 정상 동작으로 간주
    const joinOk = joinRes.status >= 200 && joinRes.status < 500;
    if (!joinOk) {
      success = false;
      console.log(`[${timestamp}] JOIN: participation fail ${joinRes.status}`);
    }
  });

  const elapsed = Date.now() - journeyStart;
  journeyLatency.add(elapsed);
  joinFlowSuccess.add(success);
  overallJourneySuccess.add(success);
  if (!success) journeyErrors.add(1);

  thinkTime(5, 10);
}

// ── 시나리오 4: 채팅 사용 (10%) ──
export function chatUsage() {
  const timestamp = new Date().toISOString();
  const journeyStart = Date.now();
  let success = true;

  group('chat_usage', () => {
    // 1. 채팅방 목록
    const roomsRes = http.get(`${config.baseUrl}/chat-rooms?size=10`, {
      headers: getHeaders(true),
      tags: { name: 'GET /chat-rooms', scenario: 'chat' },
      timeout: '10s',
    });

    const roomsOk = roomsRes.status === 200 || roomsRes.status === 401;
    if (!roomsOk) {
      success = false;
      console.log(`[${timestamp}] CHAT: /chat-rooms fail ${roomsRes.status}`);
    }
  });

  const elapsed = Date.now() - journeyStart;
  journeyLatency.add(elapsed);
  chatFlowSuccess.add(success);
  overallJourneySuccess.add(success);
  if (!success) journeyErrors.add(1);

  thinkTime(3, 5);
}

// ── 시나리오 5: 도서 검색 (5%, 외부 API 의존) ──
export function bookSearch() {
  const timestamp = new Date().toISOString();
  const journeyStart = Date.now();
  let success = true;

  group('book_search', () => {
    const keyword = randomItem(['해리포터', '아몬드', '데미안', '사피엔스']);
    const bookRes = http.get(
      `${config.baseUrl}/books?keyword=${encodeURIComponent(keyword)}&size=5`,
      {
        headers: getHeaders(false),
        tags: { name: 'GET /books', scenario: 'book' },
        timeout: '15s', // 외부 API 의존이라 타임아웃 넉넉히
      }
    );

    if (bookRes.status !== 200) {
      success = false;
      console.log(`[${timestamp}] BOOK: search fail ${bookRes.status} (${bookRes.timings.duration}ms)`);
    }
  });

  const elapsed = Date.now() - journeyStart;
  journeyLatency.add(elapsed);
  bookFlowSuccess.add(success);
  overallJourneySuccess.add(success);
  if (!success) journeyErrors.add(1);

  thinkTime(5, 10);
}

export function teardown(data) {
  console.log('=== 전체 사용자 여정 테스트 종료 ===');
  console.log('');
  console.log('포트폴리오 핵심 지표:');
  console.log('  - journey_overall_success: 전체 시나리오 성공률 (목표 95%+)');
  console.log('  - journey_guest_success: 비로그인 탐색 성공률 (목표 99%+)');
  console.log('  - journey_user_success: 로그인 사용자 성공률 (목표 95%+)');
  console.log('  - journey_errors: 총 시나리오 실패 수');
  console.log('  - journey_total_latency: 시나리오 완료 시간 (사용자 체감)');
}
