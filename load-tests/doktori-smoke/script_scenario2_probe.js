import http from "k6/http";
import { check, group, sleep } from "k6";
import { Counter, Rate, Trend } from "k6/metrics";

const BASE_URL = __ENV.BASE_URL || "https://doktori.kr";
const ACCESS_TOKEN =
  __ENV.ACCESS_TOKEN ||
  "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMiIsInVzZXJJZCI6MTIsIm5pY2tuYW1lIjoi6rmA7KeA7ISdIiwiaWF0IjoxNzcxOTQyNTM4LCJleHAiOjE3NzE5NDQzMzh9.mL0a87909IO7QxshuCXO5sAXTDL7qA1Wmrr58_3b5rg";
const PARTICIPATION_MIN_MEETING_ID = 1;
const PARTICIPATION_MAX_MEETING_ID = 65;
const PARTICIPATION_MAX_RETRIES = 20;
const TEST_VUS = Number(__ENV.VUS || 30);
const TEST_DURATION = __ENV.DURATION || "10m";

export const options = {
  scenarios: {
    rps_test: {
      executor: "constant-vus",
      vus: TEST_VUS,
      duration: TEST_DURATION,
      gracefulStop: "30s",
    },
  },
};

const apiStatusCount = new Counter("api_status_count");
const apiErrorCodeCount = new Counter("api_error_code_count");
const serverErrorCount = new Counter("server_error_count");
const migrationSuspectErrorCount = new Counter("migration_suspect_error_count");
const writeSuccessRate = new Rate("write_success_rate");
const writeFailureCount = new Counter("write_failure_count");
const writeLimitedCount = new Counter("write_limited_count");
const writeDuration = new Trend("write_duration", true);
const methodGetCount = new Counter("api_get_count");
const methodPostCount = new Counter("api_post_count");
const methodPutCount = new Counter("api_put_count");
const methodDeleteCount = new Counter("api_delete_count");

const checkMetrics = {
  me_200: {
    pass: new Counter("check_me_200_pass"),
    fail: new Counter("check_me_200_fail"),
  },
  reco_200: {
    pass: new Counter("check_reco_200_pass"),
    fail: new Counter("check_reco_200_fail"),
  },
  meeting_create_200_201: {
    pass: new Counter("check_meeting_create_200_201_pass"),
    fail: new Counter("check_meeting_create_200_201_fail"),
  },
  my_meetings_200: {
    pass: new Counter("check_my_meetings_200_pass"),
    fail: new Counter("check_my_meetings_200_fail"),
  },
  today_200: {
    pass: new Counter("check_today_200_pass"),
    fail: new Counter("check_today_200_fail"),
  },
  meeting_detail_200: {
    pass: new Counter("check_meeting_detail_200_pass"),
    fail: new Counter("check_meeting_detail_200_fail"),
  },
  book_report_200_201_429: {
    pass: new Counter("check_book_report_200_201_429_pass"),
    fail: new Counter("check_book_report_200_201_429_fail"),
  },
  unread_200: {
    pass: new Counter("check_unread_200_pass"),
    fail: new Counter("check_unread_200_fail"),
  },
  notifications_200: {
    pass: new Counter("check_notifications_200_pass"),
    fail: new Counter("check_notifications_200_fail"),
  },
  mark_read_200_204: {
    pass: new Counter("check_mark_read_200_204_pass"),
    fail: new Counter("check_mark_read_200_204_fail"),
  },
};

function runCheck(metricKey, checkLabel, res, predicate) {
  const passed = Boolean(predicate(res));
  check(res, { [checkLabel]: () => passed });
  if (checkMetrics[metricKey]) {
    if (passed) checkMetrics[metricKey].pass.add(1);
    else checkMetrics[metricKey].fail.add(1);
  }
  return passed;
}

function trackApi(endpoint, method, res, body, writeExpectedStatuses = null) {
  if (!res) return;

  const status = Number(res.status || 0);
  const tags = { endpoint, method, status: String(status) };
  apiStatusCount.add(1, tags);
  const upperMethod = String(method || "").toUpperCase();
  if (upperMethod === "GET") methodGetCount.add(1);
  else if (upperMethod === "POST") methodPostCount.add(1);
  else if (upperMethod === "PUT") methodPutCount.add(1);
  else if (upperMethod === "DELETE") methodDeleteCount.add(1);

  const bodyCode = body?.code || body?.errorCode || body?.errors?.[0]?.code;
  if (bodyCode) {
    const codeTag = String(bodyCode);
    apiErrorCodeCount.add(1, { ...tags, code: codeTag });
    if (codeTag.toUpperCase().includes("MIGRATION")) {
      migrationSuspectErrorCount.add(1, { ...tags, reason: "error_code" });
    }
  }

  if (status >= 500) {
    serverErrorCount.add(1, tags);
    const msg = String(body?.message || "").toLowerCase();
    if (
      msg.includes("migration") ||
      msg.includes("schema") ||
      msg.includes("column") ||
      msg.includes("table") ||
      msg.includes("sql")
    ) {
      migrationSuspectErrorCount.add(1, { ...tags, reason: "message_hint" });
    }
  }

  if (writeExpectedStatuses) {
    const success = writeExpectedStatuses.includes(status);
    writeSuccessRate.add(success ? 1 : 0, tags);
    writeDuration.add(res.timings?.duration || 0, tags);
    if (!success) writeFailureCount.add(1, tags);
    if (status === 429) writeLimitedCount.add(1, tags);
  }
}



function safeJson(res) {
  try { return res.json(); } catch (e) { return null; }
}

function logStep(title, res, bodyJson) {
  console.log(`\n===== ${title} =====`);
  console.log(`status: ${res.status}`);
  // 너무 길면 잘라서 출력
  const text = (bodyJson ? JSON.stringify(bodyJson) : res.body) || "";
  console.log(`body (first 1500 chars): ${text.slice(0, 1500)}`);
  // headers에서 Set-Cookie 확인용
  if (res.headers["Set-Cookie"]) {
    console.log(`Set-Cookie: ${res.headers["Set-Cookie"].slice(0, 500)}`);
  }
}

function pickFirst(obj, paths) {
  for (const p of paths) {
    const v = p(obj);
    if (v !== undefined && v !== null && v !== "") return v;
  }
  return null;
}

function randomIntInclusive(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

function plusDaysYmd(days) {
  const d = new Date();
  d.setDate(d.getDate() + days);
  return d.toISOString().slice(0, 10);
}

export function setup() {
  if (!ACCESS_TOKEN) {
    throw new Error("ACCESS_TOKEN is required. Example: ACCESS_TOKEN='xxx' k6 run script_scenario2_probe.js");
  }

  const commonHeaders = {
    Accept: "application/json",
    "Content-Type": "application/json",
  };

  const headers = { ...commonHeaders, Authorization: `Bearer ${ACCESS_TOKEN}` };
  const usedMeetingIds = new Set();
  const successStatuses = new Set([200, 201, 204]);
  const participationParams = {
    headers,
    // 409 is a business-level conflict, not a transport failure.
    responseCallback: http.expectedStatuses(200, 201, 204, 409),
  };
  let participationResult = {
    success: false,
    meetingId: null,
    status: null,
    attempts: 0,
    skipped: false,
  };

  for (let attempt = 1; attempt <= PARTICIPATION_MAX_RETRIES; attempt += 1) {
    if (usedMeetingIds.size >= (PARTICIPATION_MAX_MEETING_ID - PARTICIPATION_MIN_MEETING_ID + 1)) {
      console.log("All meetingId values in range are exhausted. Skip participation.");
      participationResult = {
        success: false,
        meetingId: null,
        status: null,
        attempts: attempt - 1,
        skipped: true,
      };
      break;
    }

    let meetingId = randomIntInclusive(
      PARTICIPATION_MIN_MEETING_ID,
      PARTICIPATION_MAX_MEETING_ID
    );
    while (usedMeetingIds.has(meetingId)) {
      meetingId = randomIntInclusive(
        PARTICIPATION_MIN_MEETING_ID,
        PARTICIPATION_MAX_MEETING_ID
      );
    }
    usedMeetingIds.add(meetingId);

    const url = `${BASE_URL}/api/meetings/${meetingId}/participations`;
    const res = http.post(url, JSON.stringify({}), participationParams);
    participationResult.attempts = attempt;
    participationResult.meetingId = meetingId;
    participationResult.status = res.status;

    if (successStatuses.has(res.status)) {
      participationResult.success = true;
      break;
    }

    if (res.status === 409) {
      console.log(`Participation 409 for meetingId=${meetingId}. Retrying...`);
      continue;
    }

    console.log(`Participation failed with status=${res.status} for meetingId=${meetingId}. Skip.`);
    participationResult.skipped = true;
    break;
  }

  if (!participationResult.success && !participationResult.skipped) {
    participationResult.skipped = true;
    console.log(
      `Participation not successful within ${PARTICIPATION_MAX_RETRIES} retries. Skip.`
    );
  }

  return { accessToken: ACCESS_TOKEN, participationResult };
}

export default function (data) {
  const accessToken = data?.accessToken;
  if (!accessToken) {
    console.log("No accessToken from setup. Stop scenario.");
    return;
  }

  if (data?.participationResult) {
    const pr = data.participationResult;
    if (pr.success) {
      console.log(
        `Participation success: meetingId=${pr.meetingId}, status=${pr.status}, attempts=${pr.attempts}`
      );
    } else {
      console.log(
        `Participation skipped: meetingId=${pr.meetingId || "NONE"}, status=${pr.status || "NONE"}, attempts=${pr.attempts}`
      );
    }
  }

  const commonHeaders = {
    Accept: "application/json",
    "Content-Type": "application/json",
  };

  let meetingId = null;
  let notificationId = null;
  let fixedRoundId = null;
  const FIXED_BOOK_REPORT_CONTENT =
    "타인의 감정을 느끼지 못하는 소년 윤재가 세상과 관계를 맺으며 성장해 가는 과정을 담은 소설 『아몬드』는 감정이란 무엇이며 우리는 어떻게 서로를 이해하게 되는지를 차분히 묻는다. 윤재는 타인의 고통과 기쁨을 즉각적으로 공감하지 못하지만, 다양한 사건과 사람들을 만나며 조금씩 변화하고 관계를 배워 간다. 특히 상처를 가진 또래 친구와의 만남을 통해 서로의 결핍을 이해하게 되는 과정이 인상 깊었다. 이 작품은 감정 표현이 서툰 사람도 결국은 누군가와 연결될 수 있다는 희망을 보여주며, 우리가 당연하게 여기는 공감 능력의 의미를 다시 생각하게 만든다. 감정을 느끼는 방식은 다르지만 결국 사람은 관계 속에서 성장한다는 메시지가 오래 기억에 남는 작품이었다.";

  function requestWithAuth(method, url, body = null) {
    const headers = { ...commonHeaders, Authorization: `Bearer ${accessToken}` };
    let res;
    if (method === "GET") res = http.get(url, { headers });
    else if (method === "POST") res = http.post(url, body, { headers });
    else if (method === "PUT") res = http.put(url, body, { headers });
    else if (method === "DELETE") res = http.del(url, body, { headers });

    return { res, body: safeJson(res) };
  }

  // 2) GET /api/users/me
  group("2) GET /api/users/me", () => {
    const { res, body } = requestWithAuth("GET", `${BASE_URL}/api/users/me`);
    if (!res) return;
    trackApi("users_me", "GET", res, body);
    logStep("2) /api/users/me", res, body);
    runCheck("me_200", "me 200", res, (r) => r.status === 200);
  });

  // 3) GET /api/recommendations/meetings (개인화)
  group("3) GET /api/recommendations/meetings", () => {
    const { res, body } = requestWithAuth("GET", `${BASE_URL}/api/recommendations/meetings`);
    if (!res) return;
    trackApi("recommendations_meetings", "GET", res, body);
    logStep("3) /api/recommendations/meetings", res, body);
    runCheck("reco_200", "reco 200", res, (r) => r.status === 200);
  });

  // 4) POST /api/meetings
  group("4) POST /api/meetings", () => {
    const runId = Date.now();
    const recruitmentDeadline = plusDaysYmd(1);
    const roundDate = plusDaysYmd(2);
    const payload = {
      meetingImagePath: "images/meetings/36ba1999-7622-4275-b44e-9642d234b6bb.png",
      title: `함께 읽는 에세이 모임 ${runId}`,
      description: "매주 한 챕터씩 읽고 이야기해요.",
      readingGenreId: 3,
      capacity: 8,
      roundCount: 1,
      startTime: "20:00",
      rounds: [
        {
          roundNo: 1,
          date: roundDate,
          book: {
            isbn: "9781234567890",
            title: "아몬드",
            authors: "손원평",
            publisher: "출판사",
          },
        },
      ],
      leaderIntro: "안녕하세요, 함께 완독해봐요!",
      leaderIntroSavePolicy: true,
      durationMinutes: 60,
      recruitmentDeadline,
    };

    const { res, body } = requestWithAuth(
      "POST",
      `${BASE_URL}/api/meetings`,
      JSON.stringify(payload)
    );
    if (!res) return;
    trackApi("meetings_create", "POST", res, body, [200, 201]);
    const created = runCheck(
      "meeting_create_200_201",
      "meeting create 200/201",
      res,
      (r) => r.status === 200 || r.status === 201
    );

    const createdMeetingId = pickFirst(body, [
      (b) => b?.data?.meetingId,
      (b) => b?.data?.id,
      (b) => b?.meetingId,
      (b) => b?.id,
    ]);

    if (createdMeetingId) {
      meetingId = createdMeetingId;
    }
    if (!created) {
      console.log("create status:", res.status);
      console.log("create body:", res.body);
      logStep("4) /api/meetings", res, body);
    }
  });

  // 5) GET /api/users/me/meetings?status=ACTIVE&size=10
  group("5) GET /api/users/me/meetings?status=ACTIVE&size=10", () => {
    const { res, body } = requestWithAuth(
      "GET",
      `${BASE_URL}/api/users/me/meetings?status=ACTIVE&size=10`
    );
    if (!res) return;
    trackApi("users_me_meetings_active", "GET", res, body);
    logStep("5) /api/users/me/meetings", res, body);
    runCheck("my_meetings_200", "my meetings 200", res, (r) => r.status === 200);

    // ✅ meetingId 후보 추출 (응답 구조 맞추기 전까지 여러 후보)
    meetingId =
      meetingId ||
      pickFirst(body, [
      (b) => b?.data?.items?.[0]?.meetingId,
      (b) => b?.data?.items?.[0]?.id,
      (b) => b?.data?.[0]?.meetingId,
      (b) => b?.items?.[0]?.meetingId,
      (b) => b?.items?.[0]?.id,
    ]);

    console.log(`meetingId extracted: ${meetingId || "NONE"}`);
  });

  // 6) GET /api/users/me/meetings/today
  group("6) GET /api/users/me/meetings/today", () => {
    const { res, body } = requestWithAuth("GET", `${BASE_URL}/api/users/me/meetings/today`);
    if (!res) return;
    trackApi("users_me_meetings_today", "GET", res, body);
    logStep("6) /api/users/me/meetings/today", res, body);
    runCheck("today_200", "today 200", res, (r) => r.status === 200);
  });

  // 7) GET /api/users/me/meetings/{meetingId}
  group("7) GET /api/users/me/meetings/{meetingId}", () => {
    if (!meetingId) {
      console.log("Skip 7) no meetingId");
      return;
    }
    const { res, body } = requestWithAuth("GET", `${BASE_URL}/api/users/me/meetings/${meetingId}`);
    if (!res) return;
    trackApi("users_me_meeting_detail", "GET", res, body);
    logStep("7) /api/users/me/meetings/{meetingId}", res, body);
    runCheck("meeting_detail_200", "meeting detail 200", res, (r) => r.status === 200);
  });

  // 7-1) GET /api/users/me/meetings/{meetingId} -> roundId 추출
  group("7-1) GET /api/users/me/meetings/{meetingId} for report", () => {
    if (!meetingId) {
      console.log("Skip 7-1) no meetingId for report");
      return;
    }
    const { res, body } = requestWithAuth(
      "GET",
      `${BASE_URL}/api/users/me/meetings/${meetingId}`
    );
    if (!res) return;
    trackApi("users_me_meeting_detail_for_report", "GET", res, body);
    logStep("7-1) /api/users/me/meetings/{meetingId} for report", res, body);
    runCheck("meeting_detail_200", "meeting detail 200", res, (r) => r.status === 200);

    fixedRoundId = pickFirst(body, [
      (b) => b?.data?.rounds?.[0]?.roundId,
      (b) => b?.data?.rounds?.[0]?.id,
      (b) => b?.rounds?.[0]?.roundId,
      (b) => b?.rounds?.[0]?.id,
    ]);

    console.log(`fixed roundId extracted: ${fixedRoundId || "NONE"}`);
  });

  // 7-2) POST /api/meeting-rounds/{roundId}/book-reports
  group("7-2) POST /api/meeting-rounds/{roundId}/book-reports", () => {
    if (!fixedRoundId) {
      console.log("Skip 7-2) no roundId from meeting detail");
      return;
    }
    const payload = { content: FIXED_BOOK_REPORT_CONTENT };
    const { res, body } = requestWithAuth(
      "POST",
      `${BASE_URL}/api/meeting-rounds/${fixedRoundId}/book-reports`,
      JSON.stringify(payload)
    );
    if (!res) return;
    trackApi("book_reports_create", "POST", res, body, [200, 201, 429]);
    logStep("7-2) /api/meeting-rounds/{roundId}/book-reports", res, body);
    runCheck(
      "book_report_200_201_429",
      "book report 200/201/429",
      res,
      (r) => r.status === 200 || r.status === 201 || r.status === 429
    );
  });

  // 8) GET /api/notifications/unread
  group("8) GET /api/notifications/unread", () => {
    const { res, body } = requestWithAuth("GET", `${BASE_URL}/api/notifications/unread`);
    if (!res) return;
    trackApi("notifications_unread", "GET", res, body);
    logStep("8) /api/notifications/unread", res, body);
    runCheck("unread_200", "unread 200", res, (r) => r.status === 200);
  });

  // 9) GET /api/notifications
  group("9) GET /api/notifications", () => {
    const { res, body } = requestWithAuth("GET", `${BASE_URL}/api/notifications`);
    if (!res) return;
    trackApi("notifications_list", "GET", res, body);
    logStep("9) /api/notifications", res, body);
    runCheck("notifications_200", "notifications 200", res, (r) => r.status === 200);

    // ✅ notificationId 후보 추출
    notificationId = pickFirst(body, [
      (b) => b?.data?.notifications?.[0]?.id,
    ]);

    console.log(`notificationId extracted: ${notificationId || "NONE"}`);
  });

  // 10) PUT /api/notifications/{notificationId}
  group("10) PUT /api/notifications/{notificationId}", () => {
    if (!notificationId) {
      console.log("Skip 10) no notificationId");
      return;
    }
    const { res, body } = requestWithAuth("PUT", `${BASE_URL}/api/notifications/${notificationId}`);
    if (!res) return;
    trackApi("notifications_mark_read", "PUT", res, body, [200, 204]);
    logStep("10) PUT /api/notifications/{id}", res, body);

    runCheck(
      "mark_read_200_204",
      "mark read 200/204",
      res,
      (r) => r.status === 200 || r.status === 204
    );
  });

  // 반복 간격 (과도한 루프 방지)
  sleep(1);
}
