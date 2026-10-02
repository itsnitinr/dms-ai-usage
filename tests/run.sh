#!/bin/sh
# Fixture tests for the three fetch scripts.
#
#   sh tests/run.sh                  everything
#   sh tests/run.sh usage notify     named sections only
#
# Sections: usage, notify, codex, history.
#
# Needs sh and jq and nothing else — no network, no Claude or Codex install, no
# notification daemon, no shell running. Recorded responses come in through the
# test seams documented at the top of fetch-usage.sh, and notify-send is a stub
# on PATH that writes its arguments to a file.
#
# Session-log fixtures are generated rather than stored, because every window
# these scripts compute is relative to now: a file with last Tuesday's
# timestamps in it stops meaning what it meant by Thursday.
set -u

here=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
root=$(dirname "$here")
fixtures="$here/fixtures"
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT INT TERM

now=$(date +%s)
passed=0
failed=0

ok() {
    passed=$((passed + 1))
    printf '  ok    %s\n' "$1"
}

bad() {
    failed=$((failed + 1))
    printf '  FAIL  %s\n' "$1"
    [ $# -gt 1 ] && printf '        %s\n' "$2"
    return 0
}

# is LABEL EXPECTED ACTUAL
is() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}

# has LABEL NEEDLE HAYSTACK
has() {
    case "$3" in
        *"$2"*) ok "$1" ;;
        *) bad "$1" "[$2] missing from [$3]" ;;
    esac
}

# lacks LABEL NEEDLE HAYSTACK
lacks() {
    case "$3" in
        *"$2"*) bad "$1" "[$2] unexpectedly present in [$3]" ;;
        *) ok "$1" ;;
    esac
}

section() {
    printf '\n%s\n' "$1"
}

iso() {
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z
}

# ---------------------------------------------------------------------------
# Shared fixtures
# ---------------------------------------------------------------------------

mkdir -p "$work/bin"
cat > "$work/bin/notify-send" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$NOTIFY_LOG"
STUB
chmod +x "$work/bin/notify-send"

# Far-future expiry: the auth verdict under test is the one the request itself
# produces, not the clock.
printf '{"claudeAiOauth":{"accessToken":"test-token","expiresAt":%s}}\n' \
    "$(( (now + 86400) * 1000 ))" > "$work/creds-ok.json"
printf '{"claudeAiOauth":{"accessToken":"test-token","expiresAt":%s}}\n' \
    "$(( (now - 3600) * 1000 ))" > "$work/creds-expired.json"

# An installed, signed-in Codex would otherwise answer for real the moment a
# test left CODEX_LIMITS_FILE unset, and the suite would pass or fail on a
# stranger's rate limits. Every run points at this instead: a path that is not
# there, which is how a test says "no Codex".
silent_codex="$work/no-such-codex.json"

# usage [--status N] [--body FILE] [--cache FILE] [-- ARGS...]
# Runs fetch-usage.sh with Claude answering from a fixture and Codex silent,
# and prints the resulting snapshot. Each call gets its own cache unless one is
# named, so a carried-forward entry can never wander between tests. mktemp
# rather than a counter: almost every call here is a command substitution, and
# a counter incremented in a subshell goes nowhere.
usage() {
    body="$fixtures/claude-usage.json"
    creds="$work/creds-ok.json"
    cache=$(mktemp "$work/cache-XXXXXX")
    status=200
    codex_file="$silent_codex"
    while [ $# -gt 0 ]; do
        case "$1" in
            --body) shift; body=$1 ;;
            --creds) shift; creds=$1 ;;
            --cache) shift; cache=$1 ;;
            --status) shift; status=$1 ;;
            --codex) shift; codex_file=$1 ;;
            --) shift; break ;;
        esac
        shift
    done

    CLAUDE_USAGE_BODY="$body" \
    CLAUDE_USAGE_STATUS="$status" \
    CLAUDE_CREDS="$creds" \
    CODEX_LIMITS_FILE="$codex_file" \
    CACHE_FILE="$cache" \
    MIN_AGE=0 \
        sh "$root/fetch-usage.sh" --no-notify "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
# usage — snapshot shape, credits, auth, carry-forward
# ---------------------------------------------------------------------------

test_usage() {
    section "fetch-usage.sh"

    out=$(usage)
    is "two Claude windows" "5-hour Weekly" \
        "$(printf '%s' "$out" | jq -r '[.claude.limits[].label] | join(" ")')"
    is "utilization floors rather than rounds" "71" \
        "$(printf '%s' "$out" | jq -r '.claude.limits[0].pct')"
    is "reset time converts to epoch" "1893499200" \
        "$(printf '%s' "$out" | jq -r '.claude.limits[0].resets_at')"
    is "auth ok" "ok" "$(printf '%s' "$out" | jq -r '.claude_auth')"

    # Credits: the spend block, the extra_usage fallback, and every reason to
    # report nothing at all.
    is "spend block read" "43 858 2000 USD 2 false" \
        "$(printf '%s' "$out" | jq -r '.claude.spend
            | [.pct, .used_minor, .limit_minor, .currency, .exponent, .limit_reached]
            | join(" ")')"

    jq 'del(.spend)' "$fixtures/claude-usage.json" > "$work/no-spend-block.json"
    is "extra_usage stands in for a missing spend block" "42 858 2000" \
        "$(usage --body "$work/no-spend-block.json" | jq -r '.claude.spend
            | [.pct, .used_minor, .limit_minor] | join(" ")')"

    jq 'del(.spend, .extra_usage)' "$fixtures/claude-usage.json" > "$work/no-credits.json"
    is "no credit blocks at all reports null" "null" \
        "$(usage --body "$work/no-credits.json" | jq -r '.claude.spend')"

    jq '.spend.enabled = false | .extra_usage.is_enabled = false' \
        "$fixtures/claude-usage.json" > "$work/credits-off.json"
    is "credits switched off reports null" "null" \
        "$(usage --body "$work/credits-off.json" | jq -r '.claude.spend')"

    jq '.spend.limit = null | .spend.percent = null' \
        "$fixtures/claude-usage.json" > "$work/uncapped.json"
    is "an uncapped balance keeps the amount and drops the fraction" "0 858 0" \
        "$(usage --body "$work/uncapped.json" | jq -r '.claude.spend
            | [.pct, .used_minor, .limit_minor] | join(" ")')"

    jq '.spend.severity = "limit_reached"' "$fixtures/claude-usage.json" \
        > "$work/reached-severity.json"
    is "limit_reached from severity" "true" \
        "$(usage --body "$work/reached-severity.json" | jq -r '.claude.spend.limit_reached')"

    jq '.extra_usage.spend_limit_reached = true' "$fixtures/claude-usage.json" \
        > "$work/reached-flag.json"
    is "limit_reached from extra_usage" "true" \
        "$(usage --body "$work/reached-flag.json" | jq -r '.claude.spend.limit_reached')"

    # A currency with no decimal place must keep its own exponent, or the QML
    # formats 430 yen as ¥4.30.
    jq '.spend.used = {amount_minor: 430, currency: "JPY", exponent: 0}
        | .spend.limit = {amount_minor: 5000, currency: "JPY", exponent: 0}' \
        "$fixtures/claude-usage.json" > "$work/yen.json"
    is "zero-decimal currency keeps its exponent" "430 JPY 0" \
        "$(usage --body "$work/yen.json" | jq -r '.claude.spend
            | [.used_minor, .currency, .exponent] | join(" ")')"

    # Auth. Each of these is a different sentence in the popout.
    is "no credentials file reads as signed out" "signed_out" \
        "$(usage --creds "$work/absent.json" | jq -r '.claude_auth')"
    is "a lapsed expiresAt reads as expired" "expired" \
        "$(usage --creds "$work/creds-expired.json" | jq -r '.claude_auth')"
    is "a refused token reads as expired whatever the clock says" "expired" \
        "$(usage --status 401 | jq -r '.claude_auth')"
    is "an expired token yields no limits" "null" \
        "$(usage --status 401 | jq -r '.claude')"

    # Carry-forward: a provider that fails keeps its previous entry, and keeps
    # the older captured_at that lets the widget label it as stale. A 429 is
    # what this looks like in practice — the endpoint answers, with an error
    # body where the windows should be.
    # Codex answers throughout, because that is the case this exists for: a
    # snapshot Codex keeps alive must not blank Claude out of it, which would
    # read as Claude not being installed.
    printf '%s\n' '{"type":"error","error":{"type":"rate_limit_error","message":"rate limit"}}' \
        > "$work/rate-limited.json"
    cache="$work/carry.json"
    usage --cache "$cache" --codex "$fixtures/codex-ratelimits.json" > /dev/null
    stamped=$(jq -r '.claude.captured_at' "$cache")
    sleep 1
    after=$(usage --cache "$cache" --status 429 --body "$work/rate-limited.json" \
                  --codex "$fixtures/codex-ratelimits.json")
    is "a failed fetch carries the previous entry forward" "71" \
        "$(printf '%s' "$after" | jq -r '.claude.limits[0].pct')"
    is "the carried entry keeps its original captured_at" "$stamped" \
        "$(printf '%s' "$after" | jq -r '.claude.captured_at')"
    is "the provider that answered is stamped fresh" "true" \
        "$(printf '%s' "$after" | jq -r '.codex.captured_at == .captured_at')"
    is "the snapshot itself is stamped now" "true" \
        "$(printf '%s' "$after" | jq -r ".captured_at > $stamped")"

    # An hour of silence is not throttling — it is a provider that has gone
    # away, and hour-old percentages would be a worse answer than none.
    MAX_STALE=0 CLAUDE_USAGE_BODY="$work/rate-limited.json" \
    CLAUDE_USAGE_STATUS=429 CLAUDE_CREDS="$work/creds-ok.json" \
    CODEX_LIMITS_FILE="$fixtures/codex-ratelimits.json" CACHE_FILE="$cache" MIN_AGE=0 \
        sh "$root/fetch-usage.sh" --no-notify > "$work/stale-out.json" 2>/dev/null
    is "carry-forward stops at MAX_STALE" "null" \
        "$(jq -r '.claude' "$work/stale-out.json")"
    is "and the provider still answering is unaffected" "Weekly" \
        "$(jq -r '.codex.limits[0].label' "$work/stale-out.json")"

    # Both providers silent: the cache is left exactly as it was, because stale
    # limits beat none, and captured_at staying put is what makes the next run
    # retry immediately instead of sitting out the min_age window.
    cache="$work/keep.json"
    usage --cache "$cache" > /dev/null
    kept=$(jq -r '.captured_at' "$cache")
    sleep 1
    usage --cache "$cache" --status 500 --body "$work/rate-limited.json" > /dev/null
    is "a total failure leaves captured_at where it was" "$kept" \
        "$(jq -r '.captured_at' "$cache")"
    is "and the auth verdict is still refreshed onto it" "ok" \
        "$(jq -r '.claude_auth' "$cache")"

    # Codex, from a recorded app-server response.
    out=$(usage --codex "$fixtures/codex-ratelimits.json")
    is "codex plan" "plus" "$(printf '%s' "$out" | jq -r '.codex.plan')"
    is "a 10080-minute window is named weekly" "Weekly" \
        "$(printf '%s' "$out" | jq -r '.codex.limits[0].label')"
    is "codex percentage floors" "15" \
        "$(printf '%s' "$out" | jq -r '.codex.limits[0].pct')"

    # rateLimitsByLimitId is preferred, so a response carrying only that must
    # still produce limits.
    jq -c 'del(.result.rateLimits)' "$fixtures/codex-ratelimits.json" \
        > "$work/codex-by-id.json"
    is "by-id-only response still yields limits" "Weekly" \
        "$(usage --codex "$work/codex-by-id.json" | jq -r '.codex.limits[0].label')"
    is "by-id-only response still yields the plan" "plus" \
        "$(usage --codex "$work/codex-by-id.json" | jq -r '.codex.plan')"

    # Reset credits. Expiries are relative to now, for the same reason the
    # session logs are generated: the recorded fixture's one credit has already
    # lapsed, which is a fine test of the filter and no test of anything else.
    jq -c --argjson now "$now" '
        .result.rateLimitResetCredits.credits = [
          {title: "Full reset", status: "available", expiresAt: ($now + 864000)},
          {title: "Full reset", status: "available", expiresAt: ($now + 86400)},
          {title: "Full reset", status: "available", expiresAt: ($now - 60)},
          {title: "Full reset", status: "redeemed",  expiresAt: ($now + 172800)}]
    ' "$fixtures/codex-ratelimits.json" > "$work/codex-resets.json"
    out=$(usage --codex "$work/codex-resets.json")
    is "only unexpired, unspent resets are kept" "2" \
        "$(printf '%s' "$out" | jq '.codex.resets | length')"
    is "the soonest expiry comes first" "$((now + 86400))" \
        "$(printf '%s' "$out" | jq '.codex.resets[0].expires_at')"
    is "resets carry their title" "Full reset" \
        "$(printf '%s' "$out" | jq -r '.codex.resets[0].title')"
    is "a lapsed credit leaves an empty list, not null" "[]" \
        "$(usage --codex "$fixtures/codex-ratelimits.json" | jq -c '.codex.resets')"

    jq -c 'del(.result.rateLimitResetCredits)' "$fixtures/codex-ratelimits.json" \
        > "$work/codex-no-resets.json"
    is "a response without the block reports null" "null" \
        "$(usage --codex "$work/codex-no-resets.json" | jq -c '.codex.resets')"
}

# ---------------------------------------------------------------------------
# notify — threshold crossings
# ---------------------------------------------------------------------------

# notify CACHE BODY [ARGS...] -> prints whatever notify-send was asked to show
notify() {
    cache=$1
    body=$2
    shift 2
    : > "$work/notify.log"
    NOTIFY_LOG="$work/notify.log" \
    PATH="$work/bin:$PATH" \
    CLAUDE_USAGE_BODY="$body" \
    CLAUDE_CREDS="$work/creds-ok.json" \
    CODEX_LIMITS_FILE="$silent_codex" \
    CACHE_FILE="$cache" \
    MIN_AGE=0 \
        sh "$root/fetch-usage.sh" "$@" > /dev/null 2>&1
    cat "$work/notify.log"
}

test_notify() {
    section "fetch-usage.sh — threshold crossings"

    base="$fixtures/claude-usage.json"
    jq '.five_hour.utilization = 3.0 | .spend.percent = 4' "$base" > "$work/quiet.json"
    jq '.five_hour.utilization = 75.0 | .spend.percent = 4' "$base" > "$work/warned.json"
    jq '.five_hour.utilization = 95.0 | .spend.percent = 4' "$base" > "$work/critical.json"

    # A bucket nobody has seen before seeds silently: the number may have been
    # sitting there for days, and announcing it on first sight would alert on
    # every shell start.
    cache="$work/n1.json"
    is "first ever run is silent" "" "$(notify "$cache" "$work/critical.json" --notify)"

    # Now it has a baseline, an upward crossing speaks.
    cache="$work/n2.json"
    notify "$cache" "$work/quiet.json" --notify > /dev/null
    out=$(notify "$cache" "$work/warned.json" --notify)
    has "crossing warn alerts" "Claude 5-hour at 75% used" "$out"
    has "warn is a normal notification" "-u normal" "$out"
    has "the body carries the window's remaining time" "Resets in" "$out"
    has "the provider's own icon rides along" "claude.svg" "$out"

    out=$(notify "$cache" "$work/warned.json" --notify)
    is "the same reading does not alert twice" "" "$out"

    out=$(notify "$cache" "$work/critical.json" --notify)
    has "crossing crit alerts" "Claude 5-hour at 95% used" "$out"
    has "crit is a critical notification" "-u critical" "$out"

    # Straight past both thresholds in one poll: the higher one, once.
    cache="$work/n3.json"
    notify "$cache" "$work/quiet.json" --notify > /dev/null
    out=$(notify "$cache" "$work/critical.json" --notify)
    is "a jump past both thresholds alerts once" "1" \
        "$(printf '%s' "$out" | grep -c '5-hour')"
    has "and reports the higher one" "-u critical" "$out"

    # A window that rolls over falls to zero, which is not a crossing — and it
    # re-arms the next climb without anything having to remember it fired.
    cache="$work/n4.json"
    notify "$cache" "$work/critical.json" --notify > /dev/null
    out=$(notify "$cache" "$work/quiet.json" --notify)
    is "a window reset is silent" "" "$out"
    out=$(notify "$cache" "$work/warned.json" --notify)
    has "and the next climb alerts again" "at 75% used" "$out"

    # Credits cross on their own account.
    cache="$work/n5.json"
    notify "$cache" "$work/quiet.json" --notify > /dev/null
    jq '.five_hour.utilization = 3.0 | .spend.percent = 91' "$base" > "$work/credits-high.json"
    out=$(notify "$cache" "$work/credits-high.json" --notify)
    has "credits crossing alerts" "Claude credits at 91% used" "$out"
    lacks "a credits alert has no reset to promise" "Resets in" "$out"

    # Thresholds come from the caller.
    cache="$work/n6.json"
    notify "$cache" "$work/quiet.json" --notify --warn 1 --crit 2 > /dev/null
    out=$(notify "$cache" "$work/warned.json" --notify --warn 80 --crit 90)
    is "a crossing below the given warn level stays quiet" "" "$out"

    cache="$work/n7.json"
    notify "$cache" "$work/quiet.json" --notify > /dev/null
    out=$(notify "$cache" "$work/critical.json" --no-notify)
    is "--no-notify silences a real crossing" "" "$out"

    # A carried-forward provider has identical numbers by definition, so the
    # routine 429 that produces one cannot re-announce anything.
    cache="$work/n8.json"
    notify "$cache" "$work/quiet.json" --notify > /dev/null
    notify "$cache" "$work/critical.json" --notify > /dev/null
    : > "$work/notify.log"
    NOTIFY_LOG="$work/notify.log" PATH="$work/bin:$PATH" \
    CLAUDE_USAGE_BODY="$work/critical.json" CLAUDE_USAGE_STATUS=429 \
    CLAUDE_CREDS="$work/creds-ok.json" CODEX_LIMITS_FILE="$fixtures/codex-ratelimits.json" \
    CACHE_FILE="$cache" MIN_AGE=0 \
        sh "$root/fetch-usage.sh" --notify > /dev/null 2>&1
    is "a carried-forward entry cannot re-alert" "" "$(cat "$work/notify.log")"

    # Several bars on several screens fetch independently. One alert between
    # them, or the same crossing arrives once per monitor.
    cache="$work/n9.json"
    notify "$cache" "$work/quiet.json" --notify > /dev/null
    : > "$work/notify.log"
    i=1
    while [ "$i" -le 4 ]; do
        NOTIFY_LOG="$work/notify.log" PATH="$work/bin:$PATH" \
        CLAUDE_USAGE_BODY="$work/critical.json" CLAUDE_CREDS="$work/creds-ok.json" \
        CODEX_LIMITS_FILE="$silent_codex" CACHE_FILE="$cache" MIN_AGE=0 \
            sh "$root/fetch-usage.sh" --notify > /dev/null 2>&1 &
        i=$((i + 1))
    done
    wait
    is "four concurrent fetches alert once" "1" \
        "$(grep -c '5-hour' "$work/notify.log")"
}

# ---------------------------------------------------------------------------
# codex — the JSON-RPC client
# ---------------------------------------------------------------------------

# codex_stub LINES_FILE -> a fake `codex app-server` that replays those lines
codex_stub() {
    cat > "$work/bin/codex" <<STUB
#!/bin/sh
# Drain the requests the client writes, then replay the recorded lines.
cat > /dev/null &
cat "$1"
sleep 5
STUB
    chmod +x "$work/bin/codex"
}

test_codex() {
    section "fetch-codex-limits.sh"

    jq -c '.' "$fixtures/codex-ratelimits.json" > "$work/rpc-legacy.txt"
    codex_stub "$work/rpc-legacy.txt"
    out=$(PATH="$work/bin:$PATH" CODEX_TIMEOUT=5 bash "$root/fetch-codex-limits.sh" 2>/dev/null)
    is "a recorded response comes back whole" "plus" \
        "$(printf '%s' "$out" | jq -r '.result.rateLimits.planType')"

    # The consumer prefers rateLimitsByLimitId, so a response carrying only
    # that has to get past the gate.
    jq -c 'del(.result.rateLimits)' "$fixtures/codex-ratelimits.json" > "$work/rpc-by-id.txt"
    codex_stub "$work/rpc-by-id.txt"
    out=$(PATH="$work/bin:$PATH" CODEX_TIMEOUT=5 bash "$root/fetch-codex-limits.sh" 2>/dev/null)
    is "a by-id-only response is accepted" "plus" \
        "$(printf '%s' "$out" | jq -r '.result.rateLimitsByLimitId.codex.planType')"

    # The app-server talks before it answers: notifications, the initialize
    # reply, and anything else carrying another id.
    {
        printf '%s\n' '{"jsonrpc":"2.0","method":"sessionConfigured","params":{}}'
        printf '%s\n' '{"id":0,"result":{"userAgent":"codex"}}'
        printf '%s\n' 'not json at all'
        cat "$work/rpc-legacy.txt"
    } > "$work/rpc-noisy.txt"
    codex_stub "$work/rpc-noisy.txt"
    out=$(PATH="$work/bin:$PATH" CODEX_TIMEOUT=5 bash "$root/fetch-codex-limits.sh" 2>/dev/null)
    is "chatter before the answer is skipped" "plus" \
        "$(printf '%s' "$out" | jq -r '.result.rateLimits.planType')"
    is "and only the answer is printed" "1" "$(printf '%s' "$out" | grep -c .)"

    printf '%s\n' '{"id":0,"result":{}}' > "$work/rpc-silent.txt"
    codex_stub "$work/rpc-silent.txt"
    PATH="$work/bin:$PATH" CODEX_TIMEOUT=1 bash "$root/fetch-codex-limits.sh" >/dev/null 2>&1
    is "an app-server that never answers times out non-zero" "1" "$?"

    rm -f "$work/bin/codex"
    PATH="$work/bin:/usr/bin:/bin" CODEX_CMD=definitely-not-installed \
        bash "$root/fetch-codex-limits.sh" >/dev/null 2>&1
    is "a missing codex exits non-zero" "1" "$?"
}

# ---------------------------------------------------------------------------
# history — local session logs
# ---------------------------------------------------------------------------

# history PROVIDER LOGDIR -> the analytics blob
history() {
    HISTORY_FILE="$work/history-$1.json" \
    CLAUDE_LOGS="$2" \
    CODEX_LOGS="$2" \
    MIN_AGE=0 \
        sh "$root/fetch-history.sh" "$1" 2>/dev/null
}

claude_line() {
    # claude_line TS MSGID REQID MODEL
    printf '{"timestamp":"%s","requestId":"%s","message":{"id":"%s","model":"%s","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":40}}}\n' \
        "$(iso "$1")" "$3" "$2" "$4"
}

test_history() {
    section "fetch-history.sh"

    # Claude. One assistant reply is written to several files as sidechains
    # replay it, so the same (message.id, requestId) must count once.
    logs="$work/claude-logs"
    mkdir -p "$logs/project-a" "$logs/project-b"
    claude_line "$((now - 3600))" msg_1 req_1 claude-sonnet-4-5-20250929 > "$logs/project-a/main.jsonl"
    claude_line "$((now - 3600))" msg_1 req_1 claude-sonnet-4-5-20250929 > "$logs/project-b/sidechain.jsonl"
    out=$(history claude "$logs")
    is "a row duplicated across files counts once" "100" \
        "$(printf '%s' "$out" | jq -r '[.daily[].tokens] | add')"
    is "the total spans input, output and both cache fields" "100" \
        "$(printf '%s' "$out" | jq -r '[.hourly[].tokens] | add')"

    # The same message answered twice is two requests, and both count.
    claude_line "$((now - 3600))" msg_1 req_2 claude-sonnet-4-5-20250929 \
        >> "$logs/project-a/main.jsonl"
    is "a second requestId is a second row" "200" \
        "$(history claude "$logs" | jq -r '[.daily[].tokens] | add')"

    # Rows outside the seven-day window are dropped on their own timestamp,
    # whatever the file's mtime says.
    claude_line "$((now - 9 * 86400))" msg_old req_old claude-sonnet-4-5-20250929 \
        >> "$logs/project-a/main.jsonl"
    out=$(history claude "$logs")
    is "an out-of-window row is excluded" "200" \
        "$(printf '%s' "$out" | jq -r '[.daily[].tokens] | add')"
    is "and excluded from the model totals too" "200" \
        "$(printf '%s' "$out" | jq -r '[.models[].tokens] | add')"

    is "models carry the recorded id" "claude-sonnet-4-5-20250929" \
        "$(history claude "$logs" | jq -r '.models[0].model')"

    # A file untouched since before the window cannot hold anything inside it,
    # which is what makes the find -newer prefilter safe. Pinned here because
    # the day someone believes otherwise, this is the line that says so.
    touch -d "@$((now - 30 * 86400))" "$logs/project-b/sidechain.jsonl"
    printf '%s' "$(claude_line "$((now - 1800))" msg_2 req_3 claude-opus-4-1-20250805)" \
        >> "$logs/project-b/sidechain.jsonl"
    touch -d "@$((now - 30 * 86400))" "$logs/project-b/sidechain.jsonl"
    is "a file older than the window is not opened" "200" \
        "$(history claude "$logs" | jq -r '[.daily[].tokens] | add')"

    # Codex. Deltas are per request and attributed to the most recent
    # turn_context, so a session that switches model splits correctly.
    logs="$work/codex-logs"
    mkdir -p "$logs/2026/08/24"
    session="$logs/2026/08/24/rollout-test.jsonl"
    {
        printf '{"timestamp":"%s","type":"session_meta","payload":{"id":"abc"}}\n' "$(iso "$((now - 7200))")"
        printf '{"timestamp":"%s","type":"turn_context","payload":{"model":"gpt-5.6-luna"}}\n' "$(iso "$((now - 7200))")"
        printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":150}}}}\n' "$(iso "$((now - 7100))")"
        printf '{"timestamp":"%s","type":"turn_context","payload":{"model":"gpt-5.6-mini"}}\n' "$(iso "$((now - 3600))")"
        printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":50}}}}\n' "$(iso "$((now - 3500))")"
    } > "$session"

    out=$(history codex "$logs")
    is "deltas sum rather than replacing each other" "200" \
        "$(printf '%s' "$out" | jq -r '[.daily[].tokens] | add')"
    is "usage lands on the model in force at the time" "gpt-5.6-luna:150 gpt-5.6-mini:50" \
        "$(printf '%s' "$out" | jq -r '[.models[] | .model + ":" + (.tokens|tostring)] | join(" ")')"
    is "models are ordered by size" "gpt-5.6-luna" \
        "$(printf '%s' "$out" | jq -r '.models[0].model')"

    # An event with no turn_context before it has no model to name, and says so
    # rather than borrowing the next one.
    printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":7}}}}\n' \
        "$(iso "$((now - 7300))")" > "$work/codex-logs/2026/08/24/rollout-bare.jsonl"
    is "usage before any turn_context is Unknown" "7" \
        "$(history codex "$logs" | jq -r '.models[] | select(.model == "Unknown") | .tokens')"

    # Shape, and the local-midnight boundaries the daily bars are drawn on.
    out=$(history codex "$logs")
    is "24 hourly buckets" "24" "$(printf '%s' "$out" | jq -r '.hourly | length')"
    is "7 daily buckets" "7" "$(printf '%s' "$out" | jq -r '.daily | length')"
    is "every day starts at a local midnight" "true" \
        "$(printf '%s' "$out" | jq -r '[.daily[].start
            | strflocaltime("%H%M")] | all(. == "0000")')"
    is "consecutive days are a day apart, give or take a DST hour" "true" \
        "$(printf '%s' "$out" | jq -r '[.daily[].start] as $s
            | [range(1; $s | length) | $s[.] - $s[. - 1]]
            | all(. >= 82800 and . <= 90000)')"
    is "hourly buckets are an hour apart" "true" \
        "$(printf '%s' "$out" | jq -r '[.hourly[].start] as $s
            | [range(1; $s | length) | $s[.] - $s[. - 1]] | all(. == 3600)')"
    is "the last hourly bucket is the current hour" "true" \
        "$(printf '%s' "$out" | jq -r ".hourly[-1].start <= $now
            and .hourly[-1].start > $now - 3600")"
    is "the last daily bucket is today" "true" \
        "$(printf '%s' "$out" | jq -r ".daily[-1].start <= $now")"

    is "an unknown provider is refused" "1" \
        "$(history nonsense "$logs" > /dev/null 2>&1; printf '%s' "$?")"
}

# ---------------------------------------------------------------------------

sections=${*:-usage notify codex history}
for name in $sections; do
    case "$name" in
        usage) test_usage ;;
        notify) test_notify ;;
        codex) test_codex ;;
        history) test_history ;;
        *) printf 'unknown section: %s\n' "$name" >&2; exit 2 ;;
    esac
done

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
