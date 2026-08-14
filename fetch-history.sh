#!/bin/sh
# Build one provider's local token analytics in a single pass over recent session
# logs. The provider is required: `fetch-history.sh codex|claude`.
#
# Output:
#   {captured_at, provider, token_basis,
#    hourly:[{start,tokens}], daily:[{start,tokens}],
#    models:[{model,tokens}]}
#
# Hourly contains the current local hour plus the previous 23. Daily contains
# seven local calendar days including today. Models cover the same seven-day
# calendar window. Token totals include cached input so every view uses the same
# familiar "tokens processed" measure shown by local usage tools.
#
# Env:
#   HISTORY_FILE  cache path (default $XDG_CACHE_HOME/dms-ai-usage-PROVIDER-history.json)
#   CLAUDE_LOGS   Claude project logs (default ~/.claude/projects)
#   CODEX_LOGS    Codex session logs (default ~/.codex/sessions)
#   MIN_AGE       seconds before a cached result is rebuilt (default 150)
set -u

provider="${1:-}"
case "$provider" in
  claude|codex) ;;
  *) exit 1 ;;
esac

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}"
cache="${HISTORY_FILE:-$cache_dir/dms-ai-usage-$provider-history.json}"
claude_logs="${CLAUDE_LOGS:-$HOME/.claude/projects}"
codex_logs="${CODEX_LOGS:-$HOME/.codex/sessions}"
min_age="${MIN_AGE:-150}"

case "$min_age" in ''|*[!0-9]*) min_age=150 ;; esac
command -v jq >/dev/null 2>&1 || exit 1

now=$(date +%s)
mkdir -p "$(dirname "$cache")" 2>/dev/null || exit 1

# Multiple widget instances share one provider cache.
if [ -s "$cache" ]; then
  cache_meta=$(jq -r '[.provider // "", .captured_at // 0] | @tsv' "$cache" 2>/dev/null)
  cached_provider=$(printf '%s' "$cache_meta" | cut -f1)
  captured=$(printf '%s' "$cache_meta" | cut -f2)
  case "$captured" in ''|*[!0-9]*) captured=0 ;; esac
  if [ "$cached_provider" = "$provider" ] && [ "$captured" -gt 0 ] \
     && [ $((now - captured)) -lt "$min_age" ]; then
    cat "$cache"
    exit 0
  fi
fi

# GNU date gives true local calendar boundaries, including DST transitions.
current_hour=$(date -d "$(date '+%Y-%m-%d %H:00:00')" +%s 2>/dev/null) || exit 1
oldest_hour=$((current_hour - 23 * 3600))
day_starts=$(
  i=6
  while [ "$i" -ge 0 ]; do
    date -d "$i days ago 00:00:00" +%s || exit 1
    i=$((i - 1))
  done | jq -Rsc '[split("\n")[] | select(length > 0) | tonumber]'
) || exit 1
oldest_day=$(printf '%s' "$day_starts" | jq -r '.[0] // 0')
[ "$oldest_day" -gt 0 ] || exit 1

# File mtime is only a prefilter; every event timestamp is checked below.
ref="$cache.ref.$$"
: > "$ref" 2>/dev/null || exit 1
touch -d "@$oldest_day" "$ref" 2>/dev/null || { rm -f "$ref"; exit 1; }

recent_logs() {
  [ -d "$1" ] || return 0
  find "$1" -name '*.jsonl' -newer "$ref" -print0 2>/dev/null
}

JQ_LIB='
def epoch(s):
  s | sub("\\.[0-9]+"; "") | sub("(Z|[+-][0-9]{2}:?[0-9]{2})$"; "")
    | strptime("%Y-%m-%dT%H:%M:%S") | mktime;
def token(n): if n == null or n < 0 then 0 else n end;
'

TAB=$(printf '\t')

claude_rows() {
  recent_logs "$claude_logs" | xargs -0 -r jq -rc "$JQ_LIB"'
    select(.message.usage != null and .message.id != null and .timestamp != null)
    | .message.usage as $u
    | [(.message.id + "|" + (.requestId // "")),
       epoch(.timestamp),
       (token($u.input_tokens) + token($u.output_tokens)
        + token($u.cache_creation_input_tokens) + token($u.cache_read_input_tokens)),
       (.message.model // "Unknown")]
    | @tsv
  ' 2>/dev/null \
  | sort -t"$TAB" -k1,1 -k2,2n \
  | awk -F"$TAB" '!seen[$1]++ { print $2 "\t" $3 "\t" $4 }'
}

codex_rows() {
  # last_token_usage is the per-request delta. The most recent turn_context is
  # the recorded model for subsequent usage events in that session.
  recent_logs "$codex_logs" | xargs -0 -r jq -nrc "$JQ_LIB"'
    foreach inputs as $row (
      {model: "Unknown"};
      if $row.type == "turn_context" then
        .model = ($row.payload.model // "Unknown")
      else . end;
      if ($row.payload.type == "token_count"
          and $row.payload.info.last_token_usage != null
          and $row.timestamp != null) then
        $row.payload.info.last_token_usage as $u
        | [epoch($row.timestamp), token($u.total_tokens), .model] | @tsv
      else empty end
    )
  ' 2>/dev/null
}

case "$provider" in
  claude) rows=$(claude_rows) ;;
  codex) rows=$(codex_rows) ;;
esac
rm -f "$ref"

out=$(printf '%s\n' "$rows" | jq -R -s \
  --arg provider "$provider" \
  --argjson now "$now" \
  --argjson currentHour "$current_hour" \
  --argjson oldestHour "$oldest_hour" \
  --argjson dayStarts "$day_starts" '
  [split("\n")[] | select(length > 0) | split("\t")
   | {ts: (.[0] | tonumber), tokens: (.[1] | tonumber), model: .[2]}
   | select(.tokens > 0)] as $events
  | {
      captured_at: $now,
      provider: $provider,
      token_basis: "total",
      hourly: [range(0; 24) as $i
        | ($oldestHour + $i * 3600) as $start
        | {start: $start,
           tokens: ([$events[] | select(.ts >= $start and .ts < ($start + 3600))
                    | .tokens] | add // 0)}],
      daily: [range(0; ($dayStarts | length)) as $i
        | $dayStarts[$i] as $start
        | (if $i + 1 < ($dayStarts | length)
           then $dayStarts[$i + 1] else $now + 1 end) as $end
        | {start: $start,
           tokens: ([$events[] | select(.ts >= $start and .ts < $end)
                    | .tokens] | add // 0)}],
      models: ([$events[] | select(.ts >= $dayStarts[0] and .ts <= $now)]
        | sort_by(.model) | group_by(.model)
        | map({model: .[0].model, tokens: (map(.tokens) | add // 0)})
        | sort_by(-.tokens))
    }
') || exit 1
[ -n "$out" ] || exit 1

tmp="$cache.tmp.$$"
printf '%s' "$out" > "$tmp" && mv -f "$tmp" "$cache" || exit 1
printf '%s' "$out"
exit 0
