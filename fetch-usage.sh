#!/bin/sh
# Collect Claude Code and Codex usage limits, normalize them into one JSON blob,
# write it to the cache, and print it.
#
# Claude: reads the OAuth access token Claude Code already keeps on disk and asks
# the same usage endpoint the client itself uses. That endpoint allows only about
# two requests per five minutes, and Claude Code itself spends from the same
# budget, so a poll landing on a 429 is routine rather than exceptional.
#
# Codex: asks the local Codex app-server for the account's current ChatGPT
# rate-limit buckets. This is live and does not inspect session rollout logs.
#
# Output:
#   {captured_at, claude: {captured_at, limits:[{label,pct,resets_at}]}|null,
#                 codex:  {captured_at, plan, limits:[...]}|null}
#
# Env:
#   CACHE_FILE      cache path (default $XDG_CACHE_HOME/dms-ai-usage.json)
#   CLAUDE_CREDS    Claude Code credentials (default ~/.claude/.credentials.json)
#   CODEX_CMD       Codex executable (default codex)
#   CODEX_TIMEOUT   app-server response timeout in seconds (default 12)
#   MIN_AGE         seconds before a cached result is refetched (default 150)
#   MAX_STALE       seconds a failed provider keeps its previous entry (default 3600)
#
# Exit: 0 if at least one provider reported, 1 if neither did. A run where
#       neither reported leaves the cache untouched, so a transient failure —
#       no network yet after a resume from sleep, say — does not erase the last
#       good snapshot out from under whatever is displaying it. The same holds
#       one provider at a time: a provider that failed keeps its previous entry,
#       stale captured_at and all, rather than being written down as null.
set -u

cache="${CACHE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/dms-ai-usage.json}"
claude_creds="${CLAUDE_CREDS:-$HOME/.claude/.credentials.json}"
min_age="${MIN_AGE:-150}"
max_stale="${MAX_STALE:-3600}"
now=$(date +%s)
script_dir=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)

mkdir -p "$(dirname "$cache")" 2>/dev/null

version_cache="${cache%/*}/dms-ai-usage-claude-version"

# `claude --version` starts the whole CLI — ~250 MB resident for a tenth of a
# second — and this script runs every five minutes, so the answer is cached and
# recomputed only when the binary itself changes. Size and mtime of the resolved
# executable are enough to catch an upgrade.
claude_version() {
  bin=$(command -v claude 2>/dev/null) || return
  [ -n "$bin" ] || return

  stamp=$(stat -Lc '%s-%Y' "$bin" 2>/dev/null)
  if [ -n "$stamp" ] && [ -s "$version_cache" ]; then
    IFS='|' read -r cached_stamp cached_ver < "$version_cache" 2>/dev/null
    if [ "$cached_stamp" = "$stamp" ] && [ -n "$cached_ver" ]; then
      printf '%s' "$cached_ver"
      return
    fi
  fi

  ver=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  [ -n "$ver" ] || return
  if [ -n "$stamp" ]; then
    tmp_ver="$version_cache.tmp.$$"
    printf '%s|%s\n' "$stamp" "$ver" > "$tmp_ver" 2>/dev/null \
      && mv -f "$tmp_ver" "$version_cache" 2>/dev/null
  fi
  printf '%s' "$ver"
}

# Shared jq helpers: ISO-8601 (with optional fraction/zone) -> epoch seconds.
# A bucket whose window has not started yet reports resets_at: null, so null
# passes straight through rather than aborting the whole conversion.
JQ_LIB='
def epoch(s):
  if s == null then null
  else s | sub("\\.[0-9]+"; "") | sub("(Z|[+-][0-9]{2}:?[0-9]{2})$"; "")
         | strptime("%Y-%m-%dT%H:%M:%S") | mktime end;
'

# Several bars/monitors can run this at once; serve a recent cache instead of
# re-hitting the network.
if [ -s "$cache" ]; then
  prev=$(jq -r '.captured_at // 0' "$cache" 2>/dev/null)
  case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
  if [ "$prev" -gt 0 ] && [ $((now - prev)) -lt "$min_age" ]; then
    cat "$cache"
    # A snapshot with no providers in it is a cached *failure*. Still serve it
    # rather than re-hitting the network, but report it as one: exiting 0 here
    # would tell the caller the fetch succeeded and simply found nothing.
    jq -e '.claude != null or .codex != null' "$cache" >/dev/null 2>&1 || exit 1
    exit 0
  fi
fi

claude_usage() {
  [ -f "$claude_creds" ] || { echo null; return; }
  tok=$(jq -r '.claudeAiOauth.accessToken // empty' "$claude_creds" 2>/dev/null)
  [ -n "$tok" ] || { echo null; return; }

  ver=$(claude_version)
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
  command -v bash >/dev/null 2>&1 || { echo null; return; }
  [ -n "$script_dir" ] || { echo null; return; }

  response=$(bash "$script_dir/fetch-codex-limits.sh" 2>/dev/null) || { echo null; return; }
  [ -n "$response" ] || { echo null; return; }

  echo "$response" | jq --argjson now "$now" '
    def win(m): if m == null then "Limit"
                elif m >= 10080 then "Weekly"
                elif m >= 1440 then ((m / 1440 | floor | tostring) + "-day")
                elif m >= 60 then ((m / 60 | floor | tostring) + "-hour")
                else ((m | tostring) + "-min") end;
    def limit_label(n; m): win(m) as $window
      | if n == null or n == "" or n == "codex" then $window
        else (n + " · " + $window) end;
    def lim(b; n): if b == null then empty
                   else {label: limit_label(n; b.windowDurationMins),
                         pct: (b.usedPercent | floor),
                         resets_at: b.resetsAt} end;
    .result as $result
    | (if (($result.rateLimitsByLimitId // {}) | length) > 0
       then [$result.rateLimitsByLimitId[]]
       elif $result.rateLimits != null then [$result.rateLimits]
       else [] end) as $buckets
    | {captured_at: $now,
       plan: ($result.rateLimits.planType
              // ($buckets | map(.planType) | map(select(. != null)) | first)
              // null),
       limits: [$buckets[]
                | . as $bucket
                | lim($bucket.primary; $bucket.limitName),
                  lim($bucket.secondary; $bucket.limitName)]}
    | select(.limits | length > 0)
  ' 2>/dev/null || echo null
}

c=$(claude_usage); [ -n "$c" ] || c=null
x=$(codex_usage);  [ -n "$x" ] || x=null

# Neither provider answered. Keep the previous snapshot — stale limits beat no
# limits — and hand the stale payload back so a caller reading stdout still has
# something to show. captured_at deliberately stays where it was, so the next
# run retries immediately instead of sitting out the min_age window.
if [ "$c" = null ] && [ "$x" = null ]; then
  [ -s "$cache" ] && cat "$cache"
  exit 1
fi

# One provider answered and the other did not, which is the common case rather
# than a rare one: Codex is served by a local app-server and effectively always
# answers, while Claude's endpoint hands back a 429 whenever a Claude Code
# session has recently spent the shared budget. Carrying the last good entry
# forward per provider keeps that routine 429 from blanking Claude out of a
# snapshot Codex is keeping alive — which reads, wrongly, as Claude not being
# installed. The carried entry keeps its own older captured_at so a reader can
# still tell it apart from a fresh one.
#
# Carrying forward stops at max_stale. Rate-limit windows are minutes long, so a
# provider silent for an hour is not being throttled — it is signed out or gone,
# and hour-old percentages would be a worse answer than admitting there are
# none. This is what lets the empty state eventually appear again.
prev_entry() {
  [ -s "$cache" ] || { echo null; return; }
  jq -c --arg key "$1" --argjson now "$now" --argjson max "$max_stale" \
    '.[$key] // null | select(. != null and $now - (.captured_at // 0) <= $max) // null' \
    "$cache" 2>/dev/null || echo null
}

if [ "$c" = null ]; then c=$(prev_entry claude); [ -n "$c" ] || c=null; fi
if [ "$x" = null ]; then x=$(prev_entry codex);  [ -n "$x" ] || x=null; fi

out=$(jq -n --argjson now "$now" --argjson claude "$c" --argjson codex "$x" \
  '{captured_at: $now, claude: $claude, codex: $codex}') || exit 1

tmp="$cache.tmp.$$"
printf '%s' "$out" > "$tmp" && mv -f "$tmp" "$cache"
printf '%s' "$out"
exit 0
