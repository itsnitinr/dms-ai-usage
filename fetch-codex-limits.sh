#!/usr/bin/env bash
# Fetch one live ChatGPT rate-limit snapshot from the local Codex app-server.
# Prints the account/rateLimits/read JSON-RPC response and nothing else.
set -u

codex_cmd="${CODEX_CMD:-codex}"
timeout_seconds="${CODEX_TIMEOUT:-12}"

command -v "$codex_cmd" >/dev/null 2>&1 || exit 1
case "$timeout_seconds" in
  ''|*[!0-9]*) exit 1 ;;
esac
[ "$timeout_seconds" -gt 0 ] || exit 1

coproc CODEX_RPC { "$codex_cmd" app-server 2>/dev/null; }
rpc_pid=$CODEX_RPC_PID
rpc_out=${CODEX_RPC[0]}
rpc_in=${CODEX_RPC[1]}

cleanup() {
  exec {rpc_in}>&- 2>/dev/null || true
  exec {rpc_out}<&- 2>/dev/null || true
  kill "$rpc_pid" 2>/dev/null || true
  wait "$rpc_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

printf '%s\n' \
  '{"method":"initialize","id":0,"params":{"clientInfo":{"name":"dms_ai_usage","title":"DMS AI Usage","version":"0.1.1"}}}' \
  '{"method":"initialized","params":{}}' \
  '{"method":"account/rateLimits/read","id":1}' \
  >&"$rpc_in"

started_at=$SECONDS
while (( SECONDS - started_at < timeout_seconds )); do
  remaining=$((timeout_seconds - (SECONDS - started_at)))
  if ! IFS= read -r -t "$remaining" -u "$rpc_out" line; then
    exit 1
  fi

  response=$(printf '%s\n' "$line" \
    | jq -ce 'select(.id == 1 and .result.rateLimits != null)' 2>/dev/null) || continue
  printf '%s\n' "$response"
  exit 0
done

exit 1
