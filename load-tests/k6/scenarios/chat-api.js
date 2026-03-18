/**
 * 채팅 REST API 부하 테스트
 *
 * 테스트 항목:
 * 1. 채팅방 목록 조회 (비인증)
 * 2. 채팅방 생성 (인증)
 * 3. 채팅방 입장 (인증, 멀티 유저)
 * 4. 채팅방 상세 조회 (인증)
 * 5. 투표 생성/조회 (인증)
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
    http_req_failed: ['rate<0.05'],
  },
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

  if (scenario <= 40) {
    // 40%: 채팅방 목록 조회 (비인증 가능)
    group('채팅방 목록 조회', function () {
      const start = Date.now();
      const res = apiGet('/chat-rooms?size=10');
      chatRoomListDuration.add(Date.now() - start);
      checkResponse(res, 200, 'Chat room list');

      const data = extractData(res);
      if (token && data && data.items && data.items.length > 0) {
        thinkTime(1, 2);
        const roomId = randomItem(data.items).chatRoomId || randomItem(data.items).id;
        if (roomId) {
          apiGetWithToken(`/chat-rooms/${roomId}`, token);
        }
      }
    });

  } else if (scenario <= 60 && token) {
    // 20%: 채팅방 생성
    group('채팅방 생성', function () {
      const quizChoices = [
        { question: '좋아하는 장르는?', options: ['소설', '에세이', '시'] },
        { question: '독서 시간대는?', options: ['아침', '오후', '밤'] },
        { question: '선호하는 모임 형태는?', options: ['온라인', '오프라인', '둘 다'] },
      ];
      const quiz = randomItem(quizChoices);

      const payload = {
        title: `[부하테스트] 채팅방 VU${__VU}-${Date.now()}`,
        description: '부하테스트용 채팅방입니다.',
        capacity: randomInt(2, 8),
        quizQuestion: quiz.question,
        quizOptions: quiz.options,
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

  } else if (scenario <= 85 && token) {
    // 25%: 채팅방 입장
    group('채팅방 입장', function () {
      // 먼저 목록에서 방 선택
      const listRes = apiGet('/chat-rooms?size=20');
      const listData = extractData(listRes);

      if (listData && listData.items && listData.items.length > 0) {
        const room = randomItem(listData.items);
        const roomId = room.chatRoomId || room.id;
        if (!roomId) return;

        thinkTime(1, 2);

        const positions = ['AGREE', 'DISAGREE'];
        const position = randomItem(positions);

        const start = Date.now();
        const res = apiPostWithToken(`/chat-rooms/${roomId}/members`, {
          position: position,
        }, token);
        chatRoomJoinDuration.add(Date.now() - start);

        if (res.status === 200 || res.status === 201) {
          chatRoomJoinSuccess.add(1);
        } else if (res.status === 409) {
          chatRoomJoinConflict.add(1);  // 이미 참여 중
        }
      }
    });

  } else {
    // 15%: 채팅방 목록 + 상세 (비인증 포함)
    group('채팅방 탐색', function () {
      apiGet('/chat-rooms?size=10');
      thinkTime(2, 4);
      apiGet('/chat-rooms?size=10&cursor=0');
    });
  }

  thinkTime(1, 3);
}