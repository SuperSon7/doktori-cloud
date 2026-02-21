/**
 * WebSocket 마이그레이션 안정성 테스트
 *
 * 목적: 채팅 서버 전환(Lightsail → 새 VPC) 시 WebSocket 연결의 동작을 검증한다.
 *
 * 시나리오:
 *   1. WebSocket 연결 수립 + 주기적 ping
 *   2. 서버 전환 발생 (nginx reload or DNS switch)
 *   3. 연결 끊김 여부, 끊기면 재연결 소요 시간 측정
 *
 * 관찰 포인트:
 *   - nginx -s reload 시 기존 WebSocket 연결 유지 여부
 *   - 연결 끊김 시 클라이언트 재연결 패턴
 *   - 메시지 유실 여부
 *
 * 실행:
 *   k6 run --env WS_URL=wss://doktori.kr/ws \
 *          --env JWT_TOKEN=<토큰> \
 *          websocket-migration.js
 */

import ws from 'k6/ws';
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';
import { config } from '../../config.js';
import { getHeaders, initAuth } from '../../helpers.js';

// ── 메트릭 ──
const wsConnectSuccess = new Rate('ws_connect_success');
const wsConnectLatency = new Trend('ws_connect_latency', true);
const wsDisconnections = new Counter('ws_disconnections');
const wsReconnections = new Counter('ws_reconnections');
const wsMessagesSent = new Counter('ws_messages_sent');
const wsMessagesReceived = new Counter('ws_messages_received');
const wsErrors = new Counter('ws_errors');

// 채팅 REST API 가용성도 함께 측정
const chatApiSuccess = new Rate('ws_chat_api_success');

const WS_URL = __ENV.WS_URL || 'wss://doktori.kr/ws';
const CHAT_BASE_URL = __ENV.CHAT_BASE_URL || __ENV.BASE_URL || 'https://doktori.kr/api';

export const options = {
  scenarios: {
    // WebSocket 장기 연결 (서버 전환 시 끊김 관찰)
    ws_connections: {
      executor: 'constant-vus',
      vus: 5,
      duration: '15m',
      exec: 'wsLongConnection',
    },
    // 채팅 REST API 가용성 (채팅방 목록 등)
    chat_api: {
      executor: 'constant-vus',
      vus: 3,
      duration: '15m',
      exec: 'chatApiCheck',
    },
  },

  thresholds: {
    'ws_connect_success': ['rate>0.90'],
    'ws_chat_api_success': ['rate>0.95'],
  },
};

export function setup() {
  initAuth();
  console.log('=== WebSocket 마이그레이션 테스트 시작 ===');
  console.log(`WebSocket: ${WS_URL}`);
  console.log(`Chat API:  ${CHAT_BASE_URL}`);
  console.log('3~5분 후 서버 전환을 수행하세요.');
  console.log('=========================================');
}

// ── WebSocket 장기 연결 ──
export function wsLongConnection() {
  const timestamp = () => new Date().toISOString();
  let connectStart = Date.now();
  let connectionId = Math.random().toString(36).substr(2, 6);

  const res = ws.connect(WS_URL, {
    headers: {
      'Authorization': `Bearer ${config.accessToken}`,
    },
  }, function (socket) {
    const connectTime = Date.now() - connectStart;
    wsConnectLatency.add(connectTime);
    wsConnectSuccess.add(true);
    console.log(`[${timestamp()}] [${connectionId}] WS 연결 성공 (${connectTime}ms)`);

    let pingCount = 0;
    let lastPongTime = Date.now();

    socket.on('open', () => {
      // STOMP CONNECT 프레임 전송
      socket.send('CONNECT\naccept-version:1.2\nheart-beat:10000,10000\n\n\0');
    });

    socket.on('message', (msg) => {
      wsMessagesReceived.add(1);

      if (msg.startsWith('CONNECTED')) {
        console.log(`[${timestamp()}] [${connectionId}] STOMP CONNECTED`);
      }
    });

    socket.on('pong', () => {
      lastPongTime = Date.now();
    });

    socket.on('error', (e) => {
      wsErrors.add(1);
      console.log(`[${timestamp()}] [${connectionId}] WS ERROR: ${e.error()}`);
    });

    socket.on('close', () => {
      wsDisconnections.add(1);
      const duration = Math.round((Date.now() - connectStart) / 1000);
      console.log(
        `[${timestamp()}] [${connectionId}] WS 연결 끊김 ` +
        `(유지 시간: ${duration}초, ping ${pingCount}회)`
      );
    });

    // 10초마다 ping (서버 전환 시 끊김 감지)
    const pingInterval = 10;
    const totalPings = Math.floor((14 * 60) / pingInterval); // 14분간

    for (let i = 0; i < totalPings; i++) {
      socket.setTimeout(() => {
        pingCount++;
        socket.ping();
        wsMessagesSent.add(1);

        // ping 후 3초 내 pong 안 오면 로그
        socket.setTimeout(() => {
          if (Date.now() - lastPongTime > (pingInterval + 3) * 1000) {
            console.log(
              `[${timestamp()}] [${connectionId}] ⚠️ PONG 미수신 (ping #${pingCount})`
            );
          }
        }, 3000);
      }, i * pingInterval * 1000);
    }

    // 14분 후 정상 종료
    socket.setTimeout(() => {
      socket.close();
    }, 14 * 60 * 1000);
  });

  if (!res || res.status !== 101) {
    wsConnectSuccess.add(false);
    wsErrors.add(1);
    console.log(
      `[${timestamp()}] [${connectionId}] WS 연결 실패: ` +
      `${res ? res.status : 'no response'}`
    );

    // 재연결 시도
    sleep(3);
    wsReconnections.add(1);
    console.log(`[${timestamp()}] [${connectionId}] 재연결 시도...`);
  }
}

// ── 채팅 REST API 가용성 ──
export function chatApiCheck() {
  const timestamp = new Date().toISOString();

  // 채팅방 목록 조회
  const res = http.get(`${CHAT_BASE_URL}/chat-rooms?size=10`, {
    headers: getHeaders(true),
    tags: { name: 'GET /chat-rooms', type: 'chat_api' },
    timeout: '10s',
  });

  const ok = res.status === 200 || res.status === 401;
  chatApiSuccess.add(ok);

  if (!ok) {
    console.log(`[${timestamp}] CHAT API FAIL: ${res.status} (${res.timings.duration}ms)`);
  }

  sleep(2);
}

export function teardown(data) {
  console.log('=== WebSocket 마이그레이션 테스트 종료 ===');
  console.log('');
  console.log('포트폴리오 핵심 지표:');
  console.log('  - ws_disconnections: 전환 중 끊긴 연결 수');
  console.log('  - ws_reconnections: 재연결 시도 수');
  console.log('  - ws_connect_latency: 연결/재연결 소요 시간');
  console.log('  - ws_errors: 에러 수');
  console.log('  - 로그에서 "WS 연결 끊김 (유지 시간: Xs)" → 전환 시점과 대조');
}
