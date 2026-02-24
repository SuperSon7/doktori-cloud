# k6 성능 테스트 (Scenario 2 Probe)

## 포함 파일
- `run_k6_with_report.sh`
- `script_scenario2_probe.js`
- `generate_k6_table_report.mjs`
- `templates/k6_report_template.html`

## 실행 방법
```bash
ACCESS_TOKEN="eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMiIsInVzZXJJZCI6MTIsIm5pY2tuYW1lIjoi6rmA7KeA7ISdIiwiaWF0IjoxNzcxOTQyNTM4LCJleHAiOjE3NzE5NDQzMzh9.mL0a87909IO7QxshuCXO5sAXTDL7qA1Wmrr58_3b5rg" VUS=1 DURATION=10s ./run_k6_with_report.sh
```
VUS = 동시접속자, DURATION = 부하테스트 실행 시간 설정

## 중요 안내
- 실행 전에 `ACCESS_TOKEN` 값을 네트워크 관리자페이지에서 찾아 반드시 수동으로 설정/변경해야 합니다.
- 실제 토큰은 GitHub에 커밋하면 안 됩니다.
- 로컬 환경에서 본인 토큰으로 교체해서 사용하세요.
