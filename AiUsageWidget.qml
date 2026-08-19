// Claude Code + Codex subscription limits and lazy local analytics.
import QtQuick
import QtQuick.Window
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root
    pluginId: "aiUsage"

    readonly property int warnPct: 70
    readonly property int critPct: 90
    readonly property bool showClaude: pluginData.showClaude !== false
    readonly property bool showCodex: pluginData.showCodex !== false
    readonly property real contentPadding: Theme.spacingS

    property int currentTab: 0            // Overview, Codex, Claude
    readonly property string activeProvider:
        currentTab === 1 ? "codex" : currentTab === 2 ? "claude" : ""

    // URL loading bypasses Qt's cached same-directory type table during an
    // in-place plugin upgrade. The query also separates this revision from a
    // previously cached AiUsageData component URL.
    Loader {
        id: dataLoader
        source: Qt.resolvedUrl("AiUsageData.qml?dashboard=3")
    }
    readonly property var usageData: dataLoader.item
    Binding {
        target: dataLoader.item
        when: dataLoader.item !== null
        property: "activeProvider"
        value: root.activeProvider
    }

    readonly property bool hasData: usageData?.hasData ?? false
    readonly property bool fetchedOnce: usageData?.fetchedOnce ?? false

    // A machine that has never signed into either CLI has nothing to say, and a
    // permanently dimmed icon says it badly. Collapse out of the bar instead,
    // and come back on the first fetch that finds something. Staying put until
    // that first fetch completes avoids flashing the pill away on every shell
    // start. fetch-usage.sh carries a failed provider forward for an hour, so
    // this waits out a transient outage rather than reacting to one.
    readonly property bool nothingToShow: fetchedOnce && !hasData
    onNothingToShowChanged: setVisibilityOverride(!nothingToShow)
    readonly property int tick: usageData?.now ?? Math.floor(Date.now() / 1000)

    function countdown(reset) { return usageData ? usageData.countdown(reset) : "" }
    function resetLabel(reset) { return usageData ? usageData.resetLabel(reset) : "" }
    function minutesSince(ts) { return usageData ? usageData.minutesSince(ts) : -1 }
    function freshness(snapshot) { return usageData ? usageData.freshness(snapshot) : "" }
    function refresh() { if (usageData) usageData.refresh() }

    readonly property var codexLimits: usageData?.codex?.limits ?? []
    readonly property var claudeLimits: usageData?.claude?.limits ?? []
    readonly property bool showCodexLimits: showCodex && codexLimits.length > 0
    readonly property bool showClaudeLimits: showClaude && claudeLimits.length > 0
    readonly property int visibleProviderCount:
        (showCodexLimits ? 1 : 0) + (showClaudeLimits ? 1 : 0)

    function remaining(pct) {
        return Math.max(0, 100 - Math.max(0, Math.min(100, pct || 0)))
    }

    function usageColor(pct) {
        return pct >= critPct ? Theme.error : pct >= warnPct ? Theme.warning : Theme.primary
    }

    function maxPct() {
        let maximum = -1
        const limits = codexLimits.concat(claudeLimits)
        for (let i = 0; i < limits.length; i++)
            maximum = Math.max(maximum, limits[i].pct)
        return maximum
    }

    function pillColor() {
        const maximum = maxPct()
        if (maximum < 0)
            return Theme.surfaceTextMedium
        return maximum >= critPct ? Theme.error
             : maximum >= warnPct ? Theme.warning : Theme.surfaceText
    }

    component OverviewLimits: Column {
        id: overviewLimits

        required property string providerName
        required property url providerIcon
        required property color providerColor
        required property var limits
        property string plan: ""
        property string freshness: "live"
        property bool first: false

        width: parent?.width ?? 0
        spacing: Theme.spacingM

        Rectangle {
            width: parent.width
            height: 1
            visible: !first
            color: Theme.outlineLight
        }

        Item {
            width: parent.width
            height: Math.max(Theme.fontSizeMedium + 3,
                             overviewProviderTitle.implicitHeight)

            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                DankSVGIcon {
                    source: overviewLimits.providerIcon
                    size: Theme.fontSizeMedium + 3
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    id: overviewProviderTitle
                    text: overviewLimits.providerName
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Bold
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    text: overviewLimits.plan
                    visible: text.length > 0
                    color: Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeSmall
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            StyledText {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: overviewLimits.freshness
                color: Theme.surfaceTextMedium
                font.pixelSize: Theme.fontSizeSmall
            }
        }

        Column {
            width: parent.width
            spacing: Theme.spacingM

            Repeater {
                model: overviewLimits.limits

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

                    Item {
                        width: parent.width
                        height: resetText.implicitHeight

                        StyledText {
                            id: resetText
                            readonly property int t: root.tick
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
    }

    pillRightClickAction: function () { root.refresh() }

    horizontalBarPill: Component {
        DankIcon {
            name: "insights"
            size: root.iconSize
            color: root.pillColor()
        }
    }

    verticalBarPill: Component {
        DankIcon {
            name: "insights"
            size: root.iconSize
            color: root.pillColor()
        }
    }

    popoutWidth: 420
    popoutHeight: 0
    popoutContent: Component {
        PopoutComponent {
            id: popoutRoot
            headerText: "AI Usage"
            showCloseButton: true
            closePopout: function () { root.closePopout() }

            // DankPopout keeps this content tree loaded after close so re-opening
            // is instant, which means destruction is not a close signal and the
            // last provider tab would otherwise keep scanning session logs every
            // five minutes for the rest of the session. Window visibility is the
            // signal that actually tracks whether anything is on screen.
            readonly property bool onScreen: Window.window?.visible ?? false

            Binding {
                target: root.usageData
                when: root.usageData !== null
                property: "popoutVisible"
                value: popoutRoot.onScreen
            }

            headerActions: Component {
                DankActionButton {
                    iconName: "refresh"
                    iconColor: Theme.surfaceTextMedium
                    tooltipText: "Refresh current view"
                    onClicked: root.refresh()
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingM + 4
                leftPadding: root.contentPadding
                rightPadding: root.contentPadding
                topPadding: Theme.spacingXS
                bottomPadding: Theme.spacingXS

                DankTabBar {
                    width: parent.width - root.contentPadding * 2
                    height: 30
                    tabHeight: 36
                    spacing: Theme.spacingXXS
                    currentIndex: root.currentTab
                    showIcons: false
                    equalWidthTabs: true
                    enableArrowNavigation: true
                    model: [
                        {text: "Overview", icon: ""},
                        {text: "Codex", icon: ""},
                        {text: "Claude", icon: ""}
                    ]
                    onTabClicked: function (index) { root.currentTab = index }
                }

                DankFlickable {
                    id: pageFlick
                    width: parent.width - root.contentPadding * 2
                    readonly property real pageHeight:
                        root.currentTab === 0
                        ? overviewPage.implicitHeight
                        : providerLoader.loadedHeight
                    height: Math.min(pageHeight, 560)
                    contentWidth: width
                    contentHeight: pageHeight
                    clip: contentHeight > height

                    onWidthChanged: contentX = 0

                    Connections {
                        target: root
                        function onCurrentTabChanged() { pageFlick.contentY = 0 }
                    }

                    // DMS draws a 6px pill in a 10px column at full opacity in
                    // Theme.outline, which is louder than anything else in this
                    // popout. The pill is DankScrollbar's contentItem and gets
                    // its width from the control minus padding, so the only way
                    // to reach either from out here is a Binding. Padding does
                    // the thinning rather than implicitWidth so the bar keeps a
                    // 10px grab area to drag.
                    Binding {
                        target: pageFlick.verticalScrollBar
                        property: "padding"
                        value: 3
                    }
                    Binding {
                        target: pageFlick.verticalScrollBar.contentItem
                        property: "color"
                        value: pageFlick.verticalScrollBar.pressed
                               ? Theme.outline : Theme.outlineMedium
                    }
                    Binding {
                        target: pageFlick.verticalScrollBar.contentItem
                        property: "opacity"
                        value: pageFlick.verticalScrollBar.pressed ? 0.9 : 0.45
                    }

                    Column {
                        id: overviewPage
                        width: pageFlick.width
                        visible: root.currentTab === 0
                        spacing: Theme.spacingL
                        topPadding: Theme.spacingS

                        OverviewLimits {
                            width: parent.width
                            visible: root.showCodexLimits
                            first: true
                            providerName: "Codex"
                            providerIcon: Qt.resolvedUrl("assets/codex.svg")
                            providerColor: Theme.tertiary
                            plan: root.usageData?.codex?.plan ?? ""
                            freshness: root.freshness(root.usageData?.codex)
                            limits: root.codexLimits
                        }

                        OverviewLimits {
                            width: parent.width
                            visible: root.showClaudeLimits
                            first: !root.showCodexLimits
                            providerName: "Claude"
                            providerIcon: Qt.resolvedUrl("assets/claude.svg")
                            providerColor: Theme.primary
                            freshness: root.freshness(root.usageData?.claude)
                            limits: root.claudeLimits
                        }

                        StyledText {
                            width: parent.width
                            visible: !root.hasData
                            wrapMode: Text.WordWrap
                            text: root.fetchedOnce
                                ? "No live limits found. Sign in to Claude Code or Codex."
                                : "Loading live limits…"
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                        }

                        StyledText {
                            width: parent.width
                            visible: root.hasData && root.visibleProviderCount === 0
                            wrapMode: Text.WordWrap
                            text: "Both providers are hidden — enable one in plugin settings."
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }

                    Loader {
                        id: providerLoader
                        width: pageFlick.width
                        readonly property real loadedHeight:
                            item ? item.preferredHeight : 0
                        height: loadedHeight
                        active: root.currentTab !== 0
                        visible: active
                        source: Qt.resolvedUrl("UsageProviderPage.qml")
                    }

                    Binding {
                        target: providerLoader.item
                        when: providerLoader.item !== null
                        property: "providerKey"
                        value: root.activeProvider
                    }
                    Binding {
                        target: providerLoader.item
                        when: providerLoader.item !== null
                        property: "providerName"
                        value: root.activeProvider === "claude" ? "Claude" : "Codex"
                    }
                    Binding {
                        target: providerLoader.item
                        when: providerLoader.item !== null
                        property: "providerIcon"
                        value: Qt.resolvedUrl(root.activeProvider === "claude"
                                              ? "assets/claude.svg" : "assets/codex.svg")
                    }
                    Binding {
                        target: providerLoader.item
                        when: providerLoader.item !== null
                        property: "providerColor"
                        value: root.activeProvider === "claude" ? Theme.primary : Theme.tertiary
                    }
                    Binding {
                        target: providerLoader.item
                        when: providerLoader.item !== null
                        property: "plan"
                        value: root.activeProvider === "codex"
                               ? (root.usageData?.codex?.plan ?? "") : ""
                    }
                    Binding {
                        target: providerLoader.item
                        when: providerLoader.item !== null
                        property: "freshness"
                        value: root.freshness(root.activeProvider === "claude"
                                              ? root.usageData?.claude
                                              : root.usageData?.codex)
                    }
                    Binding {
                        target: providerLoader.item
                        when: providerLoader.item !== null
                        property: "limits"
                        value: root.activeProvider === "claude"
                               ? root.claudeLimits : root.codexLimits
                    }
                    Binding {
                        target: providerLoader.item
                        when: providerLoader.item !== null
                        property: "history"
                        value: root.usageData
                               ? root.usageData.historyFor(root.activeProvider) : null
                    }
                    Binding {
                        target: providerLoader.item
                        when: providerLoader.item !== null
                        property: "historyLoading"
                        value: root.usageData
                               ? root.usageData.historyLoading(root.activeProvider) : false
                    }
                    Binding {
                        target: providerLoader.item
                        when: providerLoader.item !== null
                        property: "historyFailed"
                        value: root.usageData
                               ? root.usageData.historyFailed(root.activeProvider) : false
                    }
                    Binding {
                        target: providerLoader.item
                        when: providerLoader.item !== null
                        property: "historyStale"
                        value: root.usageData
                               ? root.usageData.historyStale(root.activeProvider) : false
                    }
                    Binding {
                        target: providerLoader.item
                        when: providerLoader.item !== null
                        property: "now"
                        value: root.usageData?.now ?? Math.floor(Date.now() / 1000)
                    }
                }

            }
        }
    }
}
