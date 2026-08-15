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
    property bool fetchFailed: false
    property int now: Math.floor(Date.now() / 1000)

    // Empty on Overview. Selecting a provider tab starts only that provider's
    // local log scan; the 5-minute timer then refreshes only the active tab.
    property string activeProvider: ""
    property var claudeHistory: null
    property var codexHistory: null
    property bool claudeHistoryLoading: false
    property bool codexHistoryLoading: false
    property bool claudeHistoryFailed: false
    property bool codexHistoryFailed: false

    readonly property bool hasData: claude !== null || codex !== null
    readonly property int refreshSeconds: 300
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

    function minutesSince(ts) {
        return ts ? Math.max(0, Math.floor((now - ts) / 60)) : -1
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
        Proc.runCommand("aiUsage.fetch", ["sh", scriptPath], function (stdout, exitCode) {
            root.fetchFailed = (exitCode !== 0)
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

    Timer {
        interval: root.refreshSeconds * 1000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: root.now = Math.floor(Date.now() / 1000)
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
