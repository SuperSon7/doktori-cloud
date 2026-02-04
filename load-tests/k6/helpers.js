import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';
import { config } from './config.js';

// 커스텀 메트릭
export const errorRate = new Rate('errors');
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
  errorRate.add(response.status >= 400);

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
  errorRate.add(response.status >= 400);

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
  errorRate.add(response.status >= 400);

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
  errorRate.add(response.status >= 400);

  return response;
}

// 응답 검증 헬퍼
export function checkResponse(response, expectedStatus = 200, name = 'API') {
  return check(response, {
    [`${name} status is ${expectedStatus}`]: (r) => r.status === expectedStatus,
    [`${name} response time < 500ms`]: (r) => r.timings.duration < 500,
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
  if (config.accessToken) {
    _accessToken = config.accessToken;
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
