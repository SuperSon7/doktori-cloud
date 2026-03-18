/**
 * Load 테스트 (멀티 유저)
 * 목적: 일반적인 트래픽 수준에서 K8s 클러스터 성능 검증
 *
 * 혼합 시나리오:
 * - 25%: 비회원 탐색 흐름
 * - 25%: 로그인 사용자 흐름 (멀티 토큰)
 * - 15%: 모임 검색
 * - 10%: 도서 검색
 * - 10%: 이미지 업로드
 * - 10%: 채팅방 API (REST)
 * - 5%:  알림 API
 */
import http from 'k6/http';
import { group, sleep } from 'k6';
import { config, thresholds, loadStages } from '../config.js';
import {
  apiGet, apiPost, apiPut,
  checkResponse, extractData, thinkTime, randomItem, randomInt,
  fetchMultiTokens, pickToken,
  apiGetWithToken, apiPostWithToken, apiPutWithToken,
} from '../helpers.js';

export const options = {
  stages: loadStages.load,
  thresholds: {
    http_req_duration: [`p(95)<${thresholds.read.p95}`, `p(99)<${thresholds.read.p99}`],
    http_req_failed: [`rate<${thresholds.errorRate}`],
    errors: [`rate<${thresholds.errorRate}`],
  },
};

export function setup() {
  const tokens = fetchMultiTokens();
  return { tokens };
}

// 비회원 탐색 흐름
function guestFlow() {
  group('비회원 탐색', function () {
    apiGet('/recommendations/meetings');
    thinkTime(2, 4);

    const listRes = apiGet('/meetings?size=10');
    const data = extractData(listRes);

    if (data && data.items && data.items.length > 0) {
      thinkTime(1, 3);
      const meetingId = randomItem(data.items).meetingId;
      apiGet(`/meetings/${meetingId}`);
    }

    thinkTime(2, 4);

    const keyword = randomItem(config.searchKeywords);
    apiGet(`/meetings/search?keyword=${encodeURIComponent(keyword)}&size=10`);
  });
}

// 로그인 사용자 흐름 (멀티 토큰)
function userFlow(token) {
  if (!token) { guestFlow(); return; }

  group('로그인 사용자', function () {
    apiGetWithToken('/users/me', token);
    thinkTime(2, 4);

    apiGetWithToken('/recommendations/meetings', token);
    thinkTime(2, 4);

    const myMeetingsRes = apiGetWithToken('/users/me/meetings?status=ACTIVE&size=10', token);
    const myData = extractData(myMeetingsRes);

    if (myData && myData.items && myData.items.length > 0) {
      thinkTime(1, 3);
      const meetingId = randomItem(myData.items).meetingId;
      apiGetWithToken(`/users/me/meetings/${meetingId}`, token);
    }

    thinkTime(2, 4);
    apiGetWithToken('/users/me/meetings/today', token);
    thinkTime(2, 4);
    apiGetWithToken('/notifications/unread', token);
  });
}

// 모임 검색 집중
function searchFlow() {
  group('모임 검색', function () {
    for (let i = 0; i < 3; i++) {
      const keyword = randomItem(config.searchKeywords);
      const params = [`keyword=${encodeURIComponent(keyword)}`, 'size=10'];

      if (Math.random() > 0.5) {
        params.push(`readingGenre=${randomItem(config.genreCodes)}`);
      }

      apiGet(`/meetings/search?${params.join('&')}`);
      thinkTime(1, 2);
    }
  });
}

// 도서 검색
function bookSearchFlow(token) {
  if (!token) { searchFlow(); return; }

  group('도서 검색', function () {
    const keywords = ['해리포터', '아몬드', '데미안', '사피엔스', '코스모스'];
    for (let i = 0; i < 2; i++) {
      const keyword = randomItem(keywords);
      apiGetWithToken(`/books?query=${encodeURIComponent(keyword)}&page=1&size=10`, token);
      thinkTime(2, 4);
    }
  });
}

// 이미지 업로드
function imageUploadFlow(token) {
  if (!token) { guestFlow(); return; }

  group('이미지 업로드', function () {
    const directory = randomItem(['PROFILE', 'MEETING']);
    const contentType = randomItem(['image/jpeg', 'image/png']);
    const fileSize = randomInt(100, 500) * 1024;
    const extension = contentType.split('/')[1];
    const fileName = `test_${Date.now()}_${__VU}.${extension}`;

    const res = apiPostWithToken('/uploads/presigned-url', {
      directory, fileName, contentType, fileSize,
    }, token);

    if (res.status === 200) {
      const data = extractData(res);
      if (data && data.presignedUrl) {
        const dummyData = new ArrayBuffer(fileSize);
        http.put(data.presignedUrl, dummyData, {
          headers: { 'Content-Type': contentType },
          tags: { name: 's3_upload' },
        });
      }
    }
  });
}

// 채팅방 REST API
function chatApiFlow(token) {
  group('채팅방 API', function () {
    // 채팅방 목록 (비인증 가능)
    const listRes = apiGet('/chat-rooms?size=10');
    const data = extractData(listRes);
    thinkTime(1, 3);

    if (token && data && data.items && data.items.length > 0) {
      // 채팅방 상세
      const roomId = randomItem(data.items).chatRoomId || randomItem(data.items).id;
      if (roomId) {
        apiGetWithToken(`/chat-rooms/${roomId}`, token);
      }
    }
  });
}

// 알림 API
function notificationFlow(token) {
  if (!token) { guestFlow(); return; }

  group('알림 API', function () {
    apiGetWithToken('/notifications/unread', token);
    thinkTime(1, 2);

    const res = apiGetWithToken('/notifications', token);
    const data = extractData(res);

    if (data && data.notifications && data.notifications.length > 0) {
      const unread = data.notifications.filter(n => !n.isRead);
      if (unread.length > 0) {
        apiPutWithToken(`/notifications/${unread[0].notificationId}`, {}, token);
      }
    }
  });
}

export default function (data) {
  const token = pickToken(data.tokens);
  const scenario = randomInt(1, 100);

  if (scenario <= 25) {
    guestFlow();
  } else if (scenario <= 50) {
    userFlow(token);
  } else if (scenario <= 65) {
    searchFlow();
  } else if (scenario <= 75) {
    bookSearchFlow(token);
  } else if (scenario <= 85) {
    imageUploadFlow(token);
  } else if (scenario <= 95) {
    chatApiFlow(token);
  } else {
    notificationFlow(token);
  }

  sleep(1);
}