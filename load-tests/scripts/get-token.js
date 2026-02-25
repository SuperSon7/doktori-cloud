/**
 * 카카오 OAuth 로그인 후 Access Token 자동 획득 스크립트
 *
 * 사용법:
 *   npm install playwright
 *   node scripts/get-token.js
 *
 * 옵션:
 *   --headless    브라우저 숨김 모드 (기본: 보임)
 *   --save        .env 파일에 저장
 */

const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

// 설정
const CONFIG = {
  // 서비스 OAuth 시작 URL
  oauthUrl: process.env.OAUTH_URL || 'https://your-api.com/api/oauth/kakao',

  // 프론트엔드 리다이렉트 후 URL 패턴 (토큰 확인용)
  frontendUrlPattern: process.env.FRONTEND_URL || 'https://your-frontend.com',

  // 타임아웃 (ms)
  timeout: 60000,

  // 브라우저 프로필 경로 (카카오 로그인 세션 유지용)
  userDataDir: path.join(__dirname, '.browser-profile'),
};

async function getToken() {
  const args = process.argv.slice(2);
  const headless = args.includes('--headless');
  const saveToEnv = args.includes('--save');

  console.log('========================================');
  console.log(' 카카오 OAuth 토큰 획득 스크립트');
  console.log('========================================');
  console.log(`OAuth URL: ${CONFIG.oauthUrl}`);
  console.log(`Headless: ${headless}`);
  console.log('');

  // 브라우저 프로필 디렉토리 생성
  if (!fs.existsSync(CONFIG.userDataDir)) {
    fs.mkdirSync(CONFIG.userDataDir, { recursive: true });
  }

  // 브라우저 실행 (프로필 유지 → 카카오 로그인 상태 유지)
  const context = await chromium.launchPersistentContext(CONFIG.userDataDir, {
    headless: headless,
    viewport: { width: 1280, height: 720 },
  });

  const page = await context.newPage();
  let accessToken = null;

  try {
    // 네트워크 응답 모니터링 (토큰 캡처용)
    page.on('response', async (response) => {
      const url = response.url();

      // 토큰 갱신 API 응답 캡처
      if (url.includes('/auth/tokens') && response.status() === 200) {
        try {
          const json = await response.json();
          if (json.data && json.data.accessToken) {
            accessToken = json.data.accessToken;
            console.log('[캡처] 토큰 갱신 응답에서 토큰 획득');
          }
        } catch (e) {}
      }
    });

    // 1. OAuth 시작 페이지로 이동
    console.log('[1/4] OAuth 페이지 이동...');
    await page.goto(CONFIG.oauthUrl, { waitUntil: 'networkidle', timeout: CONFIG.timeout });

    const currentUrl = page.url();
    console.log(`      현재 URL: ${currentUrl}`);

    // 2. 카카오 로그인 페이지 처리
    if (currentUrl.includes('kauth.kakao.com')) {
      console.log('[2/4] 카카오 로그인 페이지 감지');

      // 이미 로그인된 경우 → 동의 화면 또는 자동 리다이렉트
      // 로그인 필요한 경우 → 수동 입력 대기

      const loginForm = await page.$('input[name="loginId"]');
      if (loginForm) {
        console.log('');
        console.log('      ⚠️  카카오 로그인이 필요합니다.');
        console.log('      ⚠️  브라우저에서 직접 로그인해주세요.');
        console.log('');

        // 로그인 완료 대기 (URL 변경 감지)
        await page.waitForURL((url) => !url.toString().includes('kauth.kakao.com/oauth/authorize'), {
          timeout: CONFIG.timeout,
        });
      }
    }

    // 3. 카카오 동의 화면 처리
    const consentUrl = page.url();
    if (consentUrl.includes('kauth.kakao.com')) {
      console.log('[3/4] 카카오 동의 화면 처리...');

      // "동의하고 계속하기" 버튼 클릭
      const agreeButton = await page.$('button.submit');
      if (agreeButton) {
        await agreeButton.click();
        console.log('      동의 버튼 클릭');
      }

      // 리다이렉트 대기
      await page.waitForURL((url) => !url.toString().includes('kauth.kakao.com'), {
        timeout: CONFIG.timeout,
      });
    }

    // 4. 프론트엔드 리다이렉트 후 토큰 확인
    console.log('[4/4] 토큰 확인 중...');

    // 쿠키에서 토큰 확인
    const cookies = await context.cookies();
    const refreshTokenCookie = cookies.find((c) => c.name === 'refreshToken');

    if (refreshTokenCookie) {
      console.log('      Refresh Token 쿠키 발견');
    }

    // 잠시 대기 (프론트엔드 처리 시간)
    await page.waitForTimeout(2000);

    // 토큰이 아직 없으면 토큰 갱신 API 직접 호출
    if (!accessToken && refreshTokenCookie) {
      console.log('      토큰 갱신 API 호출...');

      const baseUrl = CONFIG.oauthUrl.replace('/oauth/kakao', '');
      const tokenResponse = await page.evaluate(async (url) => {
        const res = await fetch(`${url}/auth/tokens`, {
          method: 'POST',
          credentials: 'include',
        });
        return res.json();
      }, baseUrl);

      if (tokenResponse.data && tokenResponse.data.accessToken) {
        accessToken = tokenResponse.data.accessToken;
      }
    }

    // 결과 출력
    console.log('');
    console.log('========================================');

    if (accessToken) {
      console.log(' ✅ Access Token 획득 성공!');
      console.log('========================================');
      console.log('');
      console.log('Access Token:');
      console.log(accessToken);
      console.log('');

      // .env 파일에 저장
      if (saveToEnv) {
        const envPath = path.join(__dirname, '..', '.env');
        const envContent = `JWT_TOKEN=${accessToken}\n`;
        fs.writeFileSync(envPath, envContent);
        console.log(`.env 파일 저장 완료: ${envPath}`);
      }

      // 환경변수 export 명령어 출력
      console.log('사용법:');
      console.log(`  export JWT_TOKEN="${accessToken}"`);
      console.log('');

    } else {
      console.log(' ❌ Access Token 획득 실패');
      console.log('========================================');
      console.log('');
      console.log('수동으로 확인해주세요:');
      console.log('1. 브라우저 개발자도구 → Network 탭');
      console.log('2. /auth/tokens 요청 찾기');
      console.log('3. Response에서 accessToken 복사');
    }

  } catch (error) {
    console.error('오류 발생:', error.message);
  } finally {
    if (headless) {
      await context.close();
    } else {
      console.log('브라우저를 닫으려면 Ctrl+C를 누르세요.');
      // 브라우저 열어둠 (디버깅용)
      await new Promise(() => {});
    }
  }
}

getToken();
