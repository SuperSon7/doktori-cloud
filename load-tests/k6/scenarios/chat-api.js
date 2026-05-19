/**
 * 채팅 REST API 부하 테스트
 *
 * 테스트 항목:
 * 1. 채팅방 목록 조회 (비인증)
 * 2. 채팅방 생성 (인증)
 * 3. 채팅방 입장 (인증, 멀티 유저)
 * 4. 채팅방 상세 조회 (인증)
 * 5. 메시지 히스토리 조회 (인증)
 * 6. 투표 생성/조회 (인증)
 * 7. 채팅방 요약 조회 (인증)
 *
 * 테스트 포인트:
 * - Chat Pod (chat-svc:8081) REST 엔드포인트 성능
 * - K8s HTTPRoute /api/chat-rooms/ → chat-svc (75s timeout)
 * - 채팅방 생성 트랜잭션 + 퀴즈 질문 처리
 * - 동시 입장 시 정원 초과 방지
 */
import { group, check, sleep } from 'k6';
import { Trend, Counter } from 'k6/metrics';
import { config } from '../config.js';
import {
  apiGet, extractData, checkResponse,
  thinkTime, randomItem, randomInt,
  fetchMultiTokens, pickToken,
  apiGetWithToken, apiPostWithToken,
} from '../helpers.js';

// 메트릭
const chatRoomListDuration = new Trend('chat_room_list_duration', true);
const chatRoomCreateDuration = new Trend('chat_room_create_duration', true);
const chatRoomJoinDuration = new Trend('chat_room_join_duration', true);
const chatMessagesDuration = new Trend('chat_messages_duration', true);
const chatVoteDuration = new Trend('chat_vote_duration', true);
const chatRoomCreateSuccess = new Counter('chat_room_create_success');
const chatRoomJoinSuccess = new Counter('chat_room_join_success');
const chatRoomJoinConflict = new Counter('chat_room_join_conflict');

export const options = {
  scenarios: {
    chat_api: {
      executor: 'ramping-vus',
      startVUs: 5,
      stages: [
        { duration: '1m', target: 20 },
        { duration: '3m', target: 50 },
        { duration: '3m', target: 100 },
        { duration: '2m', target: 50 },
        { duration: '1m', target: 0 },
      ],
    },
  },
  thresholds: {
    chat_room_list_duration: ['p(95)<1000'],
    chat_room_create_duration: ['p(95)<2000'],
    chat_room_join_duration: ['p(95)<1000'],
    chat_messages_duration: ['p(95)<1000'],
    chat_vote_duration: ['p(95)<500'],
    http_req_failed: ['rate<0.05'],
  },
};

const DEBATE_TOPICS = [
  { topic: 'AI가 인간의 일자리를 대체할 수 있는가?', description: 'AI 기술 발전에 따른 고용 시장 변화를 토론합니다.' },
  { topic: '독서는 학업 성취에 영향을 미치는가?', description: '독서 습관과 학습 능력의 관계를 탐구합니다.' },
  { topic: '전자책이 종이책을 완전히 대체할 수 있는가?', description: '디지털 독서 문화의 발전 가능성을 논의합니다.' },
  { topic: '소셜 미디어는 현대인의 독서량을 줄이는가?', description: '미디어 환경 변화와 독서 문화의 관계를 탐구합니다.' },
];

const SAMPLE_QUIZ = {
  question: '대한민국의 수도는 어디인가요?',
  choices: [
    { choiceNumber: 1, text: '서울' },
    { choiceNumber: 2, text: '부산' },
    { choiceNumber: 3, text: '인천' },
    { choiceNumber: 4, text: '대구' },
  ],
  correctChoiceNumber: 1,
};

export function setup() {
  const tokens = fetchMultiTokens();
  if (tokens.length === 0) {
    console.error('채팅 API 테스트에 토큰이 필요합니다.');
  }
  return { tokens };
}

export default function (data) {
  const token = pickToken(data.tokens);
  const scenario = randomInt(1, 100);

  if (scenario <= 30) {
    // 30%: 채팅방 목록 + 상세 조회 (비인증 가능)
    group('채팅방 탐색', function () {
      const start = Date.now();
      const res = apiGet('/chat-rooms?size=10');
      chatRoomListDuration.add(Date.now() - start);
      checkResponse(res, 200, 'Chat room list');

      const roomData = extractData(res);
      if (token && roomData && roomData.items && roomData.items.length > 0) {
        thinkTime(1, 2);
        const room = randomItem(roomData.items);
        const roomId = room.chatRoomId || room.id;
        if (roomId) {
          apiGetWithToken(`/chat-rooms/${roomId}`, token);
        }
      }
    });

  } else if (scenario <= 50) {
    // 20%: 메시지 히스토리 조회
    group('메시지 히스토리', function () {
      const listRes = apiGet('/chat-rooms?size=20');
      const listData = extractData(listRes);

      if (token && listData && listData.items && listData.items.length > 0) {
        const room = randomItem(listData.items);
        const roomId = room.chatRoomId || room.id;
        if (!roomId) return;

        thinkTime(1, 2);
        const start = Date.now();
        const res = apiGetWithToken(`/chat-rooms/${roomId}/messages?size=20`, token);
        chatMessagesDuration.add(Date.now() - start);
        check(res, {
          'Messages 200': (r) => r.status === 200,
        });
      }
    });

  } else if (scenario <= 65 && token) {
    // 15%: 채팅방 생성
    group('채팅방 생성', function () {
      const debate = randomItem(DEBATE_TOPICS);
      const positions = ['AGREE', 'DISAGREE'];

      const payload = {
        topic: `[부하테스트] ${debate.topic} VU${__VU}`,
        description: debate.description,
        isbn: '9781234567890',
        capacity: randomItem([2, 4, 6]),
        position: randomItem(positions),
        quiz: SAMPLE_QUIZ,
      };

      const start = Date.now();
      const res = apiPostWithToken('/chat-rooms', payload, token);
      chatRoomCreateDuration.add(Date.now() - start);

      const success = check(res, {
        'Chat room create 200/201': (r) => r.status === 200 || r.status === 201,
      });

      if (success) {
        chatRoomCreateSuccess.add(1);
      }
    });

  } else if (scenario <= 80 && token) {
    // 15%: 채팅방 입장
    group('채팅방 입장', function () {
      const listRes = apiGet('/chat-rooms?size=20');
      const listData = extractData(listRes);

      if (listData && listData.items && listData.items.length > 0) {
        const room = randomItem(listData.items);
        const roomId = room.chatRoomId || room.id;
        if (!roomId) return;

        thinkTime(1, 2);

        const start = Date.now();
        const res = apiPostWithToken(`/chat-rooms/${roomId}/members`, {
          position: randomItem(['AGREE', 'DISAGREE']),
          quizAnswer: randomInt(1, 4),
        }, token);
        chatRoomJoinDuration.add(Date.now() - start);

        if (res.status === 200 || res.status === 201) {
          chatRoomJoinSuccess.add(1);
        } else if (res.status === 409) {
          chatRoomJoinConflict.add(1);
        }
      }
    });

  } else if (token) {
    // 20%: 투표 생성/조회 + 요약
    group('투표 및 요약', function () {
      const listRes = apiGet('/chat-rooms?size=20');
      const listData = extractData(listRes);

      if (listData && listData.items && listData.items.length > 0) {
        const room = randomItem(listData.items);
        const roomId = room.chatRoomId || room.id;
        if (!roomId) return;

        thinkTime(1, 2);

        // 투표
        const voteStart = Date.now();
        const voteRes = apiPostWithToken(`/chat-rooms/${roomId}/vote`, {
          choice: randomItem(['AGREE', 'DISAGREE']),
        }, token);
        chatVoteDuration.add(Date.now() - voteStart);
        check(voteRes, {
          'Vote 204/409': (r) => r.status === 204 || r.status === 409,
        });

        thinkTime(1, 2);

        // 투표 결과 조회
        apiGetWithToken(`/chat-rooms/${roomId}/vote`, token);

        thinkTime(1, 2);

        // 요약 조회
        const summaryRes = apiGetWithToken(`/chat-rooms/${roomId}/summary`, token);
        check(summaryRes, {
          'Summary 200': (r) => r.status === 200,
        });
      }
    });
  }

  thinkTime(1, 3);
}
