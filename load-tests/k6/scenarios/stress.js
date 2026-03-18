/**
 * Stress 테스트 (멀티 유저)
 * 목적: K8s 클러스터 한계점 확인 (점진적 부하 증가)
 *
 * - 40%: 공개 API (비인증)
 * - 25%: 인증 API (멀티 토큰)
 * - 10%: 검색 집중
 * - 10%: 이미지 업로드
 * - 10%: 채팅방 API
 * - 5%:  알림 API
 */
import http from 'k6/http';
import { group, sleep } from 'k6';
import { config, thresholds, loadStages } from '../config.js';
import {
  apiGet, apiPost, checkResponse, extractData,
  thinkTime, randomItem, randomInt,
  fetchMultiTokens, pickToken,
  apiGetWithToken, apiPostWithToken, apiPutWithToken,
} from '../helpers.js';

export const options = {
  stages: loadStages.stress,
  thresholds: {
    http_req_duration: [`p(95)<${thresholds.read.p95}`, `p(99)<${thresholds.read.p99}`],
    http_req_failed: ['rate<0.05'],
    errors: ['rate<0.05'],
  },
};

export function setup() {
  const tokens = fetchMultiTokens();
  return { tokens };
}

export default function (data) {
  const token = pickToken(data.tokens);
  const scenario = randomInt(1, 100);

  if (scenario <= 40) {
    // 40%: 공개 API
    group('공개 API 부하', function () {
      apiGet('/health');
      apiGet('/recommendations/meetings');

      const keyword = randomItem(config.searchKeywords);
      apiGet(`/meetings/search?keyword=${encodeURIComponent(keyword)}&size=10`);

      const listRes = apiGet('/meetings?size=10');
      const respData = extractData(listRes);
      if (respData && respData.items && respData.items.length > 0) {
        const meetingId = randomItem(respData.items).meetingId;
        apiGet(`/meetings/${meetingId}`);
      }
    });

  } else if (scenario <= 65 && token) {
    // 25%: 인증 API (멀티 토큰)
    group('인증 API 부하', function () {
      apiGetWithToken('/users/me', token);
      apiGetWithToken('/users/me/meetings?status=ACTIVE&size=10', token);
      apiGetWithToken('/users/me/meetings/today', token);
      apiGetWithToken('/notifications/unread', token);
      apiGetWithToken('/notifications', token);
    });

  } else if (scenario <= 75) {
    // 10%: 검색 집중
    group('검색 집중 부하', function () {
      for (let i = 0; i < 5; i++) {
        const keyword = randomItem(config.searchKeywords);
        apiGet(`/meetings/search?keyword=${encodeURIComponent(keyword)}&size=10`);
        sleep(0.2);
      }
    });

  } else if (scenario <= 85 && token) {
    // 10%: 이미지 업로드
    group('이미지 업로드 부하', function () {
      const directory = randomItem(['PROFILE', 'MEETING']);
      const contentType = randomItem(['image/jpeg', 'image/png']);
      const fileSize = randomInt(100, 500) * 1024;
      const extension = contentType.split('/')[1];
      const fileName = `stress_${Date.now()}_${__VU}.${extension}`;

      const res = apiPostWithToken('/uploads/presigned-url', {
        directory, fileName, contentType, fileSize,
      }, token);

      if (res.status === 200) {
        const respData = extractData(res);
        if (respData && respData.presignedUrl) {
          const dummyData = new ArrayBuffer(fileSize);
          http.put(respData.presignedUrl, dummyData, {
            headers: { 'Content-Type': contentType },
            tags: { name: 's3_upload' },
          });
        }
      }
    });

  } else if (scenario <= 95) {
    // 10%: 채팅방 API
    group('채팅방 부하', function () {
      const listRes = apiGet('/chat-rooms?size=10');
      const data = extractData(listRes);

      if (token && data && data.items && data.items.length > 0) {
        const roomId = randomItem(data.items).chatRoomId || randomItem(data.items).id;
        if (roomId) {
          apiGetWithToken(`/chat-rooms/${roomId}`, token);
        }
      }
    });

  } else if (token) {
    // 5%: 알림 API
    group('알림 부하', function () {
      apiGetWithToken('/notifications/unread', token);
      apiGetWithToken('/notifications', token);
    });
  }

  thinkTime(0, 1);
}