// 환경 설정
export const config = {
  // 기본 URL (환경변수로 오버라이드 가능)
  baseUrl: __ENV.BASE_URL || 'http://localhost:8080/api',

  // Access Token (런타임에 자동 갱신됨)
  accessToken: __ENV.JWT_TOKEN || null,

  // Refresh Token (브라우저 개발자도구 → Application → Cookies → refreshToken 값)
  refreshToken: __ENV.REFRESH_TOKEN || '',

  // 테스트 데이터 ID (환경에 맞게 수정)
  testData: {
    meetingId: __ENV.TEST_MEETING_ID || 1,
    roundId: __ENV.TEST_ROUND_ID || 1,
    notificationId: __ENV.TEST_NOTIFICATION_ID || 1,
  },

  // 검색 키워드 풀
  searchKeywords: [
    '소설', '에세이', '경제', '자기계발', '심리학',
    '역사', '과학', '철학', '시', '수필',
    '해리포터', '아몬드', '데미안', '어린왕자', '1984',
    '사피엔스', '총균쇠', '코스모스', '이기적유전자', '침묵의봄',
    // 짧은 검색어 (인덱스 성능 테스트용)
    '책', '삶', '사랑', '꿈', '별',
  ],

  // 장르 코드
  genreCodes: [
    'NOVEL', 'ESSAY', 'ECONOMY', 'SELF_HELP', 'PSYCHOLOGY',
    'HISTORY', 'SCIENCE', 'PHILOSOPHY', 'POETRY', 'HUMANITIES',
  ],

  // 요일 필터
  dayOfWeeks: ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'],
};

// SLO 임계값
export const thresholds = {
  // 읽기 API
  read: {
    p95: 500,   // ms
    p99: 1500,  // ms
  },
  // 쓰기 API
  write: {
    p95: 1000,  // ms
    p99: 2000,  // ms
  },
  // 에러율
  errorRate: 0.01,  // 1%
};

// 부하 단계 정의
export const loadStages = {
  smoke: [
    { duration: '1m', target: 5 },
  ],
  load: [
    { duration: '2m', target: 50 },   // ramp-up
    { duration: '5m', target: 50 },   // steady
    { duration: '2m', target: 100 },  // ramp-up
    { duration: '5m', target: 100 },  // steady
    { duration: '2m', target: 0 },    // ramp-down
  ],
  stress: [
    { duration: '2m', target: 100 },
    { duration: '3m', target: 200 },
    { duration: '3m', target: 300 },
    { duration: '3m', target: 500 },
    { duration: '2m', target: 0 },
  ],
  spike: [
    { duration: '1m', target: 100 },
    { duration: '30s', target: 500 }, // spike
    { duration: '1m', target: 500 },
    { duration: '30s', target: 100 }, // recovery
    { duration: '2m', target: 100 },
  ],
  soak: [
    { duration: '5m', target: 50 },   // ramp-up
    { duration: '55m', target: 50 },  // steady (1시간)
    { duration: '5m', target: 0 },    // ramp-down
  ],
};
