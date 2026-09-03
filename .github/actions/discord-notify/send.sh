#!/usr/bin/env bash

set -uo pipefail

if [[ -z "${INPUT_WEBHOOK_URL}" ]]; then
  echo "::notice::DISCORD_WEBHOOK_URL is not configured; skipping notification."
  exit 0
fi

if [[ -z "$INPUT_CONTENT" && -z "$INPUT_TITLE" && -z "$INPUT_DESCRIPTION" && "${INPUT_SHOW_CONTEXT,,}" != "true" ]]; then
  echo "::warning::Discord notification has no content; skipping delivery."
  exit 0
fi

case "${INPUT_STATUS,,}" in
  success)
    default_color="3066993"
    ;;
  failure|failed|cancelled)
    default_color="15158528"
    ;;
  warning)
    default_color="15105570"
    ;;
  *)
    default_color="5793266"
    ;;
esac

color="${INPUT_COLOR:-$default_color}"
run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
embed_url="${INPUT_URL:-$run_url}"
branch="${INPUT_BRANCH:-$GITHUB_REF_NAME}"
short_sha="${GITHUB_SHA:0:7}"
commit_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA}"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if ! [[ "$color" =~ ^[0-9]+$ ]]; then
  echo "::warning::Discord notification color must be a decimal integer; using the status color."
  color="$default_color"
fi

payload="$(
  jq -n \
    --arg content "$INPUT_CONTENT" \
    --arg title "$INPUT_TITLE" \
    --arg description "$INPUT_DESCRIPTION" \
    --arg url "$embed_url" \
    --argjson color "$color" \
    --arg show_context "${INPUT_SHOW_CONTEXT,,}" \
    --arg repository "$GITHUB_REPOSITORY" \
    --arg branch "$branch" \
    --arg short_sha "$short_sha" \
    --arg commit_url "$commit_url" \
    --arg commit_message "$INPUT_COMMIT_MESSAGE" \
    --arg commit_author "$INPUT_COMMIT_AUTHOR" \
    --arg image_tag "$INPUT_IMAGE_TAG" \
    --arg message_label "$INPUT_MESSAGE_LABEL" \
    --arg run_url "$run_url" \
    --arg timestamp "$timestamp" '
      def truncated($max):
        if length > $max then .[0:($max - 1)] + "…" else . end;

      [
        if $show_context == "true" then
          {name: "📦 저장소", value: ("`" + ($repository | truncated(1000)) + "`"), inline: true},
          {name: "🌿 브랜치", value: ("`" + ($branch | truncated(1000)) + "`"), inline: true},
          {name: "🔖 커밋", value: ("[`" + $short_sha + "`](" + $commit_url + ")"), inline: true},
          if $commit_message != "" then
            {name: ($message_label | truncated(256)), value: ($commit_message | truncated(1024)), inline: false}
          else empty end,
          if $image_tag != "" then
            {name: "🏷 이미지 태그", value: ("`" + ($image_tag | truncated(1000)) + "`"), inline: true}
          else empty end,
          if $commit_author != "" then
            {name: "👤 작성자", value: ($commit_author | truncated(1024)), inline: true}
          else empty end,
          {name: "📋 상세 로그", value: ("[Actions에서 확인](" + $run_url + ")"), inline: true}
        else empty end
      ] as $fields
      | {}
      + (if $content != "" then {content: ($content | truncated(2000))} else {} end)
      + (if ($title != "" or $description != "" or ($fields | length) > 0) then
          {embeds: [
            {}
            + (if $title != "" then {title: ($title | truncated(256))} else {} end)
            + (if $description != "" then {description: ($description | truncated(4096))} else {} end)
            + (if $url != "" then {url: $url} else {} end)
            + {color: $color, timestamp: $timestamp}
            + (if ($fields | length) > 0 then {fields: $fields} else {} end)
          ]}
        else {} end)
      + {allowed_mentions: {parse: ["users"]}}
    '
)"

if ! curl --fail-with-body --silent --show-error \
  --retry 2 --retry-delay 1 --max-time 15 \
  -H "Content-Type: application/json" \
  -X POST \
  -d "$payload" \
  "$INPUT_WEBHOOK_URL" >/dev/null; then
  echo "::warning::Discord notification delivery failed."
  if [[ "${INPUT_FAIL_ON_ERROR,,}" == "true" ]]; then
    exit 1
  fi
fi
