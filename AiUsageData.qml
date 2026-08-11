// Runs fetch-usage.sh on a timer and exposes the parsed result. The script owns
// the cache file; we watch it so every bar instance picks up one fetch.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common

Item {
    id: root

    // --- outputs ---
    property var claude: null           // {captured_at, limits:[{label,pct,resets_at}]} or null
    property var codex: null            // {captured_at, plan, limits:[...]} or null
    property int capturedAt: 0
    property bool fetchFailed: false    // last run reported no provider at all
    property int now: Math.floor(Date.now() / 1000)   // ticks every second

    readonly property bool hasData: claude !== null || codex !== null

    readonly property int refreshSeconds: 300
    readonly property string scriptPath: Qt.resolvedUrl("fetch-usage.sh").toString().replace("file://", "")
    readonly property string cachePath:
        (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache"))
        + "/dms-ai-usage.json"

    // Human countdown to a reset epoch: "5d 14h", "3h 12m", "8m".
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

    // Minutes since an epoch, or -1 when there is nothing to age.
    function minutesSince(ts) {
        return ts ? Math.max(0, Math.floor((now - ts) / 60)) : -1
    }

    function refresh() {
        Proc.runCommand("aiUsage.fetch", ["sh", scriptPath], function (stdout, exitCode) {
            root.fetchFailed = (exitCode !== 0)
        }, 100)
    }

    Component.onCompleted: refresh()

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
                console.warn("aiUsage: bad cache:", e)
            }
        }
        onFileChanged: reload()
    }
}
