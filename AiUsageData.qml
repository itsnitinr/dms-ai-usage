// Owns live limit data plus lazy, provider-specific local analytics caches.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common

Item {
    id: root

    property var claude: null
    property var codex: null
    property int capturedAt: 0
    // Separates "no limits yet" from "asked, and there are none". Without it an
    // empty result reads as a spinner that never finishes.
    property bool fetchedOnce: false
    property int now: Math.floor(Date.now() / 1000)
    // Attempt time, not success time: an offline retry must still push this
    // forward, or the staleness check below would refire every second.
    property int lastFetchAt: 0

    // Empty on Overview. Selecting a provider tab starts only that provider's
    // local log scan; the periodic refresh then covers only the active tab.
    property string activeProvider: ""
    property var claudeHistory: null
    property var codexHistory: null
    property bool claudeHistoryLoading: false
    property bool codexHistoryLoading: false
    property bool claudeHistoryFailed: false
    property bool codexHistoryFailed: false

    readonly property bool hasData: claude !== null || codex !== null
    // Claude's usage endpoint allows roughly two requests per five minutes and
    // answers a 429 with retry-after: 291. Polling every five minutes sat right
    // on that edge, so any Claude Code session running alongside the bar pushed
    // the poll over it; six minutes leaves the budget room for both.
    readonly property int refreshSeconds: 360
    readonly property string scriptPath: Qt.resolvedUrl("fetch-usage.sh").toString().replace("file://", "")
    readonly property string historyPath: Qt.resolvedUrl("fetch-history.sh").toString().replace("file://", "")
    readonly property string cacheDir:
        (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache"))
    readonly property string cachePath: cacheDir + "/dms-ai-usage.json"
    readonly property string claudeHistoryPath: cacheDir + "/dms-ai-usage-claude-history.json"
    readonly property string codexHistoryPath: cacheDir + "/dms-ai-usage-codex-history.json"

    function countdown(reset) {
        const s = reset - now
        if (!reset || s <= 0)
            return "now"
        const d = Math.floor(s / 86400)
        const h = Math.floor((s % 86400) / 3600)
        const m = Math.floor((s % 3600) / 60)
        if (d > 0)
            return d + "d " + h + "h"
        if (h > 0)
            return h + "h " + m + "m"
        return Math.max(1, m) + "m"
    }

    // A window that has not been opened yet has no reset time; saying it resets
    // "now" would read as if it had just rolled over.
    function resetLabel(reset) {
        return reset ? "Resets in " + countdown(reset) : "Window not started"
    }

    // Follows the shell's own clock preference, minus its seconds setting —
    // seconds on a reset that is hours away would be noise.
    function timeFormat() {
        if (SettingsData.use24HourClock)
            return "hh:mm"
        return SettingsData.padHours12Hour ? "hh:mm AP" : "h:mm AP"
    }

    function startOfDay(date) {
        const start = new Date(date)
        start.setHours(0, 0, 0, 0)
        return start.getTime()
    }

    // The wall-clock moment a window reopens, to sit alongside the countdown.
    // Weekly windows land days out, so anything past today carries its weekday;
    // past a week a weekday would name the same day as today, so it takes a
    // date instead. Rounding the day difference keeps the 23- and 25-hour days
    // either side of a daylight-saving change on the right label.
    function resetTime(reset) {
        if (!reset)
            return ""
        const at = new Date(reset * 1000)
        const clock = at.toLocaleTimeString(Qt.locale(), timeFormat())
        const days = Math.round((startOfDay(at) - startOfDay(new Date(now * 1000)))
                                / 86400000)
        if (days <= 0)
            return clock
        if (days < 7)
            return at.toLocaleDateString(Qt.locale(), "ddd") + " " + clock
        return at.toLocaleDateString(Qt.locale(), "d MMM") + " " + clock
    }

    function minutesSince(ts) {
        return ts ? Math.max(0, Math.floor((now - ts) / 60)) : -1
    }

    // A provider whose entry predates the snapshot holding it was carried
    // forward from an earlier fetch because this one failed — see the tail of
    // fetch-usage.sh. Labelling those numbers "live" is the one thing this
    // widget must not do, so say how old they actually are instead. Comparing
    // against the snapshot rather than against wall-clock time keeps a healthy
    // provider reading "live" for the whole refresh interval.
    function freshness(snapshot) {
        if (!snapshot)
            return "unavailable"
        const ts = snapshot.captured_at || 0
        if (ts <= 0 || ts >= capturedAt)
            return "live"
        return Math.max(1, minutesSince(ts)) + "m ago"
    }

    function historyFor(provider) {
        return provider === "claude" ? claudeHistory : codexHistory
    }

    function historyLoading(provider) {
        return provider === "claude" ? claudeHistoryLoading : codexHistoryLoading
    }

    function historyFailed(provider) {
        return provider === "claude" ? claudeHistoryFailed : codexHistoryFailed
    }

    function historyStale(provider) {
        const history = historyFor(provider)
        return history !== null && now - (history.captured_at || 0) > refreshSeconds * 2
    }

    function refreshLimits() {
        lastFetchAt = now
        Proc.runCommand("aiUsage.fetch", ["sh", scriptPath], function () {
            root.fetchedOnce = true
        }, 100, 20000)
    }

    function refreshHistory(provider) {
        if (provider !== "claude" && provider !== "codex")
            return

        if (provider === "claude") {
            claudeHistoryLoading = true
            claudeHistoryFailed = false
        } else {
            codexHistoryLoading = true
            codexHistoryFailed = false
        }

        Proc.runCommand("aiUsage.history." + provider,
                        ["sh", historyPath, provider],
                        function (stdout, exitCode) {
            if (provider === "claude") {
                root.claudeHistoryLoading = false
                root.claudeHistoryFailed = (exitCode !== 0)
            } else {
                root.codexHistoryLoading = false
                root.codexHistoryFailed = (exitCode !== 0)
            }
        }, 100, 30000)
    }

    // Whether the popout is actually on screen. The limits fetch is cheap and
    // feeds the bar pill, so it runs regardless; scanning session logs for a
    // chart nobody is looking at is not, so analytics stop when the popout does.
    property bool popoutVisible: false

    function refresh() {
        refreshLimits()
        if (popoutVisible && activeProvider !== "")
            refreshHistory(activeProvider)
    }

    onActiveProviderChanged: {
        if (activeProvider !== "")
            refreshHistory(activeProvider)
    }

    // Re-opening on a provider tab picks up whatever it missed while hidden. The
    // script's own cache window keeps a quick close/open from rescanning.
    onPopoutVisibleChanged: {
        if (popoutVisible && activeProvider !== "")
            refreshHistory(activeProvider)
    }

    Component.onCompleted: refreshLimits()

    // Refreshes hang off the one-second tick rather than a refreshSeconds Timer
    // because Qt timers run on a monotonic clock that stops while the machine is
    // suspended: a plain Timer resumes counting where it left off instead of
    // firing, so a laptop woken from sleep sits on stale limits for minutes.
    // Wall-clock elapsed time is the honest measure, and it also catches up
    // immediately on resume. A backwards clock jump (elapsed < 0) refreshes once
    // and re-bases lastFetchAt.
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: {
            root.now = Math.floor(Date.now() / 1000)
            const elapsed = root.now - root.lastFetchAt
            if (elapsed >= root.refreshSeconds || elapsed < 0)
                root.refresh()
        }
    }

    FileView {
        id: cacheFile
        path: root.cachePath
        watchChanges: true

        onLoaded: {
            try {
                const o = JSON.parse(cacheFile.text())
                root.capturedAt = o.captured_at || 0
                root.claude = o.claude || null
                root.codex = o.codex || null
            } catch (e) {
                console.warn("aiUsage: bad limits cache:", e)
            }
        }
        onFileChanged: reload()
    }

    FileView {
        id: claudeHistoryFile
        path: root.claudeHistoryPath
        watchChanges: true

        onLoaded: {
            try {
                const o = JSON.parse(claudeHistoryFile.text())
                if (o.provider !== "claude" || !Array.isArray(o.hourly)
                        || !Array.isArray(o.daily) || !Array.isArray(o.models))
                    throw new Error("unexpected Claude history schema")
                root.claudeHistory = o
            } catch (e) {
                console.warn("aiUsage: bad Claude history cache:", e)
            }
        }
        onFileChanged: reload()
    }

    FileView {
        id: codexHistoryFile
        path: root.codexHistoryPath
        watchChanges: true

        onLoaded: {
            try {
                const o = JSON.parse(codexHistoryFile.text())
                if (o.provider !== "codex" || !Array.isArray(o.hourly)
                        || !Array.isArray(o.daily) || !Array.isArray(o.models))
                    throw new Error("unexpected Codex history schema")
                root.codexHistory = o
            } catch (e) {
                console.warn("aiUsage: bad Codex history cache:", e)
            }
        }
        onFileChanged: reload()
    }
}
