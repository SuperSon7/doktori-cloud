/**
 * 모임 라이프사이클 부하 테스트
 *
 * 실제 서비스 패턴 시뮬레이션:
 *   Phase 1 — 접속 스파이크 (1분): 모임 시작 전 동시 접속 + WS 연결
 *   Phase 2 — 토론 진행 (30분): WS 메시지 지속 전송 + REST API 동시 사용
 *   Phase 3 — 종료 (30초): 연결 해제
 *
 * 도메인 규칙:
 *   - 최대 6인 채팅방, 30분 제한시간
 *   - 찬성/반대 포지션 토론
 *   - 정해진 시간에 동시 시작
 *
 * 시나리오 구성 (병렬 실행):
 *   ws_chat    — WebSocket STOMP 연결 + 30분 메시지 전송 (실시간 채팅)
 *   http_api   — REST API 부하 (모임 조회, 알림, 채팅방 REST)
 *
 * 검증 포인트:
 *   - Connection Spike: 동시 WS 핸드쉐이크 수용량
 *   - 세션 유지: 30분간 WS 연결 안정성 + 메시지 지연
 *   - 복합 부하: WS + REST 동시에 서비스가 버티는지
 *   - 가용성: 에러율 < 1%
 */
import ws from 'k6/ws';
import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Counter, Trend, Gauge, Rate } from 'k6/metrics';
import { config } from '../config.js';
import {
  fetchMultiTokens, pickToken, randomInt, randomItem,
  apiGet, extractData, thinkTime,
  apiGetWithToken, apiPostWithToken, apiPutWithToken,
} from '../helpers.js';

// ── 메트릭 ──
const wsConnectDuration = new Trend('ws_connect_duration', true);
const wsMessageSent = new Counter('ws_message_sent');
const wsMessageReceived = new Counter('ws_message_received');
const wsActiveConnections = new Gauge('ws_active_connections');
const wsConnectSuccess = new Counter('ws_connect_success');
const wsConnectFailed = new Counter('ws_connect_failed');
const wsMessageLatency = new Trend('ws_message_latency', true);
const wsSessionDuration = new Trend('ws_session_duration', true);
const wsErrorRate = new Rate('ws_errors');
const httpApiDuration = new Trend('http_api_duration', true);

// ── 설정 ──
const WS_URL = __ENV.WS_URL || 'wss://api.doktori.kr/ws/chat';
const CHAT_ROOM_IDS = (__ENV.CHAT_ROOM_IDS || '1,2,3').split(',').map(Number);
const SESSION_DURATION_SEC = Number(__ENV.SESSION_DURATION || 1800); // 30분
const MSG_INTERVAL_SEC = Number(__ENV.MSG_INTERVAL || 5);           // 5초마다 메시지

// 토론 메시지 풀 (실제 독서 토론 느낌)
const CHAT_MESSAGES = [
  '이 부분에서 작가의 의도가 뭘까요?',
  '저는 주인공의 선택에 공감했어요',
  '그 해석도 가능하네요, 저는 다르게 봤는데',
  '이 장면이 가장 인상 깊었습니다',
  '작가가 이전 작품에서도 비슷한 주제를 다뤘죠',
  '결말이 좀 아쉬웠어요',
  '반전이 예상 밖이었어요',
  '문체가 독특해서 좋았습니다',
  '다음 회차에서 다른 책도 읽어보고 싶어요',
  '이 캐릭터의 성장이 인상적이었어요',
  '배경 설정이 현실적이라 몰입이 잘 됐어요',
  '번역본이랑 원본의 뉘앙스가 좀 다른 것 같아요',
  '저도 찬성이에요, 그 관점이 맞는 것 같아요',
  '반대 의견인데, 이런 시각도 있지 않을까요?',
  '시간이 벌써 이렇게 됐네요',
];

export const options = {
  scenarios: {
    // WebSocket 채팅 — 점진적 접속 + 세션 유지 + 메시지 전송
    // ramping-vus: 새 VU가 계속 연결 → 새 Pod에도 분산
    // gracefulRampDown/Stop을 길게 → 기존 연결이 세션 끝까지 유지
    ws_chat: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '1m', target: 100 },                        // 스파이크 접속
        { duration: `${SESSION_DURATION_SEC}s`, target: 100 },  // 토론 유지
        { duration: '30s', target: 0 },                          // 종료
      ],
      gracefulRampDown: `${SESSION_DURATION_SEC}s`, // ramp-down 시 기존 VU가 세션 끝까지 유지
      gracefulStop: `${SESSION_DURATION_SEC}s`,
      exec: 'wsChat',
    },
    // REST API 동시 부하 — WS와 병렬로 세션 시간 동안 반복
    http_api: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '1m', target: 50 },
        { duration: `${SESSION_DURATION_SEC}s`, target: 50 },
        { duration: '30s', target: 0 },
      ],
      exec: 'httpApi',
      startTime: '30s',
    },
  },
  thresholds: {
    ws_connect_duration: ['p(95)<3000'],
    ws_message_latency: ['p(95)<500'],   // 메시지 전달 500ms 이내
    ws_errors: ['rate<0.05'],
    http_req_duration: ['p(95)<1000'],
    http_req_failed: ['rate<0.01'],      // 가용성: 1% 미만
  },
};

export function setup() {
  const tokens = fetchMultiTokens();
  if (tokens.length === 0) {
    console.error('토큰이 필요합니다.');
  }
  return { tokens };
}

// ── STOMP 헬퍼 ──
function stompConnect(token) {
  return `CONNECT\nAuthorization:Bearer ${token}\naccept-version:1.2\nheart-beat:10000,10000\n\n\0`;
}

function stompSubscribe(destination, id) {
  return `SUBSCRIBE\nid:sub-${id}\ndestination:${destination}\n\n\0`;
}

function stompSend(destination, body) {
  return `SEND\ndestination:${destination}\ncontent-type:application/json\n\n${JSON.stringify(body)}\0`;
}

// ── 시나리오 1: WebSocket 채팅 (30분 유지) ──
export function wsChat(data) {
  const tokens = data.tokens;
  if (!tokens || tokens.length === 0) { sleep(1); return; }

  const token = tokens[__VU % tokens.length];
  const roomId = CHAT_ROOM_IDS[__VU % CHAT_ROOM_IDS.length];
  const position = __VU % 2 === 0 ? 'AGREE' : 'DISAGREE';
  const connectStart = Date.now();
  const sessionStart = Date.now();

  const res = ws.connect(WS_URL, {
    headers: { 'Authorization': `Bearer ${token}` },
    tags: { name: 'ws_lifecycle' },
  }, function (socket) {
    wsConnectDuration.add(Date.now() - connectStart);
    wsConnectSuccess.add(1);
    wsActiveConnections.add(1);

    let connected = false;
    let messagesSent = 0;

    // STOMP CONNECT
    socket.send(stompConnect(token));

    socket.on('message', function (msg) {
      wsMessageReceived.add(1);

      if (msg.startsWith('CONNECTED') && !connected) {
        connected = true;
        socket.send(stompSubscribe(`/topic/chat-rooms/${roomId}/messages`, roomId));
      }

      if (msg.startsWith('MESSAGE')) {
        try {
          const body = msg.split('\n\n')[1];
          if (body) {
            const parsed = JSON.parse(body.replace('\0', ''));
            if (parsed.timestamp) {
              const latency = Date.now() - new Date(parsed.timestamp).getTime();
              if (latency > 0 && latency < 60000) {
                wsMessageLatency.add(latency);
              }
            }
          }
        } catch (e) { /* 파싱 실패 무시 */ }
      }
    });

    socket.on('error', function (e) {
      wsErrorRate.add(1);
    });

    // 주기적 메시지 전송 (setInterval로 세션 동안 유지)
    socket.setInterval(function () {
      if (!connected) return;

      const message = randomItem(CHAT_MESSAGES);
      socket.send(stompSend(`/app/chat-rooms/${roomId}/messages`, {
        content: `[${position}] ${message}`,
        type: 'TEXT',
      }));
      wsMessageSent.add(1);
      messagesSent++;
    }, MSG_INTERVAL_SEC * 1000);

    // 세션 시간 후 종료
    socket.setTimeout(function () {
      wsSessionDuration.add(Date.now() - sessionStart);
      wsActiveConnections.add(-1);
      socket.close();
    }, SESSION_DURATION_SEC * 1000);
  });

  const success = check(res, {
    'WS connected (101)': (r) => r && r.status === 101,
  });

  if (!success) {
    wsConnectFailed.add(1);
    wsErrorRate.add(1);
  }
}

// ── 시나리오 2: REST API 동시 부하 ──
export function httpApi(data) {
  const token = pickToken(data.tokens);
  if (!token) { sleep(1); return; }

  const scenario = randomInt(1, 100);
  const start = Date.now();

  if (scenario <= 30) {
    // 30%: 채팅방 REST
    group('채팅방 조회', function () {
      const listRes = apiGet('/chat-rooms?size=10');
      const listData = extractData(listRes);

      if (listData && listData.items && listData.items.length > 0) {
        const roomId = randomItem(listData.items).chatRoomId || randomItem(listData.items).id;
        if (roomId) {
          apiGetWithToken(`/chat-rooms/${roomId}`, token);
        }
      }
    });

  } else if (scenario <= 60) {
    // 30%: 모임/사용자 API
    group('모임 확인', function () {
      apiGetWithToken('/users/me', token);
      thinkTime(1, 2);
      apiGetWithToken('/users/me/meetings?status=ACTIVE&size=10', token);
      thinkTime(1, 2);
      apiGetWithToken('/users/me/meetings/today', token);
    });

  } else if (scenario <= 80) {
    // 20%: 알림
    group('알림', function () {
      apiGetWithToken('/notifications/unread', token);
      thinkTime(1, 2);
      const res = apiGetWithToken('/notifications', token);
      const notifData = extractData(res);
      if (notifData && notifData.notifications && notifData.notifications.length > 0) {
        const unread = notifData.notifications.filter(n => !n.isRead);
        if (unread.length > 0) {
          apiPutWithToken(`/notifications/${unread[0].notificationId}`, {}, token);
        }
      }
    });

  } else {
    // 20%: 모임 참여
    group('모임 참여', function () {
      const listRes = apiGet('/meetings?size=20');
      const meetingData = extractData(listRes);
      if (meetingData && meetingData.items && meetingData.items.length > 0) {
        const meetingId = randomItem(meetingData.items).meetingId;
        apiPostWithToken(`/meetings/${meetingId}/participations`, {}, token);
      }
    });
  }

  httpApiDuration.add(Date.now() - start);
  thinkTime(2, 5);
}

// 기본 함수 (scenarios에서 exec 지정이라 호출 안 됨)
export default function () {}
