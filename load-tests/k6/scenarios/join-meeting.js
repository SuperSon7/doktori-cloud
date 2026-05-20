/**
 * 시나리오 11: 모임 참여 신청 - 정원 레이스 컨디션 테스트
 *
 * 인증:
 *   - /api/dev/tokens 에서 발급되는 테스트 사용자 토큰을 VU별로 사용
 *
 * 병목 타겟: MeetingService.joinMeeting()
 * - Check-then-Act 패턴: 정원 체크 후 증가 사이에 다른 트랜잭션 끼어들 가능
 * - DB 레벨 락(SELECT FOR UPDATE) 없이 JPA 엔티티 메모리 값으로 비교
 * - 정원 8명 모임에 9~10명 이상 가입될 수 있음
 *
 * 코드 위치: MeetingService.java:213-247
 */
import { group, check, sleep } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';
import { config, thresholds } from '../config.js';
import {
  apiGet,
  apiPostWithToken,
  extractData,
  fetchMultiTokens,
  pickToken,
} from '../helpers.js';

// 커스텀 메트릭
const joinDuration = new Trend('join_meeting_duration', true);
const joinSuccess = new Counter('join_meeting_success');
const joinFailed = new Counter('join_meeting_failed');
const joinConflict = new Counter('join_meeting_conflict');
const capacityExceeded = new Rate('capacity_exceeded');

export const options = {
  scenarios: {
    // 동시 다발적 참여 신청 시뮬레이션
    concurrent_join: {
      executor: 'shared-iterations',
      vus: 50,              // 50명 동시 시도
      iterations: 50,       // 총 50회 요청
      maxDuration: '30s',
    },
  },
  thresholds: {
    join_meeting_duration: ['p(95)<1000'],
    http_req_failed: ['rate<0.5'],  // 동시성 테스트이므로 일부 실패 허용
  },
};

export function setup() {
  // 테스트 대상 모임 확인
  const meetingId = __ENV.TEST_MEETING_ID || config.testData.meetingId;
  const tokens = fetchMultiTokens(Number(__ENV.TOKEN_COUNT || 50));

  console.log(`=== 모임 참여 동시성 테스트 ===`);
  console.log(`대상 모임 ID: ${meetingId}`);
  console.log(`테스트 토큰 수: ${tokens.length}`);

  if (tokens.length === 0) {
    console.error('Dev token 발급에 실패했습니다.');
    return { meetingId: null };
  }

  // 모임 현재 상태 확인
  const res = apiGet(`/meetings/${meetingId}`);
  if (res.status !== 200) {
    console.error(`모임 조회 실패: ${res.status}`);
    return { meetingId: null };
  }

  const data = extractData(res);
  if (data && data.meeting) {
    console.log(`모임명: ${data.meeting.title}`);
    console.log(`정원: ${data.meeting.capacity}`);
    console.log(`현재 인원: ${data.meeting.currentCount}`);
    console.log(`남은 자리: ${data.meeting.capacity - data.meeting.currentCount}`);
    console.log(`상태: ${data.meeting.status}`);

    return {
      meetingId: meetingId,
      initialCapacity: data.meeting.capacity,
      initialCount: data.meeting.currentCount,
      tokens,
    };
  }

  return { meetingId: null };
}

export default function (data) {
  if (!data.meetingId) {
    console.log('테스트 대상 모임이 없습니다.');
    return;
  }

  const token = pickToken(data.tokens);
  if (!token) {
    sleep(1);
    return;
  }

  group('모임 참여 신청', function () {
    const start = Date.now();

    // 참여 신청 API 호출 (VU별 토큰 직접 전달)
    const res = apiPostWithToken(`/meetings/${data.meetingId}/participations`, {}, token);

    const duration = Date.now() - start;
    joinDuration.add(duration);

    if (res.status === 201) {
      // 성공
      joinSuccess.add(1);
      const resData = extractData(res);
      console.log(`VU${__VU}: 참여 성공 - joinRequestId: ${resData?.joinRequestId}`);

    } else if (res.status === 409) {
      // 중복 신청 (JOIN_REQUEST_ALREADY_EXISTS)
      joinConflict.add(1);
      console.log(`VU${__VU}: 중복 신청`);

    } else if (res.status === 400 || res.status === 403) {
      // 정원 초과 (CAPACITY_FULL) 또는 모집 마감
      joinFailed.add(1);
      console.log(`VU${__VU}: 참여 실패 - ${res.status}`);

    } else {
      joinFailed.add(1);
      console.log(`VU${__VU}: 예상치 못한 응답 - ${res.status}`);
    }
  });
}

export function teardown(data) {
  if (!data.meetingId) {
    return;
  }

  // 테스트 후 모임 상태 확인
  const res = apiGet(`/meetings/${data.meetingId}`);
  if (res.status === 200) {
    const finalData = extractData(res);
    if (finalData && finalData.meeting) {
      const expectedMax = data.initialCapacity;
      const finalCount = finalData.meeting.currentCount;

      console.log(`\n=== 테스트 결과 ===`);
      console.log(`초기 인원: ${data.initialCount}`);
      console.log(`최종 인원: ${finalCount}`);
      console.log(`정원: ${expectedMax}`);

      if (finalCount > expectedMax) {
        console.error(`!!! 정원 초과 발생 !!! (${finalCount} > ${expectedMax})`);
        capacityExceeded.add(1);
      } else {
        console.log(`정원 내 정상 처리됨`);
        capacityExceeded.add(0);
      }
    }
  }
}
