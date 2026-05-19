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

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function metric(summary, name) {
  return summary.metrics?.[name] || null;
}

function metricValues(m) {
  if (!m) return null;
  return m.values || m;
}

function fmtNum(value, digits = 2) {
  if (value === null || value === undefined || Number.isNaN(Number(value))) return "-";
  return Number(value).toFixed(digits);
}

function fmtMs(value) {
  if (value === null || value === undefined || Number.isNaN(Number(value))) return "-";
  const n = Number(value);
  return n >= 1000 ? `${(n / 1000).toFixed(2)}s` : `${n.toFixed(2)}ms`;
}

function fmtPct(value) {
  if (value === null || value === undefined || Number.isNaN(Number(value))) return "-";
  return `${(Number(value) * 100).toFixed(2)}%`;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function card(title, value, cls = "info") {
  return `
    <div class="card">
      <div class="card-title">${escapeHtml(title)}</div>
      <div class="card-value ${cls}">${escapeHtml(value)}</div>
    </div>
  `;
}

const args = parseArgs(process.argv);
if (!args.summary || !args.out) {
  console.error("Usage: node generate-k6-summary-html.mjs --summary <summary.json> --out <report.html> [--title ...] [--scenario ...] [--base-url ...] [--notes ...]");
  process.exit(1);
}

const summaryPath = path.resolve(args.summary);
const outPath = path.resolve(args.out);
const summary = readJson(summaryPath);

const checks = metric(summary, "checks");
const httpFailed = metric(summary, "http_req_failed");
const errors = metric(summary, "errors");
const httpDuration = metric(summary, "http_req_duration");
const httpReqs = metric(summary, "http_reqs");
const iterations = metric(summary, "iterations");
const vusMax = metric(summary, "vus_max");
const wsConnectDuration = metric(summary, "ws_connect_duration");
const wsErrors = metric(summary, "ws_errors");
const wsConnectSuccess = metric(summary, "ws_connect_success");
const wsConnectFailed = metric(summary, "ws_connect_failed");
const wsMessageSent = metric(summary, "ws_message_sent");
const wsMessageReceived = metric(summary, "ws_message_received");

const title = args.title || "k6 Load Test Report";
const scenario = args.scenario || path.basename(summaryPath).replace(/_summary\.json$/, "");
const baseUrl = args["base-url"] || "-";
const notes = args.notes || "";

const html = `<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${escapeHtml(title)}</title>
  <style>
    * { box-sizing: border-box; }
    body { margin: 0; padding: 24px; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #0b1220; color: #dbe4ee; }
    .container { max-width: 1200px; margin: 0 auto; }
    h1 { margin: 0 0 8px; font-size: 28px; }
    .sub { color: #93a4b8; margin-bottom: 24px; }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; margin-bottom: 20px; }
    .card { background: #111a2b; border: 1px solid #25324a; border-radius: 8px; padding: 16px; }
    .card-title { color: #93a4b8; font-size: 13px; margin-bottom: 6px; }
    .card-value { font-size: 28px; font-weight: 700; }
    .pass { color: #4ade80; }
    .warn { color: #fbbf24; }
    .fail { color: #f87171; }
    .info { color: #60a5fa; }
    .section { background: #111a2b; border: 1px solid #25324a; border-radius: 8px; padding: 16px; margin-top: 16px; }
    h2 { margin: 0 0 12px; font-size: 18px; }
    table { width: 100%; border-collapse: collapse; }
    th, td { text-align: left; padding: 10px 8px; border-top: 1px solid #25324a; font-size: 14px; }
    th { color: #93a4b8; border-top: 0; }
    code { color: #c4b5fd; }
    pre { background: #0b1220; border: 1px solid #25324a; border-radius: 8px; padding: 12px; overflow: auto; white-space: pre-wrap; word-break: break-word; }
  </style>
</head>
<body>
  <div class="container">
    <h1>${escapeHtml(title)}</h1>
    <div class="sub">scenario=${escapeHtml(scenario)} | base_url=${escapeHtml(baseUrl)} | generated_at=${new Date().toISOString()}</div>

    <div class="grid">
      ${card("Checks", checks ? fmtPct(metricValues(checks).rate ?? metricValues(checks).value) : "-", checks && (metricValues(checks).rate ?? metricValues(checks).value) === 1 ? "pass" : "warn")}
      ${card("HTTP Failed", httpFailed ? fmtPct(metricValues(httpFailed).rate ?? metricValues(httpFailed).value) : "-", httpFailed && (metricValues(httpFailed).rate ?? metricValues(httpFailed).value) > 0.05 ? "fail" : "pass")}
      ${card("Errors", errors ? fmtPct(metricValues(errors).rate ?? metricValues(errors).value) : "-", errors && (metricValues(errors).rate ?? metricValues(errors).value) > 0.05 ? "fail" : "pass")}
      ${card("HTTP P95", httpDuration ? fmtMs(metricValues(httpDuration)["p(95)"]) : "-", "info")}
      ${card("HTTP P99", httpDuration ? fmtMs(metricValues(httpDuration)["p(99)"]) : "-", "info")}
      ${card("HTTP Req/s", httpReqs ? fmtNum(metricValues(httpReqs).rate) : "-", "info")}
      ${card("HTTP Reqs", httpReqs ? fmtNum(metricValues(httpReqs).count, 0) : "-", "info")}
      ${card("VUs Max", vusMax ? fmtNum(metricValues(vusMax).max ?? metricValues(vusMax).value, 0) : "-", "info")}
      ${card("Iterations", iterations ? fmtNum(metricValues(iterations).count, 0) : "-", "info")}
      ${card("WS Conn Success", wsConnectSuccess ? fmtNum(metricValues(wsConnectSuccess).count, 0) : "-", "info")}
      ${card("WS Conn Failed", wsConnectFailed ? fmtNum(metricValues(wsConnectFailed).count, 0) : "-", wsConnectFailed && (metricValues(wsConnectFailed).count ?? 0) > 0 ? "warn" : "pass")}
      ${card("WS Error Rate", wsErrors ? fmtPct(metricValues(wsErrors).rate ?? metricValues(wsErrors).value) : "-", wsErrors && (metricValues(wsErrors).rate ?? metricValues(wsErrors).value) > 0.1 ? "fail" : "pass")}
    </div>

    <div class="section">
      <h2>Key Metrics</h2>
      <table>
        <thead>
          <tr><th>Metric</th><th>Value</th></tr>
        </thead>
        <tbody>
          <tr><td>http_req_duration avg</td><td>${httpDuration ? fmtMs(metricValues(httpDuration).avg) : "-"}</td></tr>
          <tr><td>http_req_duration p90</td><td>${httpDuration ? fmtMs(metricValues(httpDuration)["p(90)"]) : "-"}</td></tr>
          <tr><td>http_req_duration p95</td><td>${httpDuration ? fmtMs(metricValues(httpDuration)["p(95)"]) : "-"}</td></tr>
          <tr><td>http_req_duration p99</td><td>${httpDuration ? fmtMs(metricValues(httpDuration)["p(99)"]) : "-"}</td></tr>
          <tr><td>http_req_duration max</td><td>${httpDuration ? fmtMs(metricValues(httpDuration).max) : "-"}</td></tr>
          <tr><td>http_req_failed rate</td><td>${httpFailed ? fmtPct(metricValues(httpFailed).rate ?? metricValues(httpFailed).value) : "-"}</td></tr>
          <tr><td>errors rate</td><td>${errors ? fmtPct(metricValues(errors).rate ?? metricValues(errors).value) : "-"}</td></tr>
          <tr><td>ws_connect_duration p95</td><td>${wsConnectDuration ? fmtMs(metricValues(wsConnectDuration)["p(95)"]) : "-"}</td></tr>
          <tr><td>ws_message_sent</td><td>${wsMessageSent ? fmtNum(metricValues(wsMessageSent).count, 0) : "-"}</td></tr>
          <tr><td>ws_message_received</td><td>${wsMessageReceived ? fmtNum(metricValues(wsMessageReceived).count, 0) : "-"}</td></tr>
        </tbody>
      </table>
    </div>

    <div class="section">
      <h2>Notes</h2>
      <pre>${escapeHtml(notes || "none")}</pre>
    </div>

    <div class="section">
      <h2>Summary JSON</h2>
      <pre>${escapeHtml(JSON.stringify(summary, null, 2))}</pre>
    </div>
  </div>
</body>
</html>`;

fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, html, "utf8");
