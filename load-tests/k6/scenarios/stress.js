/**
 * Stress 테스트
 * 목적: 시스템 한계점 확인 (점진적 부하 증가)
 */
import http from 'k6/http';
import { group, sleep } from 'k6';
import { config, thresholds, loadStages } from '../config.js';
import {
  apiGet, apiPost, checkResponse, extractData,
  thinkTime, randomItem, randomInt, initAuth, getAccessToken
} from '../helpers.js';

export function setup() {
  const hasAuth = initAuth();
  return { hasAuth };
}

export const options = {
  stages: loadStages.stress,
  thresholds: {
    http_req_duration: ['p(95)<1000', 'p(99)<2000'],
    http_req_failed: ['rate<0.05'],  // 5% 에러 허용 (한계점 테스트)
  },
};

export default function (data) {
  const scenario = randomInt(1, 100);

  if (scenario <= 50) {
    // 50%: 공개 API (비인증)
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

  } else if (scenario <= 80 && data.hasAuth) {
    // 30%: 인증 API
    group('인증 API 부하', function () {
      apiGet('/users/me', {}, true);
      apiGet('/users/me/meetings?status=ACTIVE&size=10', {}, true);
      apiGet('/users/me/meetings/today', {}, true);
      apiGet('/notifications/unread', {}, true);
      apiGet('/notifications', {}, true);
    });

  } else if (scenario <= 90) {
    // 10%: 검색 집중
    group('검색 집중 부하', function () {
      for (let i = 0; i < 5; i++) {
        const keyword = randomItem(config.searchKeywords);
        apiGet(`/meetings/search?keyword=${encodeURIComponent(keyword)}&size=10`);
        sleep(0.2);
      }
    });

  } else if (data.hasAuth) {
    // 10%: 이미지 업로드
    group('이미지 업로드 부하', function () {
      const directories = ['PROFILE', 'MEETING'];
      const contentTypes = ['image/jpeg', 'image/png'];

      const directory = randomItem(directories);
      const contentType = randomItem(contentTypes);
      const fileSize = randomInt(100, 500) * 1024;
      const extension = contentType.split('/')[1];
      const fileName = `stress_${Date.now()}_${__VU}.${extension}`;

      const res = apiPost('/uploads/presigned-url', {
        directory: directory,
        fileName: fileName,
        contentType: contentType,
        fileSize: fileSize,
      }, true);

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
  }

  thinkTime(0, 1);  // 최소 대기 (고부하 시뮬레이션)
}
