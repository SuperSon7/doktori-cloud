/**
 * Load 테스트
 * 목적: 일반적인 트래픽 수준에서 시스템 성능 검증
 *
 * 혼합 시나리오:
 * - 40%: 비회원 탐색 흐름
 * - 35%: 로그인 사용자 흐름
 * - 15%: 모임 검색
 * - 10%: 도서 검색
 */
import http from 'k6/http';
import { group, sleep } from 'k6';
import { config, thresholds, loadStages } from '../config.js';
import {
  apiGet, apiPost, apiPut,
  checkResponse, extractData, thinkTime, randomItem, randomInt,
  initAuth, getAccessToken
} from '../helpers.js';

export const options = {
  stages: loadStages.load,
  thresholds: {
    http_req_duration: ['p(95)<500', 'p(99)<1500'],
    http_req_failed: ['rate<0.01'],
    errors: [`rate<${thresholds.errorRate}`],
  },
};

export function setup() {
  const hasAuth = initAuth();
  return { hasAuth };
}

// 비회원 탐색 흐름
function guestFlow() {
  group('비회원 탐색', function () {
    // 추천 모임
    apiGet('/recommendations/meetings');
    thinkTime(2, 4);

    // 모임 목록
    const listRes = apiGet('/meetings?size=10');
    const data = extractData(listRes);

    if (data && data.items && data.items.length > 0) {
      thinkTime(1, 3);
      // 모임 상세
      const meetingId = randomItem(data.items).meetingId;
      apiGet(`/meetings/${meetingId}`);
    }

    thinkTime(2, 4);

    // 모임 검색
    const keyword = randomItem(config.searchKeywords);
    apiGet(`/meetings/search?keyword=${encodeURIComponent(keyword)}&size=10`);
  });
}

// 로그인 사용자 흐름
function userFlow(hasAuth) {
  if (!hasAuth) {
    guestFlow();  // 토큰 없으면 비회원 흐름으로 대체
    return;
  }

  group('로그인 사용자', function () {
    // 내 프로필
    apiGet('/users/me', {}, true);
    thinkTime(2, 4);

    // 개인화 추천
    apiGet('/recommendations/meetings', {}, true);
    thinkTime(2, 4);

    // 내 모임 목록
    const myMeetingsRes = apiGet('/users/me/meetings?status=ACTIVE&size=10', {}, true);
    const myData = extractData(myMeetingsRes);

    if (myData && myData.items && myData.items.length > 0) {
      thinkTime(1, 3);
      // 내 모임 상세
      const meetingId = randomItem(myData.items).meetingId;
      apiGet(`/users/me/meetings/${meetingId}`, {}, true);
    }

    thinkTime(2, 4);

    // 오늘의 모임
    apiGet('/users/me/meetings/today', {}, true);
    thinkTime(2, 4);

    // 알림 확인
    apiGet('/notifications/unread', {}, true);
  });
}

// 모임 검색 집중
function searchFlow() {
  group('모임 검색', function () {
    for (let i = 0; i < 3; i++) {
      const keyword = randomItem(config.searchKeywords);
      const params = [`keyword=${encodeURIComponent(keyword)}`, 'size=10'];

      // 50% 확률로 필터 추가
      if (Math.random() > 0.5) {
        params.push(`readingGenre=${randomItem(config.genreCodes)}`);
      }

      apiGet(`/meetings/search?${params.join('&')}`);
      thinkTime(1, 2);
    }
  });
}

// 도서 검색 (인증 필요)
function bookSearchFlow(hasAuth) {
  if (!hasAuth) {
    searchFlow();  // 토큰 없으면 모임 검색으로 대체
    return;
  }

  group('도서 검색', function () {
    const keywords = ['해리포터', '아몬드', '데미안', '사피엔스', '코스모스'];
    for (let i = 0; i < 2; i++) {
      const keyword = randomItem(keywords);
      apiGet(`/books?query=${encodeURIComponent(keyword)}&page=1&size=10`, {}, true);
      thinkTime(2, 4);
    }
  });
}

// 이미지 업로드 (인증 필요)
function imageUploadFlow(hasAuth) {
  if (!hasAuth) {
    guestFlow();
    return;
  }

  group('이미지 업로드', function () {
    const directories = ['PROFILE', 'MEETING'];
    const contentTypes = ['image/jpeg', 'image/png'];

    const directory = randomItem(directories);
    const contentType = randomItem(contentTypes);
    const fileSize = randomInt(100, 500) * 1024;  // 100KB ~ 500KB
    const extension = contentType.split('/')[1];
    const fileName = `test_${Date.now()}_${__VU}.${extension}`;

    // Presigned URL 발급
    const res = apiPost('/uploads/presigned-url', {
      directory: directory,
      fileName: fileName,
      contentType: contentType,
      fileSize: fileSize,
    }, true);

    if (res.status === 200) {
      const data = extractData(res);
      if (data && data.presignedUrl) {
        // S3 업로드 (더미 데이터)
        const dummyData = new ArrayBuffer(fileSize);
        http.put(data.presignedUrl, dummyData, {
          headers: { 'Content-Type': contentType },
          tags: { name: 's3_upload' },
        });
      }
    }
  });
}

export default function (data) {
  const scenario = randomInt(1, 100);

  if (scenario <= 35) {
    // 35%: 비회원 탐색
    guestFlow();
  } else if (scenario <= 65) {
    // 30%: 로그인 사용자
    userFlow(data.hasAuth);
  } else if (scenario <= 80) {
    // 15%: 모임 검색
    searchFlow();
  } else if (scenario <= 90) {
    // 10%: 도서 검색
    bookSearchFlow(data.hasAuth);
  } else {
    // 10%: 이미지 업로드
    imageUploadFlow(data.hasAuth);
  }

  sleep(1);
}
