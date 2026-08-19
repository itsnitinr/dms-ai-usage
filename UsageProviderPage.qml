// One provider's limits and local token analytics page.
import QtQuick
import qs.Common
import qs.Widgets

Column {
    id: root

    property string providerKey: ""
    property string providerName: ""
    property url providerIcon: ""
    property color providerColor: Theme.primary
    property string plan: ""
    property string freshness: "live"
    property var limits: []
    property var history: null
    property bool historyLoading: false
    property bool historyFailed: false
    property bool historyStale: false
    property int now: Math.floor(Date.now() / 1000)

    readonly property var hourly: history?.hourly ?? []
    readonly property var daily: history?.daily ?? []
    readonly property var models: history?.models ?? []
    readonly property real dailyPeak: maximum(daily)
    readonly property real modelPeak: maximum(models)
    readonly property real weeklyTotal: total(daily)
    readonly property real preferredHeight: childrenRect.y + childrenRect.height

    spacing: Theme.spacingL
    topPadding: Theme.spacingS

    function maximum(rows) {
        let value = 0
        for (let i = 0; i < rows.length; i++)
            value = Math.max(value, rows[i].tokens || 0)
        return value
    }

    function total(rows) {
        let value = 0
        for (let i = 0; i < rows.length; i++)
            value += rows[i].tokens || 0
        return value
    }

    function formatTokens(n) {
        if (!n)
            return "0"
        if (n >= 1000000000)
            return (n / 1000000000).toFixed(n >= 10000000000 ? 0 : 1) + "B"
        if (n >= 1000000)
            return (n / 1000000).toFixed(n >= 10000000 ? 0 : 1) + "M"
        if (n >= 1000)
            return (n / 1000).toFixed(n >= 10000 ? 0 : 1) + "K"
        return String(n)
    }

    function remaining(pct) {
        return Math.max(0, 100 - Math.max(0, Math.min(100, pct || 0)))
    }

    function countdown(reset) {
        const seconds = reset - now
        if (!reset || seconds <= 0)
            return "now"
        const days = Math.floor(seconds / 86400)
        const hours = Math.floor((seconds % 86400) / 3600)
        const minutes = Math.floor((seconds % 3600) / 60)
        if (days > 0)
            return days + "d " + hours + "h"
        if (hours > 0)
            return hours + "h " + minutes + "m"
        return Math.max(1, minutes) + "m"
    }

    function resetLabel(reset) {
        return reset ? "Resets in " + countdown(reset) : "Window not started"
    }

    function dayLabel(epoch, index) {
        if (index === daily.length - 1)
            return "Today"
        return new Date(epoch * 1000).toLocaleDateString(Qt.locale(), "ddd")
    }

    // Model ids arrive hyphenated with the version split across segments
    // (`claude-sonnet-4-5-20250929`, `gpt-5-codex`), so a plain title-case of
    // every segment renders "Claude Sonnet 4 5 20250929". Rejoin the numeric
    // run into one version instead and title-case the words around it. The
    // trailing eight-digit date is a build stamp rather than part of the name,
    // and the `claude-` prefix only repeats the provider heading above.
    function modelLabel(value) {
        if (!value || value === "Unknown")
            return "Unknown model"

        const parts = String(value).replace(/^claude-/, "")
                                   .replace(/-\d{8}$/, "").split("-")
        const words = []
        let version = []

        function flushVersion() {
            if (version.length === 0)
                return
            // "GPT-5.1" carries its version on a hyphen; every other family
            // spaces it off ("Sonnet 4.5").
            const joined = version.join(".")
            if (words.length > 0 && words[words.length - 1] === "GPT")
                words[words.length - 1] += "-" + joined
            else
                words.push(joined)
            version = []
        }

        for (let i = 0; i < parts.length; i++) {
            const part = parts[i]
            if (part.length === 0)
                continue
            if (/^\d/.test(part)) {
                version.push(part)
                continue
            }
            flushVersion()
            words.push(part === "gpt" ? "GPT"
                                      : part.charAt(0).toUpperCase() + part.slice(1))
        }
        flushVersion()

        return words.length > 0 ? words.join(" ") : "Unknown model"
    }

    function historyCaption() {
        if (!history)
            return historyLoading ? "Reading local session history…" : "No local analytics available"
        const age = Math.max(0, Math.floor((now - (history.captured_at || 0)) / 60))
        let freshness = age <= 0 ? "updated now" : "updated " + age + "m ago"
        if (historyFailed)
            freshness += " · refresh failed"
        else if (historyStale)
            freshness += " · stale"
        return "Local session tokens · " + freshness
    }

    component SectionTitle: StyledText {
        font.pixelSize: Theme.fontSizeSmall
        font.weight: Font.Bold
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.6
        color: Theme.surfaceTextMedium
    }

    component Rule: Rectangle {
        width: root.width
        height: 1
        color: Theme.outlineLight
    }

    Item {
        width: parent.width
        height: Math.max(Theme.iconSize + 2, providerTitle.implicitHeight)

        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingS

            DankSVGIcon {
                source: root.providerIcon
                size: Theme.iconSize + 2
                anchors.verticalCenter: parent.verticalCenter
            }
            StyledText {
                id: providerTitle
                text: root.providerName
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Bold
                anchors.verticalCenter: parent.verticalCenter
            }
            StyledText {
                text: root.plan
                visible: text.length > 0
                color: Theme.surfaceTextMedium
                font.pixelSize: Theme.fontSizeSmall
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        StyledText {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.limits.length > 0 ? root.freshness : "unavailable"
            color: Theme.surfaceTextMedium
            font.pixelSize: Theme.fontSizeSmall
        }
    }

    Column {
        width: parent.width
        spacing: Theme.spacingM

        SectionTitle { text: "Limits" }

        Column {
            width: parent.width
            spacing: Theme.spacingM

            Repeater {
                model: root.limits

                delegate: Column {
                    required property var modelData
                    width: parent.width
                    spacing: Theme.spacingXXS

                Item {
                    width: parent.width
                    height: limitName.implicitHeight

                    StyledText {
                        id: limitName
                        anchors.left: parent.left
                        text: modelData.label
                        color: Theme.surfaceText
                        font.pixelSize: Theme.fontSizeSmall
                    }
                    StyledText {
                        anchors.right: parent.right
                        text: modelData.pct + "% used"
                        color: root.providerColor
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
                        color: root.providerColor
                    }
                }

                Item {
                    width: parent.width
                    height: resetText.implicitHeight

                    StyledText {
                        id: resetText
                        anchors.left: parent.left
                        text: root.resetLabel(modelData.resets_at)
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                    }
                    StyledText {
                        anchors.right: parent.right
                        text: root.remaining(modelData.pct) + "% remaining"
                        color: Theme.surfaceTextMedium
                        font.pixelSize: Theme.fontSizeSmall
                    }
                }
                }
            }
        }

        StyledText {
            width: parent.width
            visible: root.limits.length === 0
            text: "No live limit data for this provider."
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
            wrapMode: Text.WordWrap
        }
    }

    Rule { visible: root.history !== null || root.historyLoading || root.historyFailed }

    Column {
        width: parent.width
        visible: root.history !== null
        spacing: Theme.spacingM

        SectionTitle { text: "Hourly usage" }

        Loader {
            id: hourlyLoader
            width: parent.width
            source: Qt.resolvedUrl("UsageGraph.qml")
        }
        Binding {
            target: hourlyLoader.item
            when: hourlyLoader.item !== null
            property: "buckets"
            value: root.hourly
        }
        Binding {
            target: hourlyLoader.item
            when: hourlyLoader.item !== null
            property: "barColor"
            value: root.providerColor
        }
    }

    Rule { visible: root.history !== null }

    Column {
        width: parent.width
        visible: root.history !== null
        spacing: Theme.spacingM

        Item {
            width: parent.width
            height: dailyTitle.implicitHeight
            SectionTitle { id: dailyTitle; anchors.left: parent.left; text: "Tokens by day" }
            StyledText {
                anchors.right: parent.right
                text: root.formatTokens(root.weeklyTotal) + " / 7 days"
                color: Theme.surfaceTextMedium
                font.pixelSize: Theme.fontSizeSmall
            }
        }

        Column {
            width: parent.width

            Repeater {
                model: root.daily

                delegate: Item {
                    required property var modelData
                    required property int index
                    width: parent.width
                    height: 24

                StyledText {
                    id: dayName
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: 48
                    text: root.dayLabel(modelData.start, index)
                    color: index === root.daily.length - 1 ? Theme.surfaceText : Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: index === root.daily.length - 1 ? Font.Bold : Font.Normal
                }
                StyledText {
                    id: dayValue
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 64
                    horizontalAlignment: Text.AlignRight
                    text: root.formatTokens(modelData.tokens)
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                }
                Rectangle {
                    anchors.left: dayName.right
                    anchors.leftMargin: Theme.spacingS
                    anchors.right: dayValue.left
                    anchors.rightMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    height: 5
                    radius: height / 2
                    color: Theme.surfaceVariant

                    Rectangle {
                        width: parent.width * (modelData.tokens || 0) / Math.max(1, root.dailyPeak)
                        height: parent.height
                        radius: parent.radius
                        color: root.providerColor
                    }
                }
                }
            }
        }
    }

    Rule { visible: root.history !== null }

    Column {
        width: parent.width
        visible: root.history !== null
        spacing: Theme.spacingS

        SectionTitle { text: "Tokens by model · 7 days" }

        Column {
            width: parent.width
            spacing: Theme.spacingS

            Repeater {
                model: root.models

                delegate: Item {
                    required property var modelData
                    width: parent.width
                    height: 30

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.cornerRadius
                    color: Theme.surfaceVariant
                }
                Rectangle {
                    width: parent.width * (modelData.tokens || 0) / Math.max(1, root.modelPeak)
                    height: parent.height
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(root.providerColor, 0.22)
                }
                StyledText {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.modelLabel(modelData.model)
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeSmall
                }
                StyledText {
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.formatTokens(modelData.tokens)
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                }
                }
            }
        }

        StyledText {
            visible: root.models.length === 0
            text: "No model-attributed local usage in this window."
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
        }
    }

    StyledText {
        width: parent.width
        text: root.historyCaption()
        color: root.historyFailed || root.historyStale ? Theme.warning : Theme.surfaceVariantText
        font.pixelSize: Theme.fontSizeSmall
        wrapMode: Text.WordWrap
    }
}
