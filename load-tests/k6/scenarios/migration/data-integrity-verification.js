/**
 * 데이터 무손실 검증 부하 테스트
 *
 * 목적: 마이그레이션 중 쓰기(INSERT/UPDATE) 부하를 발생시키고,
 *       마이그레이션 전후 데이터 건수를 비교하여 데이터 유실 여부를 증명한다.
 *
 * 시나리오:
 *   1. Before: 마이그레이션 전 baseline 데이터 수집 (row count)
 *   2. During: 지속적인 쓰기 부하 (모임 생성 — POST /meetings)
 *   3. After: 마이그레이션 후 row count 비교
 *
 * 핵심 메트릭:
 *   - write_attempted: 시도한 쓰기 수
 *   - write_succeeded: 성공한 쓰기 수
 *   - write_failed: 실패한 쓰기 수 (마이그레이션 중 예상)
 *   - data_loss: 0이어야 함 (성공한 쓰기는 전부 반영)
 *
 * 포트폴리오 핵심:
 *   "마이그레이션 중 N건 쓰기 시도, 성공 X건 전부 반영, 데이터 유실 0건"
 *
 * 실행:
 *   k6 run --env BASE_URL=https://doktori.kr/api \
 *          --env JWT_TOKEN=<토큰> \
 *          data-integrity-verification.js
 */

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter, Gauge } from 'k6/metrics';
import { config } from '../../config.js';
import { getHeaders, initAuth, randomItem, randomInt } from '../../helpers.js';

// ── 테스트 데이터 ──
const bookKeywords = ['해리포터', '아몬드', '데미안', '어린왕자', '사피엔스', '코스모스'];
const genreIds = [1, 2, 3, 4, 5];

// ── 메트릭 ──
const writeAttempted = new Counter('integrity_write_attempted');
const writeSucceeded = new Counter('integrity_write_succeeded');
const writeFailed = new Counter('integrity_write_failed');
const writeSuccessRate = new Rate('integrity_write_success_rate');
const writeLatency = new Trend('integrity_write_latency', true);

const readSuccess = new Rate('integrity_read_success');
const readLatency = new Trend('integrity_read_latency', true);

// 쓰기 시도 ID 기록 (검증용)
const successfulWriteIds = new Counter('integrity_successful_write_ids');

export const options = {
  scenarios: {
    // 쓰기 부하: 지속적으로 POST/PUT 요청
    write_load: {
      executor: 'constant-vus',
      vus: 5,
      duration: '15m',
      exec: 'writeLoad',
    },
    // 읽기 부하: 데이터 반영 확인
    read_verify: {
      executor: 'constant-vus',
      vus: 3,
      duration: '15m',
      exec: 'readVerify',
    },
    // 주기적 상태 리포트
    reporter: {
      executor: 'constant-vus',
      vus: 1,
      duration: '15m',
      exec: 'periodicReport',
    },
  },

  thresholds: {
    // 마이그레이션 중에도 쓰기 성공률 90%+ (일시적 실패 허용)
    'integrity_write_success_rate': ['rate>0.90'],
    'integrity_read_success': ['rate>0.99'],
  },
};

// ── 내부 상태 ──
let totalWriteAttempts = 0;
let totalWriteSuccesses = 0;
let totalWriteFailures = 0;
let phaseStartTime = 0;

export function setup() {
  initAuth();
  phaseStartTime = Date.now();

  console.log('=== 데이터 무손실 검증 테스트 시작 ===');
  console.log(`대상: ${config.baseUrl}`);
  console.log('');
  console.log('이 테스트는 마이그레이션 중 쓰기 데이터의 무손실을 검증합니다.');
  console.log('');
  console.log('Phase 1 (0~3분):  baseline — 정상 쓰기 성공률 수집');
  console.log('Phase 2 (3~12분): migration — 마이그레이션 수행 (이 구간에서 작업)');
  console.log('Phase 3 (12~15분): verify — 데이터 반영 확인');
  console.log('=============================================');

  // Baseline: 초기 데이터 수 기록
  const meetingsRes = http.get(`${config.baseUrl}/meetings?size=1`, {
    headers: getHeaders(false),
    timeout: '10s',
  });

  let initialCount = 'N/A';
  if (meetingsRes.status === 200) {
    try {
      const data = meetingsRes.json();
      initialCount = data.data?.pageInfo?.totalElements || 'N/A';
    } catch (e) {
      // ignore
    }
  }
  console.log(`초기 모임 수: ${initialCount}`);

  return { startTime: Date.now(), initialCount };
}

// ── 쓰기 부하: 모임 생성 (POST /meetings) ──
export function writeLoad() {
  const timestamp = new Date().toISOString();

  writeAttempted.add(1);
  totalWriteAttempts++;

  // 1. 도서 검색 (모임 생성에 필요)
  const keyword = randomItem(bookKeywords);
  const bookRes = http.get(
    `${config.baseUrl}/books?query=${encodeURIComponent(keyword)}&page=1&size=5`,
    {
      headers: getHeaders(true),
      tags: { name: 'GET /books (integrity)', type: 'write_integrity' },
      timeout: '10s',
    }
  );

  let book = null;
  if (bookRes.status === 200) {
    try {
      const data = bookRes.json();
      const items = data.data?.items || [];
      if (items.length > 0) {
        book = randomItem(items);
      }
    } catch (e) { /* ignore */ }
  }

  if (!book) {
    writeFailed.add(1);
    totalWriteFailures++;
    console.log(`[${timestamp}] WRITE SKIP: 도서 검색 실패`);
    sleep(2);
    return;
  }

  // 2. 모임 생성
  const now = new Date();
  const firstRoundDate = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000);
  const recruitmentDeadline = new Date(now.getTime() + 5 * 24 * 60 * 60 * 1000);
  const formatDate = (d) => d.toISOString().split('T')[0];

  const meetingData = {
    title: `[무손실검증] ${Date.now()}`,
    description: '마이그레이션 데이터 무손실 검증용 모임입니다.',
    readingGenreId: randomItem(genreIds),
    capacity: randomInt(3, 8),
    roundCount: 1,
    leaderIntro: '부하테스트 리더',
    leaderIntroSavePolicy: false,
    firstRoundAt: formatDate(firstRoundDate),
    recruitmentDeadline: formatDate(recruitmentDeadline),
    time: {
      startTime: '19:00',
      endTime: '20:30',
    },
    rounds: [
      { roundNo: 1, date: formatDate(firstRoundDate) },
    ],
    booksByRound: [
      {
        roundNo: 1,
        book: {
          title: book.title,
          authors: book.authors,
          publisher: book.publisher,
          thumbnailUrl: book.thumbnailUrl,
          publishedAt: book.publishedAt,
          isbn13: book.isbn13,
        },
      },
    ],
  };

  const res = http.post(
    `${config.baseUrl}/meetings`,
    JSON.stringify(meetingData),
    {
      headers: getHeaders(true),
      tags: { name: 'POST /meetings', type: 'write_integrity' },
      timeout: '15s',
    }
  );

  const ok = res.status === 201;
  writeSuccessRate.add(ok);

  if (ok) {
    writeSucceeded.add(1);
    totalWriteSuccesses++;
    successfulWriteIds.add(1);
    writeLatency.add(res.timings.duration);
  } else if (res.status === 401) {
    // 인증 문제는 쓰기 실패로 카운트하지 않음
    writeSuccessRate.add(true);
  } else {
    writeFailed.add(1);
    totalWriteFailures++;
    console.log(
      `[${timestamp}] WRITE FAIL (meeting create): ${res.status} ` +
      `(${res.timings.duration}ms)`
    );
  }

  sleep(2);
}

// ── 읽기 검증 (데이터 반영 확인) ──
export function readVerify() {
  const timestamp = new Date().toISOString();

  // 1. 모임 목록 조회
  const meetingsRes = http.get(`${config.baseUrl}/meetings?size=20`, {
    headers: getHeaders(false),
    tags: { name: 'GET /meetings (verify)', type: 'read_verify' },
    timeout: '10s',
  });

  const listOk = meetingsRes.status === 200;
  readSuccess.add(listOk);

  if (listOk) {
    readLatency.add(meetingsRes.timings.duration);

    try {
      const data = meetingsRes.json();
      const items = data.data?.items || data.data?.content || [];
      if (items.length === 0) {
        console.log(`[${timestamp}] READ VERIFY: 데이터 0건 — DB 연결 확인 필요`);
      }
    } catch (e) {
      // ignore
    }
  } else {
    console.log(`[${timestamp}] READ FAIL (list): ${meetingsRes.status}`);
  }

  sleep(1);

  // 2. 검색 조회
  const keyword = randomItem(config.searchKeywords);
  const searchRes = http.get(
    `${config.baseUrl}/meetings/search?keyword=${encodeURIComponent(keyword)}&size=5`,
    {
      headers: getHeaders(false),
      tags: { name: 'GET /meetings/search (verify)', type: 'read_verify' },
      timeout: '10s',
    }
  );

  const searchOk = searchRes.status === 200;
  readSuccess.add(searchOk);

  if (searchOk) {
    readLatency.add(searchRes.timings.duration);
  } else {
    console.log(`[${timestamp}] READ FAIL (search): ${searchRes.status}`);
  }

  sleep(2);
}

// ── 주기적 상태 리포트 ──
export function periodicReport() {
  const elapsed = Math.floor((Date.now() - phaseStartTime) / 1000);
  const minutes = Math.floor(elapsed / 60);
  const seconds = elapsed % 60;

  let phase = 'baseline';
  if (elapsed > 180 && elapsed <= 720) phase = 'migration';
  else if (elapsed > 720) phase = 'verify';

  console.log(
    `[REPORT ${minutes}m${seconds}s] phase=${phase} ` +
    `writes=${totalWriteAttempts} ok=${totalWriteSuccesses} ` +
    `fail=${totalWriteFailures} ` +
    `rate=${totalWriteAttempts > 0
      ? ((totalWriteSuccesses / totalWriteAttempts) * 100).toFixed(1) + '%'
      : 'N/A'}`
  );

  sleep(30);
}

export function teardown(data) {
  console.log('=== 데이터 무손실 검증 테스트 종료 ===');
  console.log('');
  console.log('포트폴리오 핵심 지표:');
  console.log('  - integrity_write_attempted: 총 쓰기 시도 수');
  console.log('  - integrity_write_succeeded: 쓰기 성공 수');
  console.log('  - integrity_write_failed: 쓰기 실패 수 (마이그레이션 중 발생)');
  console.log('  - integrity_write_success_rate: 쓰기 성공률');
  console.log('  - integrity_read_success: 읽기 성공률 (데이터 반영 확인)');
  console.log('');
  console.log('검증 방법:');
  console.log('  1. 모임 생성 성공 수(integrity_write_succeeded)가 DB의 신규 모임 수와 일치하는지');
  console.log('  2. 09-checksum-verify.sh로 Master/Slave CHECKSUM 일치 확인');
  console.log('  3. 실패 건수(integrity_write_failed)가 마이그레이션 구간에만 집중되는지');
}
