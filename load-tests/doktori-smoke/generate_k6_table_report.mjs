#!/usr/bin/env node

import fs from "fs";
import path from "path";

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) continue;
    const key = token.slice(2);
    const next = argv[i + 1];
    if (!next || next.startsWith("--")) {
      args[key] = "true";
      continue;
    }
    args[key] = next;
    i += 1;
  }
  return args;
}

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

function pct(v) {
  if (v === null) return "-";
  const n = v <= 1 ? v * 100 : v;
  return `${n.toFixed(2)}%`;
}

function ms(v) {
  if (v === null) return "-";
  if (v >= 1000) return `${(v / 1000).toFixed(2)}s`;
  return `${v.toFixed(2)}ms`;
}

function escapeHtml(s) {
  return String(s)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function metric(summary, name) {
  return summary?.metrics?.[name] || null;
}

const CHECK_METRIC_CONFIG = [
  { name: "me 200", pass: "check_me_200_pass", fail: "check_me_200_fail" },
  { name: "reco 200", pass: "check_reco_200_pass", fail: "check_reco_200_fail" },
  { name: "meeting create 200/201", pass: "check_meeting_create_200_201_pass", fail: "check_meeting_create_200_201_fail" },
  { name: "my meetings 200", pass: "check_my_meetings_200_pass", fail: "check_my_meetings_200_fail" },
  { name: "today 200", pass: "check_today_200_pass", fail: "check_today_200_fail" },
  { name: "meeting detail 200", pass: "check_meeting_detail_200_pass", fail: "check_meeting_detail_200_fail" },
  { name: "book report 200/201/429", pass: "check_book_report_200_201_429_pass", fail: "check_book_report_200_201_429_fail" },
  { name: "unread 200", pass: "check_unread_200_pass", fail: "check_unread_200_fail" },
  { name: "notifications 200", pass: "check_notifications_200_pass", fail: "check_notifications_200_fail" },
  { name: "mark read 200/204", pass: "check_mark_read_200_204_pass", fail: "check_mark_read_200_204_fail" },
];

const CHECK_METHOD_PREFIX = {
  "me 200": "GET",
  "reco 200": "GET",
  "meeting create 200/201": "POST",
  "my meetings 200": "GET",
  "today 200": "GET",
  "meeting detail 200": "GET",
  "book report 200/201/429": "POST",
  "unread 200": "GET",
  "notifications 200": "GET",
  "mark read 200/204": "PUT",
};

function decorateCheckName(name) {
  const method = CHECK_METHOD_PREFIX[name];
  return method ? `[${method}] ${name}` : name;
}

function parseCheckRowsFromSummary(summary) {
  const rows = [];
  for (const cfg of CHECK_METRIC_CONFIG) {
    const passCount = num(metric(summary, cfg.pass)?.count) ?? 0;
    const failCount = num(metric(summary, cfg.fail)?.count) ?? 0;
    const total = passCount + failCount;
    if (total === 0) continue;
    const successRate = `${((passCount / total) * 100).toFixed(2)}%`;
    const status = failCount > 0 ? "FAIL" : "PASS";
    rows.push({
      status,
      name: decorateCheckName(cfg.name),
      successRate,
      pass: String(passCount),
      fail: String(failCount),
    });
  }
  return rows;
}

function metricCount(m) {
  return num(m?.count) ?? 0;
}

function percentile(values, p) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const idx = Math.ceil((p / 100) * sorted.length) - 1;
  return sorted[Math.max(0, Math.min(sorted.length - 1, idx))];
}

function formatSecLabel(sec) {
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

function buildTimeSeries(rawPath) {
  if (!rawPath) return null;
  if (!fs.existsSync(rawPath)) return null;

  const lines = fs.readFileSync(rawPath, "utf8").split(/\r?\n/);
  let startTs = null;
  let maxSec = -1;
  const buckets = new Map();

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    let row;
    try {
      row = JSON.parse(trimmed);
    } catch {
      continue;
    }

    if (row?.type !== "Point") continue;
    const t = row?.data?.time;
    const metricName = row?.metric;
    const value = num(row?.data?.value);
    if (!t || !metricName || value === null) continue;

    const ts = Date.parse(t);
    if (!Number.isFinite(ts)) continue;
    if (startTs === null) startTs = ts;

    const sec = Math.max(0, Math.floor((ts - startTs) / 1000));
    maxSec = Math.max(maxSec, sec);
    if (!buckets.has(sec)) {
      buckets.set(sec, { reqs: 0, durations: [], fails: 0 });
    }
    const b = buckets.get(sec);

    if (metricName === "http_reqs") b.reqs += 1;
    if (metricName === "http_req_duration") b.durations.push(value);
    if (metricName === "http_req_failed") b.fails += value;
  }

  if (maxSec < 0) return null;

  const labels = [];
  const rps = [];
  const avg = [];
  const p95 = [];
  const failRate = [];

  for (let sec = 0; sec <= maxSec; sec += 1) {
    const b = buckets.get(sec) || { reqs: 0, durations: [], fails: 0 };
    const avgVal = b.durations.length
      ? b.durations.reduce((acc, v) => acc + v, 0) / b.durations.length
      : null;
    const p95Val = b.durations.length ? percentile(b.durations, 95) : null;
    const failPct = b.reqs > 0 ? (b.fails / b.reqs) * 100 : 0;

    labels.push(formatSecLabel(sec));
    rps.push(Number(b.reqs.toFixed(2)));
    avg.push(avgVal === null ? null : Number(avgVal.toFixed(2)));
    p95.push(p95Val === null ? null : Number(p95Val.toFixed(2)));
    failRate.push(Number(failPct.toFixed(2)));
  }

  return { labels, rps, avg, p95, failRate };
}

function renderTemplate(template, values) {
  let out = template;
  for (const [k, v] of Object.entries(values)) {
    out = out.replaceAll(`{{${k}}}`, String(v));
  }
  return out;
}

function buildHtmlReport(data) {
  const {
    templatePath,
    summaryPath,
    logPath,
    runMeta,
    checks,
    httpReqFailed,
    httpReqDuration,
    httpReqs,
    iterations,
    checkRows,
    writeSuccess,
    writeFailure,
    serverError,
    migrationSuspect,
    apiGetCount,
    apiPostCount,
    apiPutCount,
    apiDeleteCount,
    rawPath,
  } = data;

  const getN = metricCount(apiGetCount);
  const postN = metricCount(apiPostCount);
  const putN = metricCount(apiPutCount);
  const deleteN = metricCount(apiDeleteCount);
  const methodTotal = Math.max(getN + postN + putN + deleteN, 1);

  const checksRowsHtml = checkRows
    .map((r) => {
      const cls = r.status === "PASS" ? "ok" : "fail";
      return `<tr>
  <td><span class="badge ${cls}">${escapeHtml(r.status)}</span></td>
  <td>${escapeHtml(r.name)}</td>
  <td>${escapeHtml(r.successRate)}</td>
  <td>${escapeHtml(r.pass)}</td>
  <td>${escapeHtml(r.fail)}</td>
</tr>`;
    })
    .join("\n");

  const methodBars = [
    { label: "GET", count: getN, color: "#1f77b4" },
    { label: "POST", count: postN, color: "#2ca02c" },
    { label: "PUT", count: putN, color: "#ff7f0e" },
    { label: "DELETE", count: deleteN, color: "#d62728" },
  ]
    .map((m) => {
      const ratio = ((m.count / methodTotal) * 100).toFixed(1);
      return `<div class="bar-row">
  <div class="bar-label">${m.label}</div>
  <div class="bar-wrap"><div class="bar" style="width:${ratio}%;background:${m.color};"></div></div>
  <div class="bar-value">${m.count}</div>
</div>`;
    })
    .join("\n");

  const methodRowsHtml = [
    { label: "GET", count: getN, color: "#3b82f6" },
    { label: "POST", count: postN, color: "#10b981" },
    { label: "PUT", count: putN, color: "#f59e0b" },
    { label: "DEL", count: deleteN, color: "#64748b" },
  ]
    .map((m) => {
      const ratio = Math.max((m.count / methodTotal) * 100, m.count > 0 ? 0.5 : 0.1).toFixed(1);
      return `<div class="method-row">
  <div class="method-name" style="color:${m.color};">${m.label}</div>
  <div class="method-track"><div class="method-fill" style="width:${ratio}%; background:linear-gradient(90deg,${m.color}B3,${m.color}4D);"><span>${ratio}%</span></div></div>
  <div class="method-count">${m.count}</div>
</div>`;
    })
    .join("\n");

  const checksDetailRowsHtml = checkRows
    .map((r) => {
      const isPass = r.status === "PASS";
      const statusClass = isPass ? "ok" : "fail";
      const statusLabel = isPass ? "✓ PASS" : "✗ FAIL";
      const rateNum = Number(String(r.successRate).replace("%", "")) || 0;
      return `<tr><td style="padding-left:20px;"><span class="badge ${statusClass}">${statusLabel}</span></td><td><span class="check-name">${escapeHtml(r.name)}</span></td><td><div class="pass-bar-wrap"><div class="pass-bar" style="width:${Math.max(0, Math.min(100, rateNum))}%;"></div></div><span class="num ${isPass ? "ok" : "fail"}">${escapeHtml(r.successRate)}</span></td><td><span class="num ok">${escapeHtml(r.pass)}</span></td><td style="padding-right:20px;"><span class="num ${isPass ? "muted" : "fail"}">${escapeHtml(r.fail)}</span></td></tr>`;
    })
    .join("\n");

  const checksPass = num(checks.passes) ?? 0;
  const checksFail = num(checks.fails) ?? 0;
  const checksTotal = checksPass + checksFail;
  const allPass = checksFail === 0;
  const targetHost = runMeta.baseUrl.replace(/^https?:\/\//, "").replace(/\/+$/, "");
  const generatedDate = new Date();
  const generatedDateShort = generatedDate.toISOString().slice(0, 10);
  const timeseries = buildTimeSeries(rawPath);
  const hasTimeseries = Boolean(timeseries?.labels?.length);

  const tpl = fs.readFileSync(templatePath, "utf8");
  return renderTemplate(tpl, {
    generated_at: escapeHtml(new Date().toISOString()),
    summary_path: escapeHtml(summaryPath),
    summary_file_name: escapeHtml(path.basename(summaryPath)),
    log_path: escapeHtml(logPath),
    env_name: escapeHtml(runMeta.envName),
    vus: escapeHtml(runMeta.vus),
    duration: escapeHtml(runMeta.duration),
    base_url: escapeHtml(runMeta.baseUrl),
    target_host: escapeHtml(targetHost),
    script_path: escapeHtml(runMeta.script),
    checks_success: escapeHtml(pct(num(checks.value))),
    checks_pass_count: escapeHtml(String(checksPass)),
    checks_fail_count: escapeHtml(String(checksFail)),
    checks_total_count: escapeHtml(String(checksTotal)),
    checks_status_text: allPass ? "전체 체크 PASS" : "체크 실패 존재",
    checks_status_suffix: allPass ? "✓ All checks passed" : "⚠ Failed checks exist",
    checks_status_badge_class: allPass ? "ok" : "fail",
    http_req_failed: escapeHtml(pct(num(httpReqFailed.value))),
    http_reqs: escapeHtml(String(num(httpReqs.count) ?? "-")),
    iterations: escapeHtml(String(num(iterations.count) ?? "-")),
    resp_avg: escapeHtml(ms(num(httpReqDuration.avg))),
    resp_med: escapeHtml(ms(num(httpReqDuration.med))),
    resp_p90: escapeHtml(ms(num(httpReqDuration["p(90)"]))),
    resp_p95: escapeHtml(ms(num(httpReqDuration["p(95)"]))),
    resp_max: escapeHtml(ms(num(httpReqDuration.max))),
    checks_rows_html: checksRowsHtml,
    checks_detail_rows_html: checksDetailRowsHtml,
    method_bars_html: methodBars,
    method_rows_html: methodRowsHtml,
    method_total_count: escapeHtml(String(getN + postN + putN + deleteN)),
    get_count: escapeHtml(String(getN)),
    post_count: escapeHtml(String(postN)),
    put_count: escapeHtml(String(putN)),
    delete_count: escapeHtml(String(deleteN)),
    write_success_rate: escapeHtml(writeSuccess ? pct(num(writeSuccess.value)) : "-"),
    write_failure_count: escapeHtml(String(writeFailure ? num(writeFailure.count) ?? 0 : 0)),
    server_error_count: escapeHtml(String(serverError ? num(serverError.count) ?? 0 : 0)),
    migration_suspect_count: escapeHtml(String(migrationSuspect ? num(migrationSuspect.count) ?? 0 : 0)),
    raw_file_name: escapeHtml(rawPath ? path.basename(rawPath) : "-"),
    timeseries_enabled: hasTimeseries ? "true" : "false",
    timeseries_labels_json: hasTimeseries ? JSON.stringify(timeseries.labels) : "[]",
    timeseries_rps_json: hasTimeseries ? JSON.stringify(timeseries.rps) : "[]",
    timeseries_avg_json: hasTimeseries ? JSON.stringify(timeseries.avg) : "[]",
    timeseries_p95_json: hasTimeseries ? JSON.stringify(timeseries.p95) : "[]",
    timeseries_fail_json: hasTimeseries ? JSON.stringify(timeseries.failRate) : "[]",
    generated_date_short: escapeHtml(generatedDateShort),
  });
}

function parseCheckRows(logText) {
  const lines = logText.split(/\r?\n/);
  const rows = [];
  const checkHeader = /^\s*[✓✗]\s+(.+?)\s*$/;
  const checkDetail = /↳\s+([0-9.]+)%\s+—\s+✓\s+([0-9]+)\s+\/\s+✗\s+([0-9]+)/;

  for (let i = 0; i < lines.length; i += 1) {
    const m = lines[i].match(checkHeader);
    if (!m) continue;

    const status = lines[i].includes("✓") ? "PASS" : "FAIL";
    const name = m[1].trim();
    let successRate = "세부없음";
    let pass = "-";
    let fail = "-";

    const next = lines[i + 1] || "";
    const d = next.match(checkDetail);
    if (d) {
      successRate = `${d[1]}%`;
      pass = d[2];
      fail = d[3];
      i += 1;
    }

    rows.push({ status, name: decorateCheckName(name), successRate, pass, fail });
  }

  return rows;
}

function main() {
  const args = parseArgs(process.argv);
  const summaryPath = args.summary;
  const logPath = args.log;
  if (!summaryPath || !logPath) {
    console.error("Usage: node generate_k6_table_report.mjs --summary <summary.json> --log <run.log> [--raw <k6_raw.json>] [--out <report.md>]");
    process.exit(1);
  }

  const summary = JSON.parse(fs.readFileSync(summaryPath, "utf8"));
  const logText = fs.readFileSync(logPath, "utf8");
  const templatePath = path.resolve(
    args.template ||
      path.join(path.dirname(process.argv[1]), "templates", "k6_report_template.html")
  );
  const rawPath = args.raw ? path.resolve(args.raw) : "";

  const outPath =
    args.out ||
    path.join(
      "logs",
      `k6_table_report_${path.basename(summaryPath).replace(/\.json$/, "")}.md`
    );
  const htmlOutPath =
    args["html-out"] ||
    outPath.replace(/\.md$/i, ".html");

  const runMeta = {
    envName: args["env-name"] || "-",
    vus: args.vus || "-",
    duration: args.duration || "-",
    baseUrl: args["base-url"] || "-",
    script: args.script || "-",
  };

  const checks = metric(summary, "checks") || {};
  const httpReqFailed = metric(summary, "http_req_failed") || {};
  const httpReqDuration = metric(summary, "http_req_duration") || {};
  const iterations = metric(summary, "iterations") || {};
  const httpReqs = metric(summary, "http_reqs") || {};

  const writeSuccess = metric(summary, "write_success_rate");
  const writeFailure = metric(summary, "write_failure_count");
  const migrationSuspect = metric(summary, "migration_suspect_error_count");
  const serverError = metric(summary, "server_error_count");
  const apiGetCount = metric(summary, "api_get_count");
  const apiPostCount = metric(summary, "api_post_count");
  const apiPutCount = metric(summary, "api_put_count");
  const apiDeleteCount = metric(summary, "api_delete_count");

  const rowsFromSummary = parseCheckRowsFromSummary(summary);
  const rows = rowsFromSummary.length ? rowsFromSummary : parseCheckRows(logText);
  const checkTable = rows.length
    ? rows
        .map(
          (r) =>
            `| ${r.status} | ${r.name} | ${r.successRate} | ${r.pass} | ${r.fail} |`
        )
        .join("\n")
    : "| N/A | check details not found in log | N/A | N/A | N/A |";

  const customMetricTable = [
    `| 쓰기 성공률(write_success_rate) | ${writeSuccess ? pct(num(writeSuccess.value)) : "-"} |`,
    `| 쓰기 실패 건수(write_failure_count) | ${writeFailure ? num(writeFailure.count) ?? 0 : 0} |`,
    `| 서버 5xx 건수(server_error_count) | ${serverError ? num(serverError.count) ?? 0 : 0} |`,
    `| 마이그레이션 의심 건수(migration_suspect_error_count) | ${migrationSuspect ? num(migrationSuspect.count) ?? 0 : 0} |`,
  ].join("\n");

  const methodMetricTable = [
    `| GET 요청 수(api_get_count) | ${apiGetCount ? num(apiGetCount.count) ?? 0 : 0} |`,
    `| POST 요청 수(api_post_count) | ${apiPostCount ? num(apiPostCount.count) ?? 0 : 0} |`,
    `| PUT 요청 수(api_put_count) | ${apiPutCount ? num(apiPutCount.count) ?? 0 : 0} |`,
    `| DELETE 요청 수(api_delete_count) | ${apiDeleteCount ? num(apiDeleteCount.count) ?? 0 : 0} |`,
  ].join("\n");

  const report = `# k6 부하테스트 표 리포트

- 생성 시각: ${new Date().toISOString()}
- 요약 파일: \`${summaryPath}\`
- 로그 파일: \`${logPath}\`
- 원본 시계열(raw): \`${rawPath || "-"}\`

## 실행 조건
| 항목 | 값 |
|---|---|
| 실행 환경 | ${runMeta.envName} |
| 동시 접속자(VUs) | ${runMeta.vus} |
| 부하 지속시간(Duration) | ${runMeta.duration} |
| 대상 서버(BASE_URL) | ${runMeta.baseUrl} |
| 실행 스크립트 | ${runMeta.script} |

## 전체 요약
| 지표 | 값 |
|---|---:|
| 체크 성공률 | ${pct(num(checks.value))} |
| 체크 통과/실패 | ${num(checks.passes) ?? "-"} / ${num(checks.fails) ?? "-"} |
| HTTP 실패율(http_req_failed) | ${pct(num(httpReqFailed.value))} |
| 총 요청 수(http_reqs) | ${num(httpReqs.count) ?? "-"} |
| 반복 수(iterations) | ${num(iterations.count) ?? "-"} |
| 응답시간 평균 | ${ms(num(httpReqDuration.avg))} |
| 응답시간 중앙값 | ${ms(num(httpReqDuration.med))} |
| 응답시간 p90 | ${ms(num(httpReqDuration["p(90)"]))} |
| 응답시간 p95 | ${ms(num(httpReqDuration["p(95)"]))} |
| 응답시간 최대 | ${ms(num(httpReqDuration.max))} |

## 체크 상세
| 상태 | 체크 항목 | 성공률 | 통과 | 실패 |
|---|---|---:|---:|---:|
${checkTable}

## 커스텀 지표 (쓰기/마이그레이션)
| 지표 | 값 |
|---|---:|
${customMetricTable}

## 메서드별 요청 수
| 지표 | 값 |
|---|---:|
${methodMetricTable}

## 참고
- \`세부없음\`은 k6 기본 요약/로그에서 해당 체크의 개별 통과/실패 건수를 제공하지 않아 계산할 수 없다는 뜻입니다.
`;

  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, report, "utf8");
  const html = buildHtmlReport({
    templatePath,
    summaryPath,
    logPath,
    runMeta,
    checks,
    httpReqFailed,
    httpReqDuration,
    httpReqs,
    iterations,
    checkRows: rows,
    writeSuccess,
    writeFailure,
    serverError,
    migrationSuspect,
    apiGetCount,
    apiPostCount,
    apiPutCount,
    apiDeleteCount,
    rawPath,
  });
  fs.writeFileSync(htmlOutPath, html, "utf8");
  console.log(`${outPath}\n${htmlOutPath}`);
}

main();
