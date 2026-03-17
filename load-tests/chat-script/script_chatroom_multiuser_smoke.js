import http from "k6/http";
import { check, group, sleep } from "k6";
import { Counter, Rate, Trend } from "k6/metrics";

const BASE_URL = __ENV.BASE_URL || "https://doktori.kr";
const TOKEN_API_URL = __ENV.TOKEN_API_URL || `${BASE_URL}/api/dev/tokens`;
const DEBUG_LOG = __ENV.DEBUG_LOG === "1";
const ROOM_CAPACITIES = [2, 2, 2, 4, 4, 4, 6, 6, 6];
const REQUIRED_TOKEN_COUNT = ROOM_CAPACITIES.reduce((sum, size) => sum + size, 0);

export const options = {
  scenarios: {
    chatroom_smoke: {
      executor: "per-vu-iterations",
      vus: 1,
      iterations: 1,
      maxDuration: __ENV.MAX_DURATION || "2m",
    },
  },
};

const apiStatusCount = new Counter("api_status_count");
const writeSuccessRate = new Rate("write_success_rate");
const writeFailureCount = new Counter("write_failure_count");
const writeDuration = new Trend("write_duration", true);

const checkCreatePass = new Counter("check_chat_room_create_pass");
const checkCreateFail = new Counter("check_chat_room_create_fail");
const checkJoinPass = new Counter("check_chat_room_join_pass");
const checkJoinFail = new Counter("check_chat_room_join_fail");
const chatRoomJoinConflictCount = new Counter("chat_room_join_conflict_count");
const roomsCompletedPass = new Counter("check_chat_room_plan_completed_pass");
const roomsCompletedFail = new Counter("check_chat_room_plan_completed_fail");

function loadTokenSource() {
  if (__ENV.DEV_TOKENS_JSON) {
    return JSON.parse(__ENV.DEV_TOKENS_JSON);
  }

  try {
    return JSON.parse(open("./tokens.dev.json"));
  } catch (e) {
    return [];
  }
}

function fetchTokensFromApi() {
  if (!TOKEN_API_URL) return [];
  const res = http.get(TOKEN_API_URL, {
    headers: { Accept: "application/json" },
    responseCallback: http.expectedStatuses(200),
  });
  return normalizeTokenPool(safeJson(res));
}

function normalizeTokenPool(raw) {
  const candidates = Array.isArray(raw)
    ? raw
    : raw?.data?.tokens || raw?.data || raw?.tokens || raw?.items || [];

  return candidates
    .map((entry, index) => {
      if (typeof entry === "string") {
        return { id: `token-${index + 1}`, accessToken: entry };
      }
      return {
        id: String(
          entry?.userId ||
            entry?.id ||
            entry?.providerId ||
            entry?.nickname ||
            `token-${index + 1}`
        ),
        accessToken: entry?.accessToken || entry?.token || "",
      };
    })
    .filter((entry) => entry.accessToken);
}

function safeJson(res) {
  try {
    return res.json();
  } catch (e) {
    return null;
  }
}

function trackApi(endpoint, method, res, expectedStatuses = null) {
  if (!res) return;
  const status = Number(res.status || 0);
  const tags = { endpoint, method, status: String(status) };
  apiStatusCount.add(1, tags);

  if (expectedStatuses) {
    const success = expectedStatuses.includes(status);
    writeSuccessRate.add(success ? 1 : 0, tags);
    writeDuration.add(res.timings?.duration || 0, tags);
    if (!success) writeFailureCount.add(1, tags);
  }
}

function requestWithToken(token, method, url, body = null, expectedStatuses = null) {
  const headers = {
    Accept: "application/json",
    "Content-Type": "application/json",
    Authorization: `Bearer ${token}`,
  };
  const options = { headers };
  if (expectedStatuses?.length) {
    options.responseCallback = http.expectedStatuses(...expectedStatuses);
  }

  let res;
  if (method === "GET") res = http.get(url, options);
  else if (method === "POST") res = http.post(url, body, options);
  else if (method === "PATCH") res = http.patch(url, body, options);
  else if (method === "DELETE") res = http.del(url, body, options);

  return { res, body: safeJson(res) };
}

function logStep(title, res, body) {
  console.log(`[STEP] ${title} status=${res.status}`);
  if (!DEBUG_LOG) return;
  const text = (body ? JSON.stringify(body) : res.body) || "";
  console.log(`body (first 1000 chars): ${text.slice(0, 1000)}`);
}

function pickFirst(obj, paths) {
  for (const path of paths) {
    const value = path(obj);
    if (value !== undefined && value !== null && value !== "") return value;
  }
  return null;
}

function buildCreatePayload(suffix) {
  return {
    topic: `AI가 인간의 일자리를 대체할 수 있는가? ${suffix}`,
    description: "AI 기술 발전에 따른 고용 시장 변화를 토론합니다.",
    isbn: "9781234567890",
    capacity: 4,
    position: "AGREE",
    quiz: {
      question: "대한민국의 수도는 어디인가요",
      choices: [
        { choiceNumber: 1, text: "서울" },
        { choiceNumber: 2, text: "부산" },
        { choiceNumber: 3, text: "인천" },
        { choiceNumber: 4, text: "대구" },
      ],
      correctChoiceNumber: 1,
    },
  };
}

function buildJoinPayload(position) {
  return {
    position,
    quizAnswer: 1,
  };
}

function buildStartPayload() {
  return {
    status: "IN_PROGRESS",
  };
}

function recordCheck(ok, passCounter, failCounter, label, res) {
  check(res, { [label]: () => ok });
  if (ok) passCounter.add(1);
  else failCounter.add(1);
}

export function setup() {
  const apiTokens = fetchTokensFromApi();
  const fallbackTokens = normalizeTokenPool(loadTokenSource());
  const tokens = apiTokens.length ? apiTokens : fallbackTokens;

  if (tokens.length < REQUIRED_TOKEN_COUNT) {
    throw new Error(
      `At least ${REQUIRED_TOKEN_COUNT} access tokens are required. Checked ${TOKEN_API_URL} and fallback token input.`
    );
  }

  return {
    tokenCount: tokens.length,
    roomCapacities: ROOM_CAPACITIES,
    tokens,
  };
}

function buildRoomPlans(tokens) {
  let cursor = 0;
  return ROOM_CAPACITIES.map((capacity, index) => {
    const reserveOneSeat = index === 3;
    const memberCount = reserveOneSeat ? capacity - 1 : capacity;
    const members = tokens.slice(cursor, cursor + memberCount);
    cursor += capacity;
    return {
      roomIndex: index + 1,
      capacity,
      reservedSeat: reserveOneSeat,
      owner: members[0],
      joiners: members.slice(1),
    };
  });
}

function runRoomPlan(plan) {
  const suffix = `room-${plan.roomIndex}-${plan.capacity}-${Date.now()}`;
  let roomId = null;
  let joinSuccessCount = 0;

  group(`${plan.roomIndex}) POST /api/chat-rooms`, () => {
    const payload = buildCreatePayload(suffix);
    payload.capacity = plan.capacity;
    const { res, body } = requestWithToken(
      plan.owner.accessToken,
      "POST",
      `${BASE_URL}/api/chat-rooms`,
      JSON.stringify(payload),
      [200, 201]
    );
    if (!res) return;
    trackApi("chat_rooms_create", "POST", res, [200, 201]);
    logStep(`${plan.roomIndex}) /api/chat-rooms`, res, body);

    const ok = res.status === 200 || res.status === 201;
    recordCheck(ok, checkCreatePass, checkCreateFail, "chat room create 200/201", res);
    roomId = pickFirst(body, [
      (b) => b?.data?.roomId,
      (b) => b?.data?.id,
      (b) => b?.roomId,
      (b) => b?.id,
    ]);
  });

  group(`${plan.roomIndex}) POST /api/chat-rooms/{roomId}/members`, () => {
    if (!roomId) {
      console.log(`Skip ${plan.roomIndex}) no roomId`);
      return;
    }

    const targetMemberCount = plan.reservedSeat ? plan.capacity - 1 : plan.capacity;
    const agreeTargetCount = Math.max(1, Math.ceil(targetMemberCount / 2));
    const agreeSlots = Math.max(0, agreeTargetCount - 1);
    for (let index = 0; index < plan.joiners.length; index += 1) {
      const joiner = plan.joiners[index];
      const position = index < agreeSlots ? "AGREE" : "DISAGREE";
      const payload = buildJoinPayload(position);
      const { res, body } = requestWithToken(
        joiner.accessToken,
        "POST",
        `${BASE_URL}/api/chat-rooms/${roomId}/members`,
        JSON.stringify(payload),
        [201, 401, 403, 404, 409, 422]
      );
      if (!res) continue;
      trackApi("chat_rooms_join", "POST", res, [201]);
      logStep(`${plan.roomIndex}) /api/chat-rooms/{roomId}/members`, res, body);

      if (res.status === 409) {
        chatRoomJoinConflictCount.add(1, {
          endpoint: "chat_rooms_join",
          roomIndex: String(plan.roomIndex),
        });
      }

      const ok = res.status === 201;
      recordCheck(ok, checkJoinPass, checkJoinFail, "chat room join 201", res);
      if (ok) joinSuccessCount += 1;
    }
  });

  return Boolean(roomId) && joinSuccessCount === plan.joiners.length;
}

export default function (setupData) {
  const tokens = normalizeTokenPool(setupData?.tokens || []);
  const roomPlans = buildRoomPlans(tokens);
  let completedRooms = 0;

  for (const plan of roomPlans) {
    if (runRoomPlan(plan)) completedRooms += 1;
  }

  const completed = completedRooms === roomPlans.length;
  recordCheck(
    completed,
    roomsCompletedPass,
    roomsCompletedFail,
    "chat room plan completed",
    { status: completed ? 200 : 500 }
  );

  sleep(1);
}
