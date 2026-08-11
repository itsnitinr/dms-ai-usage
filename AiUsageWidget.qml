// Claude Code + Codex subscription limits: one status icon in the bar, the
// numbers in the popout.
import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root
    pluginId: "aiUsage"

    // Thresholds kept in code so the settings page stays short.
    readonly property int warnPct: 70       // amber at/above
    readonly property int critPct: 90       // red at/above
    readonly property int staleMinutes: 180 // flag a snapshot older than this

    readonly property bool showClaude: pluginData.showClaude !== false
    readonly property bool showCodex: pluginData.showCodex !== false

    // Content is inset to line up with the popout header's own left margin.
    readonly property real contentPadding: Theme.spacingS

    AiUsageData { id: data }

    // Inline Components can't resolve a sibling id, so everything goes through root.
    readonly property bool hasData: data.hasData
    readonly property bool fetchFailed: data.fetchFailed
    readonly property int tick: data.now

    function countdown(reset) { return data.countdown(reset) }
    function minutesSince(ts) { return data.minutesSince(ts) }
    function refresh() { data.refresh() }

    function usageColor(pct) {
        return pct >= critPct ? Theme.error : pct >= warnPct ? Theme.warning : Theme.primary
    }

    // Enabled providers that actually reported something.
    function providers() {
        const out = []
        if (showClaude && data.claude && data.claude.limits && data.claude.limits.length > 0) {
            out.push({
                name: "Claude",
                icon: Qt.resolvedUrl("assets/claude.svg").toString(),
                limits: data.claude.limits,
                capturedAt: data.claude.captured_at || 0,
                plan: "",
                // Claude is queried live; Codex only updates when the CLI runs.
                live: true
            })
        }
        if (showCodex && data.codex && data.codex.limits && data.codex.limits.length > 0) {
            out.push({
                name: "Codex",
                icon: Qt.resolvedUrl("assets/codex.svg").toString(),
                limits: data.codex.limits,
                capturedAt: data.codex.captured_at || 0,
                plan: data.codex.plan || "",
                live: false
            })
        }
        return out
    }

    // Highest utilization across everything shown, or -1 with no data.
    function maxPct() {
        let m = -1
        const ps = providers()
        for (let i = 0; i < ps.length; i++)
            for (let j = 0; j < ps[i].limits.length; j++)
                m = Math.max(m, ps[i].limits[j].pct)
        return m
    }

    // The bar icon sits among monochrome widgets, so it stays neutral until
    // something actually needs attention.
    function pillColor() {
        const m = maxPct()
        if (m < 0)
            return Theme.surfaceTextMedium
        return m >= critPct ? Theme.error : m >= warnPct ? Theme.warning : Theme.surfaceText
    }

    // Freshness for a provider, as a short right-aligned caption.
    function freshness(p) {
        if (p.live)
            return "live"
        const mins = minutesSince(p.capturedAt)
        if (mins < 0)
            return ""
        if (mins <= 0)
            return "just now"
        return mins >= 60 ? Math.floor(mins / 60) + "h ago" : mins + "m ago"
    }

    function isStale(p) {
        return !p.live && minutesSince(p.capturedAt) > staleMinutes
    }

    pillRightClickAction: function () { root.refresh() }

    // BasePill (which PluginComponent wraps these in) draws the background,
    // applies the bar's widgetPadding and owns hover/ripple — it sizes itself
    // from the content's implicit size, so the content is the icon alone.
    horizontalBarPill: Component {
        DankIcon {
            name: "speed"
            size: root.iconSize
            color: root.pillColor()
        }
    }

    verticalBarPill: Component {
        DankIcon {
            name: "speed"
            size: root.iconSize
            color: root.pillColor()
        }
    }

    popoutWidth: 340
    popoutHeight: 0     // PluginPopout rebinds this to the content's implicit height
    popoutContent: Component {
        PopoutComponent {
            headerText: "AI Usage"
            showCloseButton: true
            closePopout: function () { root.closePopout() }

            // Refresh lives in the header, so no hint line is needed below.
            headerActions: Component {
                DankActionButton {
                    iconName: "refresh"
                    iconColor: Theme.surfaceTextMedium
                    tooltipText: "Refresh now"
                    onClicked: root.refresh()
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingL
                leftPadding: root.contentPadding
                rightPadding: root.contentPadding
                topPadding: Theme.spacingXS
                bottomPadding: Theme.spacingXS

                Repeater {
                    model: root.providers()

                    delegate: Column {
                        required property var modelData
                        required property int index

                        width: parent.width - root.contentPadding * 2
                        spacing: Theme.spacingM

                        // Hairline between providers, never above the first.
                        Rectangle {
                            width: parent.width
                            height: 1
                            visible: index > 0
                            color: Theme.outlineLight
                        }

                        Item {
                            width: parent.width
                            height: providerName.implicitHeight

                            Row {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingXS

                                DankSVGIcon {
                                    source: modelData.icon
                                    size: Theme.fontSizeMedium + 2
                                    colorOverride: Theme.surfaceTextMedium
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                StyledText {
                                    id: providerName
                                    text: modelData.name
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                StyledText {
                                    text: modelData.plan
                                    visible: modelData.plan !== ""
                                    color: Theme.surfaceTextMedium
                                    font.pixelSize: Theme.fontSizeSmall
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            StyledText {
                                readonly property int t: root.tick
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.freshness(modelData)
                                color: root.isStale(modelData) ? Theme.warning : Theme.surfaceTextMedium
                                font.pixelSize: Theme.fontSizeSmall
                            }
                        }

                        Repeater {
                            model: modelData.limits

                            delegate: Column {
                                required property var modelData

                                width: parent.width
                                spacing: Theme.spacingXXS

                                Item {
                                    width: parent.width
                                    height: limitLabel.implicitHeight

                                    StyledText {
                                        id: limitLabel
                                        anchors.left: parent.left
                                        text: modelData.label
                                        color: Theme.surfaceText
                                        font.pixelSize: Theme.fontSizeSmall
                                    }
                                    StyledText {
                                        anchors.right: parent.right
                                        text: modelData.pct + "%"
                                        color: root.usageColor(modelData.pct)
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Medium
                                    }
                                }

                                Rectangle {
                                    width: parent.width
                                    height: 5
                                    radius: height / 2
                                    color: Theme.surfaceVariant

                                    Rectangle {
                                        width: parent.width * Math.max(0, Math.min(1, modelData.pct / 100))
                                        height: parent.height
                                        radius: parent.radius
                                        color: root.usageColor(modelData.pct)

                                        Behavior on width {
                                            NumberAnimation { duration: Theme.shortDuration; easing.type: Easing.OutCubic }
                                        }
                                    }
                                }

                                StyledText {
                                    readonly property int t: root.tick   // re-evaluate each second
                                    text: "resets in " + root.countdown(modelData.resets_at)
                                    color: Theme.surfaceTextMedium
                                    font.pixelSize: Theme.fontSizeSmall
                                }
                            }
                        }
                    }
                }

                StyledText {
                    width: parent.width - root.contentPadding * 2
                    visible: !root.hasData
                    wrapMode: Text.WordWrap
                    text: root.fetchFailed
                        ? "No usage found. Sign in to Claude Code (`claude` then `/login`) or run Codex at least once."
                        : "Loading usage…"
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                StyledText {
                    width: parent.width - root.contentPadding * 2
                    visible: root.hasData && root.providers().length === 0
                    wrapMode: Text.WordWrap
                    text: "Both providers are hidden — enable one in plugin settings."
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }
            }
        }
    }
}
