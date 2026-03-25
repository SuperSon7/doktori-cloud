/**
 * Chat HPA 메트릭 검증 — "조용한 연결 → 메시지 폭발" 패턴
 *
 * 목적: WS 연결만 유지하다 갑자기 메시지 폭발 시 HPA가 제때 반응하는가
 *
 * Phase 1 (1분): WS 500 연결 수립 (메시지 없음)
 * Phase 2 (2분): 연결 유지, 메시지 없음 — "조용한 방" (CPU 낮아야 함)
 * Phase 3 (2분): 메시지 1초 간격 폭발 — CPU 급등 확인
 * Phase 4 (2분): 폭발 지속 — HPA 반응 + Pod 추가 확인
 *
 * 관찰: kubectl get hpa -n prod -w / kubectl top pods -n prod
 */
import ws from 'k6/ws';
import { check, sleep } from 'k6';
import { Counter, Trend, Gauge, Rate } from 'k6/metrics';
import { config } from '../config.js';
import { fetchMultiTokens, randomItem, apiGet, extractData, apiGetWithToken } from '../helpers.js';

const wsConnectDuration = new Trend('ws_connect_duration', true);
const wsMessageSent = new Counter('ws_message_sent');
const wsMessageReceived = new Counter('ws_message_received');
const wsActiveConnections = new Gauge('ws_active_connections');
const wsConnectSuccess = new Counter('ws_connect_success');
const wsConnectFailed = new Counter('ws_connect_failed');
const wsErrorRate = new Rate('ws_errors');
const burstMessageDuration = new Trend('burst_message_duration', true);

const WS_URL = __ENV.WS_URL || 'wss://api.doktori.kr/ws/chat';
const CHAT_ROOM_IDS = (__ENV.CHAT_ROOM_IDS || '1,2,3').split(',').map(Number);
const WS_VUS = Number(__ENV.WS_VUS || 500);

// Phase 타이밍 (초)
const CONNECT_PHASE = 60;    // Phase 1: 연결
const QUIET_PHASE = 120;     // Phase 2: 조용한 대기
const BURST_PHASE = 240;     // Phase 3+4: 메시지 폭발

const MESSAGES = [
  '이 부분에서 작가의 의도가 뭘까요?',
  '저는 주인공의 선택에 공감했어요',
  '그 해석도 가능하네요',
  '반대 의견인데요',
  '시간이 벌써 이렇게 됐네요',
];

export const options = {
  scenarios: {
    ws_burst: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '1m', target: WS_VUS },   // Phase 1: 연결 수립
        { duration: '6m', target: WS_VUS },   // Phase 2+3+4: 유지
        { duration: '30s', target: 0 },        // 종료
      ],
      gracefulRampDown: '30s',
      gracefulStop: '5m',
    },
  },
  thresholds: {
    ws_connect_duration: ['p(95)<5000'],
    ws_errors: ['rate<0.2'],
  },
};

export function setup() {
  const tokens = fetchMultiTokens();
  return { tokens };
}

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
  if (!tokens || tokens.length === 0) { sleep(1); return; }

  const token = tokens[__VU % tokens.length];
  const roomId = CHAT_ROOM_IDS[__VU % CHAT_ROOM_IDS.length];
  const position = __VU % 2 === 0 ? 'AGREE' : 'DISAGREE';
  const connectStart = Date.now();
  const testStart = Date.now();

  const res = ws.connect(WS_URL, {
    headers: { 'Authorization': `Bearer ${token}` },
    tags: { name: 'ws_burst' },
  }, function (socket) {
    wsConnectDuration.add(Date.now() - connectStart);
    wsConnectSuccess.add(1);
    wsActiveConnections.add(1);

    let connected = false;

    socket.send(stompConnect(token));

    socket.on('message', function (msg) {
      wsMessageReceived.add(1);
      if (msg.startsWith('CONNECTED') && !connected) {
        connected = true;
        socket.send(stompSubscribe(`/topic/chat-rooms/${roomId}/messages`, roomId));
      }
    });

    socket.on('error', function (e) {
      wsErrorRate.add(1);
    });

    // Phase 2: 조용한 대기 (QUIET_PHASE 동안 메시지 안 보냄)
    // Phase 3+4: 메시지 폭발 (1초 간격)
    socket.setInterval(function () {
      if (!connected) return;

      const elapsed = (Date.now() - testStart) / 1000;

      // Phase 1+2: 연결 후 QUIET_PHASE까지 메시지 안 보냄
      if (elapsed < CONNECT_PHASE + QUIET_PHASE) {
        return; // 조용히 대기
      }

      // Phase 3+4: 메시지 폭발
      const sendStart = Date.now();
      socket.send(stompSend(`/app/chat-rooms/${roomId}/messages`, {
        content: `[${position}] ${randomItem(MESSAGES)}`,
        type: 'TEXT',
      }));
      wsMessageSent.add(1);
      burstMessageDuration.add(Date.now() - sendStart);
    }, 1000); // 1초 간격

    // 전체 테스트 시간 후 종료
    socket.setTimeout(function () {
      wsActiveConnections.add(-1);
      socket.close();
    }, (CONNECT_PHASE + QUIET_PHASE + BURST_PHASE) * 1000);
  });

  const success = check(res, {
    'WS connected (101)': (r) => r && r.status === 101,
  });

  if (!success) {
    wsConnectFailed.add(1);
    wsErrorRate.add(1);
  }
}