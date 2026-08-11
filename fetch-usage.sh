#!/bin/sh
# Collect Claude Code and Codex usage limits, normalize them into one JSON blob,
# write it to the cache, and print it.
#
# Claude: reads the OAuth access token Claude Code already keeps on disk and asks
# the same usage endpoint the client itself uses. Live, always current.
#
# Codex: the CLI does not expose a usage endpoint; it records a rate-limit
# snapshot into its session rollout log on every turn. We read the newest such
# snapshot, so the numbers are as fresh as your last Codex turn (the payload
# carries absolute reset times, so a stale snapshot is still directionally right
# until its window rolls over).
#
# Output:
#   {captured_at, claude: {captured_at, limits:[{label,pct,resets_at}]}|null,
#                 codex:  {captured_at, plan, limits:[...]}|null}
#
# Env:
#   CACHE_FILE      cache path (default $XDG_CACHE_HOME/dms-ai-usage.json)
#   CLAUDE_CREDS    Claude Code credentials (default ~/.claude/.credentials.json)
#   CODEX_HOME      Codex state dir (default ~/.codex)
#   MIN_AGE         seconds before a cached result is refetched (default 150)
#
# Exit: 0 if at least one provider reported, 1 if neither did.
set -u

cache="${CACHE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/dms-ai-usage.json}"
codex_home="${CODEX_HOME:-$HOME/.codex}"
claude_creds="${CLAUDE_CREDS:-$HOME/.claude/.credentials.json}"
min_age="${MIN_AGE:-150}"
now=$(date +%s)

mkdir -p "$(dirname "$cache")" 2>/dev/null

# Shared jq helpers: ISO-8601 (with optional fraction/zone) -> epoch seconds.
JQ_LIB='
def epoch(s):
  s | sub("\\.[0-9]+"; "") | sub("(Z|[+-][0-9]{2}:?[0-9]{2})$"; "")
    | strptime("%Y-%m-%dT%H:%M:%S") | mktime;
'

# Several bars/monitors can run this at once; serve a recent cache instead of
# re-hitting the network.
if [ -s "$cache" ]; then
  prev=$(jq -r '.captured_at // 0' "$cache" 2>/dev/null)
  case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
  if [ "$prev" -gt 0 ] && [ $((now - prev)) -lt "$min_age" ]; then
    cat "$cache"
    exit 0
  fi
fi

claude_usage() {
  [ -f "$claude_creds" ] || { echo null; return; }
  tok=$(jq -r '.claudeAiOauth.accessToken // empty' "$claude_creds" 2>/dev/null)
  [ -n "$tok" ] || { echo null; return; }

  ver=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  body=$(curl -s -m 10 \
    -H "Authorization: Bearer $tok" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "User-Agent: claude-code/${ver:-2.1.0}" \
    https://api.anthropic.com/api/oauth/usage 2>/dev/null)

  # A usage response is an object with a five_hour block; error bodies are not.
  echo "$body" | jq -e 'type == "object" and has("five_hour")' >/dev/null 2>&1 || { echo null; return; }

  echo "$body" | jq --argjson now "$now" "$JQ_LIB"'
    def lim(b; n): if b == null then empty
                   else {label: n, pct: (b.utilization | floor), resets_at: epoch(b.resets_at)} end;
    {captured_at: $now,
     limits: [lim(.five_hour; "5-hour"), lim(.seven_day; "Weekly")]}
  ' 2>/dev/null || echo null
}

codex_usage() {
  dir="$codex_home/sessions"
  [ -d "$dir" ] || { echo null; return; }

  # Newest rollout first; stop at the first one carrying a rate-limit snapshot.
  line=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    l=$(grep -a '"rate_limits"' "$f" 2>/dev/null | tail -1)
    if [ -n "$l" ]; then line=$l; break; fi
  done <<EOF
$(find "$dir" -name 'rollout-*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
  | sort -rn | head -20 | cut -d' ' -f2-)
EOF
  [ -n "$line" ] || { echo null; return; }

  # window_minutes names the limit; resets_at is absolute in newer Codex builds,
  # older ones only give resets_in_seconds relative to the snapshot.
  echo "$line" | jq "$JQ_LIB"'
    def win(m): if m == null then "Limit"
                elif m >= 10080 then "Weekly"
                elif m >= 1440 then ((m / 1440 | floor | tostring) + "-day")
                elif m >= 60 then ((m / 60 | floor | tostring) + "-hour")
                else ((m | tostring) + "-min") end;
    def lim(b; ts): if b == null then empty
                    else {label: win(b.window_minutes),
                          pct: (b.used_percent | floor),
                          resets_at: (b.resets_at // (ts + (b.resets_in_seconds // 0)))} end;
    epoch(.timestamp) as $ts
    | .payload.rate_limits
    | select(. != null)
    | {captured_at: $ts,
       plan: (.plan_type // null),
       limits: [lim(.primary; $ts), lim(.secondary; $ts)]}
  ' 2>/dev/null || echo null
}

c=$(claude_usage); [ -n "$c" ] || c=null
x=$(codex_usage);  [ -n "$x" ] || x=null

out=$(jq -n --argjson now "$now" --argjson claude "$c" --argjson codex "$x" \
  '{captured_at: $now, claude: $claude, codex: $codex}') || exit 1

tmp="$cache.tmp.$$"
printf '%s' "$out" > "$tmp" && mv -f "$tmp" "$cache"
printf '%s' "$out"

[ "$c" = null ] && [ "$x" = null ] && exit 1
exit 0
