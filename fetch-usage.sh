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
#   {captured_at, claude: {captured_at, limits:[{label,pct,resets_at}],
#                          spend: {pct,used_minor,limit_minor,currency,exponent,
#                                  limit_reached}|null}|null,
#                 codex:  {captured_at, plan, limits:[...]}|null,
#                 claude_auth: "ok"|"expired"|"signed_out"}
#
# Args:
#   --notify | --no-notify   desktop alerts on a threshold crossing (default on)
#   --warn N   --crit N      crossing thresholds (default 70 and 90)
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
tab=$(printf '\t')

# Thresholds come from the widget rather than being declared twice; these are
# the fallbacks for a hand-run.
notify=1
warn_pct=70
crit_pct=90
while [ $# -gt 0 ]; do
  case "$1" in
    --notify) notify=1 ;;
    --no-notify) notify=0 ;;
    --warn) shift; warn_pct="${1:-$warn_pct}" ;;
    --crit) shift; crit_pct="${1:-$crit_pct}" ;;
  esac
  shift
done
case "$warn_pct" in ''|*[!0-9]*) warn_pct=70 ;; esac
case "$crit_pct" in ''|*[!0-9]*) crit_pct=90 ;; esac

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

# Claude Code's access token sits on disk with an expiry — eight hours, in
# practice — and only the CLI itself can renew it, from a refresh token this
# script deliberately leaves alone. So a lapsed token is not a failure to retry
# out of: it stays broken until a session runs, and the endpoint refuses it with
# the same 401 a signed-out machine would get. Telling those apart is the whole
# point, because "start Claude Code and it comes back" is the answer to one of
# them and not the other.
#
# The verdict rides beside the providers rather than inside claude's entry, so
# that entry keeps its single meaning — no live limits — in every failure case,
# and so a carried-forward entry can still say why the numbers stopped moving.
claude_auth=signed_out
claude_token=$(jq -r '.claudeAiOauth.accessToken // empty' "$claude_creds" 2>/dev/null)
if [ -n "$claude_token" ]; then
  claude_exp=$(jq -r '(.claudeAiOauth.expiresAt // 0) / 1000 | floor' "$claude_creds" 2>/dev/null)
  case "$claude_exp" in ''|*[!0-9]*) claude_exp=0 ;; esac
  # A missing expiresAt reads as 0, which is not an expiry in 1970 but an
  # unknown one; let the request itself settle those.
  if [ "$claude_exp" -gt 0 ] && [ "$claude_exp" -le "$now" ]; then
    claude_auth=expired
  else
    claude_auth=ok
  fi
fi

# Answers into claude_result, and may downgrade claude_auth. Called plainly
# rather than through a command substitution, so that downgrade outlives it.
claude_result=null
claude_usage() {
  claude_result=null
  [ "$claude_auth" = ok ] || return

  ver=$(claude_version)
  nl='
'
  body=$(curl -s -m 10 -w "$nl%{http_code}" \
    -H "Authorization: Bearer $claude_token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "User-Agent: claude-code/${ver:-2.1.0}" \
    https://api.anthropic.com/api/oauth/usage 2>/dev/null)
  status=${body##*"$nl"}
  body=${body%"$nl"*}

  # A token the server turns down is expired in the only sense that matters
  # here, whether or not its recorded expiry has come round: a revoked or
  # rotated one lands identically, and the same new session fixes all three.
  case "$status" in
    401|403) claude_auth=expired; return ;;
  esac

  # A usage response is an object with a five_hour block; error bodies are not.
  echo "$body" | jq -e 'type == "object" and has("five_hour")' >/dev/null 2>&1 || return

  claude_result=$(echo "$body" | jq -c --argjson now "$now" "$JQ_LIB"'
    def lim(b; n): if b == null then empty
                   else {label: n, pct: (b.utilization | floor), resets_at: epoch(b.resets_at)} end;

    # Overage credits, for accounts that have them switched on. Money is not a
    # rate-limit window — it has a cap and no reset this response knows about —
    # so it rides beside limits rather than inside them, and stays null when the
    # account has no credits enabled.
    #
    # Amounts are minor units (858 = $8.58) with their own exponent, because
    # that is how both blocks state them and a currency with no decimal place
    # would not survive the round trip through a float.
    def pct_of(used; limit): if limit == null or limit <= 0 then 0
                             else used * 100 / limit end;
    def spend_block:
      (.spend // {}) as $s | (.extra_usage // {}) as $x
      | if $s.enabled == true and $s.used.amount_minor != null then
          {pct: (($s.percent // pct_of($s.used.amount_minor; $s.limit.amount_minor)) | floor),
           used_minor: $s.used.amount_minor,
           limit_minor: ($s.limit.amount_minor // 0),
           currency: ($s.used.currency // "USD"),
           exponent: ($s.used.exponent // 2),
           limit_reached: (($x.spend_limit_reached // false)
                           or ($s.severity == "limit_reached"))}
        # The older block, and still the only one to name the cap as monthly.
        elif $x.is_enabled == true and $x.used_credits != null then
          {pct: (($x.utilization // pct_of($x.used_credits; $x.monthly_limit)) | floor),
           used_minor: ($x.used_credits | floor),
           limit_minor: ($x.monthly_limit // 0),
           currency: ($x.currency // "USD"),
           exponent: ($x.decimal_places // 2),
           limit_reached: ($x.spend_limit_reached // false)}
        else null end;

    {captured_at: $now,
     limits: [lim(.five_hour; "5-hour"), lim(.seven_day; "Weekly")],
     spend: spend_block}
  ' 2>/dev/null)
  [ -n "$claude_result" ] || claude_result=null
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

claude_usage;     c=$claude_result
x=$(codex_usage); [ -n "$x" ] || x=null

# Neither provider answered. Keep the previous snapshot — stale limits beat no
# limits — and hand the stale payload back so a caller reading stdout still has
# something to show. captured_at deliberately stays where it was, so the next
# run retries immediately instead of sitting out the min_age window.
#
# The auth verdict is the exception: it is fresh news about why Claude went
# quiet, it costs nothing to be wrong about later, and withholding it until some
# provider happens to answer would strand the reader on the stale-and-silent
# reading this whole field exists to replace. Stamp it on and keep the rest.
if [ "$c" = null ] && [ "$x" = null ]; then
  if [ -s "$cache" ]; then
    stamped=$(jq -c --arg auth "$claude_auth" '.claude_auth = $auth' "$cache" 2>/dev/null)
    if [ -n "$stamped" ]; then
      tmp="$cache.tmp.$$"
      printf '%s' "$stamped" > "$tmp" && mv -f "$tmp" "$cache"
      printf '%s' "$stamped"
    else
      cat "$cache"
    fi
  fi
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
  --arg auth "$claude_auth" \
  '{captured_at: $now, claude: $claude, codex: $codex, claude_auth: $auth}') || exit 1

countdown() {
  [ "${1:-0}" -gt 0 ] 2>/dev/null || return 0
  seconds=$(($1 - now))
  [ "$seconds" -gt 0 ] || { printf 'now'; return 0; }
  days=$((seconds / 86400))
  hours=$(((seconds % 86400) / 3600))
  minutes=$(((seconds % 3600) / 60))
  if [ "$days" -gt 0 ]; then printf '%dd %dh' "$days" "$hours"
  elif [ "$hours" -gt 0 ]; then printf '%dh %dm' "$hours" "$minutes"
  else printf '%dm' "$minutes"; fi
}

# Announce a bucket that has just crossed a threshold on the way up, and nothing
# else. A bucket with no previous reading — first run on this machine, or a
# provider that has only now started answering — seeds silently rather than
# announcing a number that may have been sitting there for days. A window that
# has rolled over drops to zero, which is not a crossing, so the alert re-arms
# for the next climb without anything having to remember it did. Crossing both
# thresholds between two polls reports the higher one only.
notify_crossings() {
  [ "$notify" -eq 1 ] || return 0
  command -v notify-send >/dev/null 2>&1 || return 0

  jq -rn --argjson before "$1" --argjson after "$2" \
         --argjson warn "$warn_pct" --argjson crit "$crit_pct" '
    def buckets($snap):
      [($snap.claude.limits // [])[]
       | {key: ("claude|" + .label), provider: "claude",
          name: ("Claude " + .label), pct: .pct, resets_at: .resets_at}]
      + [($snap.codex.limits // [])[]
         | {key: ("codex|" + .label), provider: "codex",
            name: ("Codex " + .label), pct: .pct, resets_at: .resets_at}]
      # Credits have a cap and no reset, so they cross once and stay crossed
      # until the account tops up — which is the whole point of saying so.
      + (if $snap.claude.spend == null then []
         else [{key: "claude|credits", provider: "claude",
                name: "Claude credits", pct: $snap.claude.spend.pct,
                resets_at: null}] end);

    (buckets($before) | INDEX(.key)) as $was
    | buckets($after)[]
    | . as $now
    | ($was[$now.key] // null) as $then
    | select($then != null)
    | ([$crit, $warn] | map(select($then.pct < . and $now.pct >= .)) | first) as $level
    | select($level != null)
    | [$level, $now.provider, $now.name, $now.pct, ($now.resets_at // 0)] | @tsv
  ' 2>/dev/null | while IFS="$tab" read -r level provider name pct reset; do
    [ -n "$name" ] || continue
    urgency=normal
    [ "$level" = "$crit_pct" ] && urgency=critical
    summary="$name at ${pct}% used"
    body=$(when=$(countdown "$reset"); [ -n "$when" ] && printf 'Resets in %s' "$when")
    icon="$script_dir/assets/$provider.svg"
    if [ -f "$icon" ]; then
      notify-send -a "AI Usage" -u "$urgency" -i "$icon" "$summary" "$body" 2>/dev/null
    else
      notify-send -a "AI Usage" -u "$urgency" "$summary" "$body" 2>/dev/null
    fi
  done
  return 0
}

# The cache write and the comparison that drives alerts belong together, because
# the comparison is against whatever is on disk at that moment. Two bars on two
# screens fetch independently and can land on the same crossing: under this lock
# whoever writes first alerts, and the other reads back the snapshot just
# written, finds nothing crossed, and stays quiet.
lock="$cache.notify.lock"
# A run killed between mkdir and rmdir would otherwise silence alerts for good,
# so a lock nothing has touched for a minute counts as abandoned.
if [ -d "$lock" ] && [ -z "$(find "$lock" -maxdepth 0 -mmin -1 2>/dev/null)" ]; then
  rmdir "$lock" 2>/dev/null
fi

tmp="$cache.tmp.$$"
if mkdir "$lock" 2>/dev/null; then
  before=$(jq -c . "$cache" 2>/dev/null) || before=null
  [ -n "$before" ] || before=null
  printf '%s' "$out" > "$tmp" && mv -f "$tmp" "$cache"
  notify_crossings "$before" "$out"
  rmdir "$lock" 2>/dev/null
else
  printf '%s' "$out" > "$tmp" && mv -f "$tmp" "$cache"
fi

printf '%s' "$out"
exit 0
