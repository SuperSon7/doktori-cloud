/**
 * 독후감 부하 테스트
 *
 * 테스트 항목:
 * 1. 독후감 작성 (POST /meeting-rounds/{roundId}/book-reports)
 * 2. 내 독후감 조회 (GET /meeting-rounds/{roundId}/book-reports/me)
 * 3. 전체 독후감 목록 조회 (GET /meeting-rounds/{roundId}/book-reports)
 *
 * 사전 조건:
 * - JWT_TOKEN 또는 REFRESH_TOKEN 환경변수 필요
 * - TEST_ROUND_ID 환경변수: 테스트할 모임 회차 ID (기본값: config.testData.roundId)
 *
 * 제약사항:
 * - 독후감 내용은 300~1500자 필수
 * - 동일 회차에 1인 1독후감 제한 → 중복 제출 시 409
 */
import { group, check, sleep } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';
import { config, thresholds } from '../config.js';
import {
  apiGet, apiPost, checkResponse,
  thinkTime, initAuth, getAccessToken,
} from '../helpers.js';

const bookReportCreateDuration = new Trend('book_report_create_duration', true);
const bookReportReadDuration = new Trend('book_report_read_duration', true);
const bookReportSuccess = new Counter('book_report_create_success');
const bookReportConflict = new Counter('book_report_create_conflict');
const bookReportRateLimited = new Counter('book_report_rate_limited');

export const options = {
  scenarios: {
    book_report: {
      executor: 'ramping-vus',
      startVUs: 5,
      stages: [
        { duration: '1m', target: 30 },
        { duration: '3m', target: 80 },
        { duration: '2m', target: 80 },
        { duration: '1m', target: 0 },
      ],
    },
  },
  thresholds: {
    book_report_create_duration: ['p(95)<2000'],
    book_report_read_duration: ['p(95)<1000'],
    http_req_failed: ['rate<0.05'],
  },
};

const ROUND_ID = __ENV.TEST_ROUND_ID || config.testData.roundId;

const BOOK_REPORT_CONTENTS = [
  '타인의 감정을 느끼지 못하는 소년 윤재가 세상과 관계를 맺으며 성장해 가는 과정을 담은 소설 아몬드는 감정이란 무엇이며 우리는 어떻게 서로를 이해하게 되는지를 차분히 묻는다. 윤재는 타인의 고통과 기쁨을 즉각적으로 공감하지 못하지만, 다양한 사건과 사람들을 만나며 조금씩 변화하고 관계를 배워 간다. 특히 상처를 가진 또래 친구와의 만남을 통해 서로의 결핍을 이해하게 되는 과정이 인상 깊었다. 이 작품은 감정 표현이 서툰 사람도 결국은 누군가와 연결될 수 있다는 희망을 보여주며, 우리가 당연하게 여기는 공감 능력의 의미를 다시 생각하게 만든다. 감정을 느끼는 방식은 다르지만 결국 사람은 관계 속에서 성장한다는 메시지가 오래 기억에 남는 작품이었다.',
  '사피엔스는 인류의 역사를 거시적 시각으로 바라보며, 우리가 어떻게 지구를 지배하는 종이 되었는지를 설득력 있게 설명한다. 특히 허구를 믿는 능력이 인류 협력의 핵심이라는 주장이 인상적이었다. 화폐, 국가, 종교 같은 개념들이 모두 집단적 상상의 산물이라는 시각은 처음에는 낯설었지만 읽어 나갈수록 설득력 있게 다가왔다. 우리가 자연스럽게 받아들이는 사회 구조들이 사실 언제든 바뀔 수 있는 허구라는 점을 깨닫게 해주는 책이었다. 역사를 통해 현재를 이해하고 미래를 상상할 수 있는 시야를 넓혀준 의미 있는 독서였다.',
  '데미안은 자아 발견의 여정을 다룬 소설로, 에밀 싱클레어가 자신의 내면과 마주하며 성장해 가는 과정을 섬세하게 그려낸다. 선과 악, 빛과 어둠이 공존하는 인간 내면의 복잡성을 탐구하며, 진정한 자기 자신을 찾아가는 여정이 매력적이다. 데미안이라는 인물을 통해 나타나는 이상적 자아의 모습과 싱클레어 내면의 갈등이 읽는 내내 공감을 자아냈다. 우리 모두 각자의 삶에서 자신만의 데미안을 찾아가는 여정 위에 있다는 생각이 들었다. 성장통을 겪고 있는 모든 이에게 깊은 울림을 주는 작품이다.',
];

export function setup() {
  const hasAuth = initAuth();
  if (!hasAuth) {
    console.warn('인증 토큰이 없습니다. JWT_TOKEN 또는 REFRESH_TOKEN 환경변수를 설정하세요.');
  }
  return { hasAuth };
}

export default function (data) {
  if (!data.hasAuth) return;

  const scenario = Math.floor(Math.random() * 100);

  if (scenario < 40) {
    // 40%: 독후감 작성
    group('독후감 작성', function () {
      const content = BOOK_REPORT_CONTENTS[__VU % BOOK_REPORT_CONTENTS.length];
      const start = Date.now();
      const res = apiPost(
        `/meeting-rounds/${ROUND_ID}/book-reports`,
        { content },
        true
      );
      bookReportCreateDuration.add(Date.now() - start);

      if (res.status === 200 || res.status === 201) {
        bookReportSuccess.add(1);
      } else if (res.status === 409) {
        bookReportConflict.add(1);
      } else if (res.status === 429) {
        bookReportRateLimited.add(1);
      }

      check(res, {
        'Book report 201/409/429': (r) => [201, 200, 409, 429].includes(r.status),
      });
    });

  } else if (scenario < 70) {
    // 30%: 내 독후감 조회
    group('내 독후감 조회', function () {
      const start = Date.now();
      const res = apiGet(`/meeting-rounds/${ROUND_ID}/book-reports/me`, {}, true);
      bookReportReadDuration.add(Date.now() - start);
      check(res, {
        'My book report 200/404': (r) => r.status === 200 || r.status === 404,
      });
    });

  } else {
    // 30%: 전체 독후감 목록 조회
    group('독후감 목록 조회', function () {
      const start = Date.now();
      const res = apiGet(`/meeting-rounds/${ROUND_ID}/book-reports`, {}, true);
      bookReportReadDuration.add(Date.now() - start);
      checkResponse(res, 200, 'Book reports list');
    });
  }

  thinkTime(2, 5);
}
