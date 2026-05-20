import http from 'k6/http';
import { check, sleep } from 'k6';
import { SharedArray } from 'k6/data';
import { Rate, Trend } from 'k6/metrics';
import { config } from './config.js';

const tokenFileData = __ENV.TOKEN_FILE
  ? new SharedArray('token-file-data', () => JSON.parse(open(__ENV.TOKEN_FILE)))
  : null;

// 커스텀 메트릭
export const errorRate = new Rate('errors');           // SLO-1: 5xx만 카운트
export const clientErrorRate = new Rate('client_errors'); // 디버깅용: 4xx 카운트
export const apiDuration = new Trend('api_duration', true);

// Access Token 저장소 (VU별로 공유)
let _accessToken = config.accessToken;

// Access Token 갱신
export function refreshAccessToken() {
  if (!config.refreshToken) {
    console.log('REFRESH_TOKEN이 설정되지 않았습니다.');
    return false;
  }

  const url = `${config.baseUrl}/auth/tokens`;
  const response = http.post(url, null, {
    headers: {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    },
    cookies: {
      refreshToken: config.refreshToken,
    },
    tags: { name: '/auth/tokens' },
  });

  if (response.status === 200) {
    try {
      const json = response.json();
      if (json.data && json.data.accessToken) {
        _accessToken = json.data.accessToken;
        console.log('Access Token 갱신 성공');
        return true;
      }
    } catch (e) {
      console.log('토큰 응답 파싱 실패:', e.message);
    }
  } else {
    console.log(`토큰 갱신 실패: ${response.status}`);
  }

  return false;
}

// 현재 Access Token 반환
export function getAccessToken() {
  return _accessToken;
}

// HTTP 헤더
export function getHeaders(withAuth = false) {
  const headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  if (withAuth && _accessToken) {
    headers['Authorization'] = `Bearer ${_accessToken}`;
  }

  return headers;
}

// 401 응답 시 토큰 갱신 후 재시도
function handleResponse(response, retryFn, auth) {
  if (response.status === 401 && auth && config.refreshToken) {
    console.log('401 응답 - 토큰 갱신 시도');
    if (refreshAccessToken()) {
      // 재시도
      return retryFn();
    }
  }
  return response;
}

// GET 요청 헬퍼
export function apiGet(path, params = {}, auth = false) {
  const url = `${config.baseUrl}${path}`;

  const doRequest = () => {
    return http.get(url, {
      headers: getHeaders(auth),
      tags: { name: path.split('?')[0] },
      ...params,
    });
  };

  let response = doRequest();
  response = handleResponse(response, doRequest, auth);

  apiDuration.add(response.timings.duration);
  errorRate.add(response.status >= 500);
  clientErrorRate.add(response.status >= 400 && response.status < 500);

  return response;
}

// POST 요청 헬퍼
export function apiPost(path, body = {}, auth = false) {
  const url = `${config.baseUrl}${path}`;

  const doRequest = () => {
    return http.post(url, JSON.stringify(body), {
      headers: getHeaders(auth),
      tags: { name: path.split('?')[0] },
    });
  };

  let response = doRequest();
  response = handleResponse(response, doRequest, auth);

  apiDuration.add(response.timings.duration);
  errorRate.add(response.status >= 500);
  clientErrorRate.add(response.status >= 400 && response.status < 500);

  return response;
}

// PUT 요청 헬퍼
export function apiPut(path, body = {}, auth = false) {
  const url = `${config.baseUrl}${path}`;

  const doRequest = () => {
    return http.put(url, JSON.stringify(body), {
      headers: getHeaders(auth),
      tags: { name: path.split('?')[0] },
    });
  };

  let response = doRequest();
  response = handleResponse(response, doRequest, auth);

  apiDuration.add(response.timings.duration);
  errorRate.add(response.status >= 500);
  clientErrorRate.add(response.status >= 400 && response.status < 500);

  return response;
}

// DELETE 요청 헬퍼
export function apiDelete(path, auth = false) {
  const url = `${config.baseUrl}${path}`;

  const doRequest = () => {
    return http.del(url, null, {
      headers: getHeaders(auth),
      tags: { name: path.split('?')[0] },
    });
  };

  let response = doRequest();
  response = handleResponse(response, doRequest, auth);

  apiDuration.add(response.timings.duration);
  errorRate.add(response.status >= 500);
  clientErrorRate.add(response.status >= 400 && response.status < 500);

  return response;
}

// POST 요청 (토큰 직접 지정 — 다중 사용자 시나리오용)
export function apiPostWithToken(path, body = {}, token = null) {
  const url = `${config.baseUrl}${path}`;

  const response = http.post(url, JSON.stringify(body), {
    headers: authHeaders(token),
    tags: { name: path.split('?')[0] },
  });

  apiDuration.add(response.timings.duration);
  errorRate.add(response.status >= 500);
  clientErrorRate.add(response.status >= 400 && response.status < 500);

  return response;
}

// 응답 검증 헬퍼
export function checkResponse(response, expectedStatus = 200, name = 'API') {
  return check(response, {
    [`${name} status is ${expectedStatus}`]: (r) => r.status === expectedStatus,
    [`${name} response time < 1000ms`]: (r) => r.timings.duration < 1000,
  });
}

// 응답에서 데이터 추출
export function extractData(response) {
  try {
    const json = response.json();
    return json.data || json;
  } catch (e) {
    return null;
  }
}

// 랜덤 요소 선택
export function randomItem(array) {
  return array[Math.floor(Math.random() * array.length)];
}

// 랜덤 정수 (min 이상 max 미만)
export function randomInt(min, max) {
  return Math.floor(Math.random() * (max - min)) + min;
}

// Think Time (사용자 대기 시간 시뮬레이션)
export function thinkTime(minSec = 1, maxSec = 3) {
  sleep(randomInt(minSec, maxSec));
}

// 커서 기반 페이지네이션 반복
export function paginateWithCursor(path, params = {}, maxPages = 3, auth = false) {
  const results = [];
  let cursorId = null;

  for (let page = 0; page < maxPages; page++) {
    const queryParams = { ...params };
    if (cursorId) {
      queryParams.cursorId = cursorId;
    }

    const queryString = Object.entries(queryParams)
      .map(([k, v]) => `${k}=${encodeURIComponent(v)}`)
      .join('&');

    const fullPath = queryString ? `${path}?${queryString}` : path;
    const response = apiGet(fullPath, {}, auth);

    checkResponse(response, 200, `${path} page ${page + 1}`);

    const data = extractData(response);
    if (!data || !data.items || data.items.length === 0) {
      break;
    }

    results.push(...data.items);

    // 다음 페이지 커서 확인
    if (!data.pageInfo || !data.pageInfo.hasNext) {
      break;
    }
    cursorId = data.pageInfo.nextCursorId;

    thinkTime(1, 2);
  }

  return results;
}

// 테스트 시작 시 토큰 초기화 (setup에서 호출)
export function initAuth() {
  const tokens = fetchMultiTokens(1);
  if (tokens.length > 0) {
    _accessToken = tokens[0];
    console.log('/dev/tokens에서 Access Token 로드');
    return true;
  }

  if (config.accessToken) {
    _accessToken = config.accessToken; // migration 호환용 fallback
    console.log('JWT_TOKEN 환경변수에서 토큰 로드');
    return true;
  }

  if (config.refreshToken) {
    console.log('REFRESH_TOKEN으로 Access Token 발급 시도...');
    return refreshAccessToken();
  }

  console.log('인증 토큰이 설정되지 않았습니다. (JWT_TOKEN 또는 REFRESH_TOKEN 필요)');
  return false;
}

// ── 멀티 토큰 (다수 유저 시뮬레이션) ──────────────────────────────────────

// /api/dev/tokens 에서 테스트 유저 토큰 목록을 발급받아 반환 (setup에서 1회 호출)
export function fetchMultiTokens(count = 500) {
  if (Array.isArray(tokenFileData) && tokenFileData.length > 0) {
    const tokens = tokenFileData
      .slice(0, count)
      .map(t => typeof t === 'string' ? t : (t.accessToken || t.token));
    console.log(`로컬 토큰 파일 ${tokens.length}개 로드 성공`);
    return tokens;
  }

  const baseUrl = __ENV.BASE_URL || config.baseUrl;
  const pageSize = Math.min(Number(__ENV.TOKEN_PAGE_SIZE || 100), count);
  const baseOffset = Number(__ENV.TOKEN_OFFSET || 0);
  const tokens = [];

  for (let fetched = 0; fetched < count; fetched += pageSize) {
    const limit = Math.min(pageSize, count - fetched);
    const offset = baseOffset + fetched;
    const tokenUrl = `${baseUrl}/dev/tokens?limit=${limit}&offset=${offset}`;

    console.log(`멀티 토큰 발급: ${tokenUrl}`);
    const res = http.get(tokenUrl, {
      headers: { 'Accept': 'application/json' },
      tags: { name: '/dev/tokens' },
      timeout: __ENV.TOKEN_FETCH_TIMEOUT || '300s',
    });

    if (res.status !== 200) {
      console.log(`멀티 토큰 발급 실패: ${res.status} (offset=${offset}, limit=${limit})`);
      break;
    }

    try {
      const json = res.json();
      const items = json.data || json.tokens || json;
      if (!Array.isArray(items) || items.length === 0) {
        break;
      }

      tokens.push(...items.map(t => typeof t === 'string' ? t : (t.accessToken || t.token)));

      if (items.length < limit) {
        break;
      }
    } catch (e) {
      console.log(`멀티 토큰 파싱 실패(offset=${offset}):`, e.message);
      break;
    }
  }

  if (tokens.length > 0) {
    console.log(`멀티 토큰 ${tokens.length}개 발급 성공`);
    return tokens;
  }

  return [];
}

// VU별 라운드로빈 토큰 선택
export function pickToken(tokens) {
  if (!tokens || tokens.length === 0) return null;
  return tokens[__VU % tokens.length];
}

export function authHeaders(token, extra = {}) {
  const headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    ...extra,
  };
  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
  }
  return headers;
}

// 특정 토큰으로 GET
export function apiGetWithToken(path, token, params = {}) {
  const url = `${config.baseUrl}${path}`;

  const response = http.get(url, {
    headers: authHeaders(token),
    tags: { name: path.split('?')[0] },
    ...params,
  });

  apiDuration.add(response.timings.duration);
  errorRate.add(response.status >= 500);
  clientErrorRate.add(response.status >= 400 && response.status < 500);
  return response;
}

// 특정 토큰으로 PUT
export function apiPutWithToken(path, body = {}, token = null) {
  const url = `${config.baseUrl}${path}`;

  const response = http.put(url, JSON.stringify(body), {
    headers: authHeaders(token),
    tags: { name: path.split('?')[0] },
  });

  apiDuration.add(response.timings.duration);
  errorRate.add(response.status >= 500);
  clientErrorRate.add(response.status >= 400 && response.status < 500);
  return response;
}

export function apiDeleteWithToken(path, token = null) {
  const url = `${config.baseUrl}${path}`;

  const response = http.del(url, null, {
    headers: authHeaders(token),
    tags: { name: path.split('?')[0] },
  });

  apiDuration.add(response.timings.duration);
  errorRate.add(response.status >= 500);
  clientErrorRate.add(response.status >= 400 && response.status < 500);
  return response;
}
