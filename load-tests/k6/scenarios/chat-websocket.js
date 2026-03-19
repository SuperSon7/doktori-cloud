/**
 * 채팅 WebSocket 부하 테스트
 *
 * 테스트 항목:
 * 1. STOMP over WebSocket 연결 (JWT 인증)
 * 2. 채팅방 구독 + 메시지 송수신
 * 3. 동시 연결 수 한계
 *
 * 테스트 포인트:
 * - Chat Pod (2 replica) WebSocket 연결 분산
 * - STOMP 인증 (StompChannelInterceptor JWT 검증)
 * - 메시지 브로커 (/topic) 부하
 * - 장시간 연결 유지 안정성
 *
 * 프로토콜: WebSocket (STOMP)
 * 엔드포인트: /ws (→ K8s HTTPRoute → chat-svc:8081 → /api/ws)
 */
import ws from 'k6/ws';
import { check, sleep } from 'k6';
import { Counter, Trend, Gauge, Rate } from 'k6/metrics';
import { config } from '../config.js';
import { fetchMultiTokens, randomInt } from '../helpers.js';

// 메트릭
const wsConnectDuration = new Trend('ws_connect_duration', true);
const wsMessageSent = new Counter('ws_message_sent');
const wsMessageReceived = new Counter('ws_message_received');
const wsActiveConnections = new Gauge('ws_active_connections');
const wsConnectSuccess = new Counter('ws_connect_success');
const wsConnectFailed = new Counter('ws_connect_failed');
const wsErrorRate = new Rate('ws_errors');

const WS_URL = __ENV.WS_URL || 'wss://api.doktori.kr/ws/chat';
const CHAT_ROOM_IDS = (__ENV.CHAT_ROOM_IDS || '1,2,3').split(',').map(Number);
const MESSAGE_INTERVAL_SEC = Number(__ENV.MSG_INTERVAL || 3);

export const options = {
  scenarios: {
    ws_connections: {
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
    ws_connect_duration: ['p(95)<3000'],
    ws_errors: ['rate<0.1'],
  },
};

export function setup() {
  const tokens = fetchMultiTokens();
  if (tokens.length === 0) {
    console.error('WebSocket 테스트에 토큰이 필요합니다.');
  }
  return { tokens };
}

// STOMP 프레임 생성 헬퍼
function stompConnect(token) {
  return `CONNECT\nAuthorization:Bearer ${token}\naccept-version:1.2\nheart-beat:10000,10000\n\n\0`;
}

function stompSubscribe(destination, id) {
  return `SUBSCRIBE\nid:sub-${id}\ndestination:${destination}\n\n\0`;
}

function stompSend(destination, body) {
  return `SEND\ndestination:${destination}\ncontent-type:application/json\n\n${JSON.stringify(body)}\0`;
}

export default function (data) {
  const tokens = data.tokens;
  if (!tokens || tokens.length === 0) {
    sleep(1);
    return;
  }

  const token = tokens[__VU % tokens.length];
  const roomId = CHAT_ROOM_IDS[__VU % CHAT_ROOM_IDS.length];
  const connectStart = Date.now();

  const res = ws.connect(WS_URL, {
    headers: { 'Authorization': `Bearer ${token}` },
    tags: { name: 'ws_chat' },
  }, function (socket) {
    wsConnectDuration.add(Date.now() - connectStart);
    wsConnectSuccess.add(1);
    wsActiveConnections.add(1);

    // STOMP CONNECT
    socket.send(stompConnect(token));

    socket.on('message', function (msg) {
      wsMessageReceived.add(1);

      // CONNECTED 프레임 수신 시 구독 시작
      if (msg.startsWith('CONNECTED')) {
        // 채팅방 토픽 구독
        socket.send(stompSubscribe(`/topic/chat-rooms/${roomId}/messages`, roomId));
      }
    });

    socket.on('error', function (e) {
      wsErrorRate.add(1);
      console.log(`WS error VU${__VU}: ${e.error()}`);
    });

    // 메시지 전송 (주기적)
    const messageCount = randomInt(3, 8);
    for (let i = 0; i < messageCount; i++) {
      socket.send(stompSend(`/app/chat-rooms/${roomId}/messages`, {
        content: `부하테스트 메시지 VU${__VU} #${i + 1}`,
        type: 'TEXT',
      }));
      wsMessageSent.add(1);
      sleep(MESSAGE_INTERVAL_SEC);
    }

    // 연결 유지 (실제 유저의 채팅방 체류 시뮬레이션)
    sleep(randomInt(10, 30));

    wsActiveConnections.add(-1);
    socket.close();
  });

  const connected = check(res, {
    'WS connected (101)': (r) => r && r.status === 101,
  });

  if (!connected) {
    wsConnectFailed.add(1);
    wsErrorRate.add(1);
  }

  sleep(randomInt(1, 3));
}