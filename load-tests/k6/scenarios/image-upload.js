/**
 * 이미지 업로드 부하 테스트
 *
 * 흐름:
 * 1. POST /uploads/presigned-url → S3 Presigned URL 발급
 * 2. PUT presignedUrl → S3에 실제 이미지 업로드
 */
import http from 'k6/http';
import { group, check, sleep } from 'k6';
import { Trend, Counter } from 'k6/metrics';
import { config } from '../config.js';
import { apiPost, checkResponse, extractData, initAuth, randomItem, randomInt } from '../helpers.js';

// 커스텀 메트릭
const presignDuration = new Trend('presign_url_duration', true);
const s3UploadDuration = new Trend('s3_upload_duration', true);
const uploadSuccess = new Counter('upload_success');
const uploadFailed = new Counter('upload_failed');

export const options = {
  scenarios: {
    image_upload: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '1m', target: 10 },
        { duration: '2m', target: 30 },
        { duration: '2m', target: 50 },
        { duration: '1m', target: 0 },
      ],
    },
  },
  thresholds: {
    presign_url_duration: ['p(95)<500'],
    s3_upload_duration: ['p(95)<3000'],  // S3 업로드는 좀 더 여유
    http_req_failed: ['rate<0.05'],
  },
};

// 테스트용 더미 이미지 데이터 생성 (지정된 크기)
function generateDummyImage(sizeBytes) {
  // 간단한 바이너리 데이터 생성
  const data = new Uint8Array(sizeBytes);
  for (let i = 0; i < sizeBytes; i++) {
    data[i] = Math.floor(Math.random() * 256);
  }
  return data.buffer;
}

// 파일 크기 옵션 (바이트)
const fileSizes = [
  100 * 1024,      // 100KB
  500 * 1024,      // 500KB
  1024 * 1024,     // 1MB
  2 * 1024 * 1024, // 2MB
];

// 디렉토리 옵션
const directories = ['PROFILE', 'MEETING'];

// 콘텐츠 타입
const contentTypes = ['image/jpeg', 'image/png', 'image/webp'];

export function setup() {
  const hasAuth = initAuth();
  if (!hasAuth) {
    console.error('이미지 업로드는 인증이 필요합니다. JWT_TOKEN 또는 REFRESH_TOKEN을 설정하세요.');
  }
  return { hasAuth };
}

export default function (data) {
  if (!data.hasAuth) {
    sleep(1);
    return;
  }

  const directory = randomItem(directories);
  const contentType = randomItem(contentTypes);
  const fileSize = randomItem(fileSizes);
  const extension = contentType.split('/')[1];
  const fileName = `loadtest_${Date.now()}_${__VU}.${extension}`;

  group('이미지 업로드', function () {
    // 1. Presigned URL 발급
    let presignedUrl = null;

    group('Presigned URL 발급', function () {
      const start = Date.now();

      const res = apiPost('/uploads/presigned-url', {
        directory: directory,
        fileName: fileName,
        contentType: contentType,
        fileSize: fileSize,
      }, true);

      const duration = Date.now() - start;
      presignDuration.add(duration);

      const success = check(res, {
        'Presign - status 200': (r) => r.status === 200,
        'Presign - has presignedUrl': (r) => {
          const data = extractData(r);
          return data && data.presignedUrl;
        },
      });

      if (success) {
        const resData = extractData(res);
        presignedUrl = resData.presignedUrl;
      }
    });

    // 2. S3에 실제 업로드
    if (presignedUrl) {
      group('S3 업로드', function () {
        const imageData = generateDummyImage(fileSize);
        const start = Date.now();

        const res = http.put(presignedUrl, imageData, {
          headers: {
            'Content-Type': contentType,
          },
          tags: { name: 's3_upload' },
        });

        const duration = Date.now() - start;
        s3UploadDuration.add(duration);

        const success = check(res, {
          'S3 Upload - status 200': (r) => r.status === 200,
        });

        if (success) {
          uploadSuccess.add(1);
          console.log(`업로드 성공: ${directory}/${fileName} (${(fileSize / 1024).toFixed(0)}KB)`);
        } else {
          uploadFailed.add(1);
          console.log(`업로드 실패: ${res.status}`);
        }
      });
    } else {
      uploadFailed.add(1);
    }
  });

  sleep(randomInt(1, 3));
}
