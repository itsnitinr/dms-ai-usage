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
    // "icon" | "iconValue" | "value"
    readonly property string barDisplay: pluginData.barDisplay || "icon"
    readonly property bool showBarIcon: barDisplay !== "value"
    readonly property bool showBarValue: barDisplay !== "icon"
    readonly property bool tintBarIcon: pluginData.tintBarIcon !== false
    // Off by default: credits are money rather than a window that reopens, and
    // an amber bar that cannot be waited out is a different message from the one
    // this tint has meant until now. Opt in to fold them together.
    readonly property bool tintOnSpend: pluginData.tintOnSpend === true
    readonly property bool notifyThresholds: pluginData.notifyThresholds !== false
    readonly property real contentPadding: Theme.spacingS

    property int currentTab: 0            // Overview, Codex, Claude
    readonly property string activeProvider:
        currentTab === 1 ? "codex" : currentTab === 2 ? "claude" : ""

    // URL loading bypasses Qt's cached same-directory type table during an
    // in-place plugin upgrade. It does not, on its own, survive one: the engine
    // caches compiled components by URL, and PluginService busts that cache only
    // on the plugin's own surface URLs (a `?t=` it appends in loadPlugin), so a
    // nested URL load keeps serving the copy compiled before the edit. This root
    // is rebuilt once per load, which makes a timestamp captured here a fresh
    // token exactly once per `plugins reload` — every file below is recompiled,
    // with no per-file revision constant to remember to bump.
    readonly property string reloadToken: "?r=" + Date.now()

    Loader {
        id: dataLoader
        source: Qt.resolvedUrl("AiUsageData.qml" + root.reloadToken)
    }
    readonly property var usageData: dataLoader.item
    Binding {
        target: dataLoader.item
        when: dataLoader.item !== null
        property: "activeProvider"
        value: root.activeProvider
    }
    Binding {
        target: dataLoader.item
        when: dataLoader.item !== null
        property: "notifyThresholds"
        value: root.notifyThresholds
    }
    Binding {
        target: dataLoader.item
        when: dataLoader.item !== null
        property: "warnPct"
        value: root.warnPct
    }
    Binding {
        target: dataLoader.item
        when: dataLoader.item !== null
        property: "critPct"
        value: root.critPct
    }

    readonly property bool hasData: usageData?.hasData ?? false
    readonly property bool fetchedOnce: usageData?.fetchedOnce ?? false

    // A machine that has never signed into either CLI has nothing to say, and a
    // permanently dimmed icon says it badly. Collapse out of the bar instead,
    // and come back on the first fetch that finds something. Staying put until
    // that first fetch completes avoids flashing the pill away on every shell
    // start. fetch-usage.sh carries a failed provider forward for an hour, so
    // this waits out a transient outage rather than reacting to one.
    //
    // An expired token is the exception, and the reason is circular: it is the
    // one empty state that comes with an explanation and a fix, and collapsing
    // the pill takes away the only way to reach either. A Claude-only machine
    // would otherwise lose the widget an hour after the token lapsed, with
    // nothing on screen connecting that to the session it needs to start.
    readonly property bool claudeTokenExpired:
        showClaude && (usageData?.claudeAuth ?? "ok") === "expired"
    readonly property bool nothingToShow: fetchedOnce && !hasData && !claudeTokenExpired
    onNothingToShowChanged: setVisibilityOverride(!nothingToShow)
    readonly property int tick: usageData?.now ?? Math.floor(Date.now() / 1000)

    function countdown(reset) { return usageData ? usageData.countdown(reset) : "" }
    function resetLabel(reset) { return usageData ? usageData.resetLabel(reset) : "" }
    function resetTime(reset) { return usageData ? usageData.resetTime(reset) : "" }
    function minutesSince(ts) { return usageData ? usageData.minutesSince(ts) : -1 }
    function freshness(snapshot) { return usageData ? usageData.freshness(snapshot) : "" }
    function authLabel(provider) { return usageData ? usageData.authLabel(provider) : "" }
    function authNote(provider) { return usageData ? usageData.authNote(provider) : "" }
    function spendAmount(spend) { return usageData ? usageData.spendAmount(spend) : "" }
    function refresh() { if (usageData) usageData.refresh() }

    readonly property var codexLimits: usageData?.codex?.limits ?? []
    readonly property var claudeLimits: usageData?.claude?.limits ?? []
    readonly property bool showCodexLimits: showCodex && codexLimits.length > 0
    readonly property bool showClaudeLimits: showClaude && claudeLimits.length > 0
    // Null unless the account has overage credits switched on.
    readonly property var claudeSpend: showClaude ? (usageData?.claude?.spend ?? null) : null
    // Credits arrive in the same entry as the limits, so in practice they show
    // up together — but the section is worth drawing for either one alone
    // rather than letting the amount vanish with the windows.
    readonly property bool showClaudeSection: showClaudeLimits || claudeSpend !== null
    readonly property int visibleProviderCount:
        (showCodexLimits ? 1 : 0) + (showClaudeSection ? 1 : 0)
    // Empty unless Claude's sign-in is what is missing, and empty while Claude
    // is switched off — a provider nobody asked to see owes no explanation.
    readonly property string claudeAuthNote: showClaude ? authNote("claude") : ""

    function usageColor(pct) {
        return pct >= critPct ? Theme.error : pct >= warnPct ? Theme.warning : Theme.primary
    }

    function maxPct() {
        let maximum = -1
        const limits = codexLimits.concat(claudeLimits)
        for (let i = 0; i < limits.length; i++)
            maximum = Math.max(maximum, limits[i].pct)
        // An uncapped credit balance has no percentage to contribute: pct is 0
        // there, which would not raise the maximum anyway.
        if (tintOnSpend && claudeSpend)
            maximum = Math.max(maximum, claudeSpend.limit_reached ? 100 : claudeSpend.pct)
        return maximum
    }

    // The number in the bar reads the same maximum the tint does, so the digits
    // and the color can never disagree about how bad things are. A bar too
    // narrow for a percent sign — every vertical one — drops it and keeps the
    // digits, which are the part worth reading.
    function barValue(withSign) {
        const maximum = maxPct()
        if (maximum < 0)
            return "—"
        return withSign ? maximum + "%" : String(maximum)
    }

    function worstLimit(limits) {
        let worst = null
        for (let i = 0; i < limits.length; i++)
            if (!worst || limits[i].pct > worst.pct)
                worst = limits[i]
        return worst
    }

    // One line, because DankTooltip is one line: it clamps at 300px and elides
    // whatever runs past. So the long form — which names the window each number
    // belongs to — gives way to a short one rather than letting an ellipsis eat
    // whichever provider happens to sit last. The pill says how bad it is; this
    // says which of them is that bad; the popout has the rest.
    function tooltipText() {
        const parts = []
        const brief = []

        function add(long, short) {
            parts.push(long)
            brief.push(short)
        }

        if (showCodex) {
            const worst = worstLimit(codexLimits)
            if (worst)
                add("Codex " + worst.label + " " + worst.pct + "%",
                    "Codex " + worst.pct + "%")
        }
        if (showClaude) {
            const worst = worstLimit(claudeLimits)
            if (worst)
                add("Claude " + worst.label + " " + worst.pct + "%",
                    "Claude " + worst.pct + "%")
            else if (authLabel("claude"))
                add("Claude " + authLabel("claude"), "Claude " + authLabel("claude"))
            if (claudeSpend) {
                const credits = "Credits "
                              + (claudeSpend.limit_reached ? "spent" : claudeSpend.pct + "%")
                add(credits, credits)
            }
        }

        if (parts.length === 0)
            return fetchedOnce ? "No live limits" : "Loading live limits…"
        const full = parts.join(" · ")
        return fitsTooltip(full) ? full : brief.join(" · ")
    }

    // Whether DankTooltip can show a line whole. It sizes itself to the text and
    // then clamps at 300px, padding included, so this measures rather than
    // counting characters: font scale is a user setting, and a line that fits at
    // 12px does not at 15.
    StyledText {
        id: tooltipRuler
        visible: false
        font.pixelSize: Theme.fontSizeSmall
    }

    function fitsTooltip(text) {
        tooltipRuler.text = text
        return tooltipRuler.implicitWidth <= 300 - Theme.spacingM * 2
    }

    // Off means off: the icon sits at the ordinary bar text color whatever the
    // numbers say, including the dim "nothing fetched yet" shade, so it is
    // indistinguishable from every other widget in the bar.
    function pillColor() {
        if (!tintBarIcon)
            return Theme.surfaceText
        const maximum = maxPct()
        if (maximum < 0)
            return Theme.surfaceTextMedium
        return maximum >= critPct ? Theme.error
             : maximum >= warnPct ? Theme.warning : Theme.surfaceText
    }

    // Credits sit below the windows they back up: the meters above say when
    // Claude stops, this one says what it costs to carry on past that. Declared
    // ahead of OverviewLimits, which uses it.
    component SpendMeter: Column {
        id: spendMeter

        required property var spend
        required property color accent

        // Without a cap there is no fraction to draw, so the meter and the
        // percentage both drop and the amount speaks for itself.
        readonly property bool capped: (spend?.limit_minor ?? 0) > 0
        readonly property bool reached: spend?.limit_reached ?? false
        readonly property color meterColor: reached ? Theme.error : accent

        width: parent?.width ?? 0
        visible: spend !== null
        spacing: Theme.spacingXXS

        Item {
            width: parent.width
            height: creditsLabel.implicitHeight

            StyledText {
                id: creditsLabel
                anchors.left: parent.left
                text: "Credits"
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
            }
            StyledText {
                anchors.right: parent.right
                visible: spendMeter.capped
                text: (spendMeter.spend?.pct ?? 0) + "% used"
                color: spendMeter.meterColor
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
            }
        }

        Rectangle {
            width: parent.width
            height: 5
            radius: height / 2
            visible: spendMeter.capped
            color: Theme.surfaceVariant

            Rectangle {
                width: parent.width * Math.max(0, Math.min(1, (spendMeter.spend?.pct ?? 0) / 100))
                height: parent.height
                radius: parent.radius
                color: spendMeter.meterColor

                Behavior on width {
                    NumberAnimation { duration: Theme.shortDuration; easing.type: Easing.OutCubic }
                }
            }
        }

        Item {
            width: parent.width
            height: creditsAmount.implicitHeight

            StyledText {
                id: creditsAmount
                anchors.left: parent.left
                text: root.spendAmount(spendMeter.spend)
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
            }
            StyledText {
                anchors.right: parent.right
                visible: spendMeter.reached
                text: "Limit reached"
                color: Theme.error
                font.pixelSize: Theme.fontSizeSmall
            }
        }
    }

    component OverviewLimits: Column {
        id: overviewLimits

        required property string providerName
        required property url providerIcon
        required property color providerColor
        required property var limits
        property var spend: null
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
                            readonly property int t: root.tick
                            anchors.right: parent.right
                            text: root.resetTime(modelData.resets_at)
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }
                }
            }

            SpendMeter {
                spend: overviewLimits.spend
                accent: root.usageColor(overviewLimits.spend?.pct ?? 0)
            }
        }
    }

    pillRightClickAction: function () { root.refresh() }

    // Content only — BasePill draws the background, owns click and ripple, and
    // sizes itself from this item's implicit size, which is why the layout below
    // hands its own implicit size up rather than filling anything.
    component BarPill: Item {
        id: barPill

        property bool vertical: false

        // The popout says everything the tooltip does and says it better, so
        // while it is open the tooltip stays out of the way. This also covers
        // bars configured to open popouts on hover, where the two would
        // otherwise appear together on the same gesture.
        readonly property bool wantsTooltip:
            hover.hovered && !(root.usageData?.popoutVisible ?? false)

        implicitWidth: layout.implicitWidth
        implicitHeight: layout.implicitHeight

        Grid {
            id: layout

            anchors.centerIn: parent
            columns: barPill.vertical ? 1 : 2
            spacing: barPill.vertical ? 0 : Theme.spacingXXS
            horizontalItemAlignment: Grid.AlignHCenter
            verticalItemAlignment: Grid.AlignVCenter

            DankIcon {
                name: "insights"
                size: root.iconSize
                color: root.pillColor()
                visible: root.showBarIcon
            }

            StyledText {
                text: root.barValue(!barPill.vertical)
                visible: root.showBarValue
                color: root.pillColor()
                font.pixelSize: barPill.vertical ? Theme.fontSizeSmall - 1
                                                 : Theme.fontSizeSmall
                font.weight: Font.Medium
            }
        }

        // Not a MouseArea: BasePill's own sits behind this content and owns the
        // click, and a hover-only handler has no business competing for it.
        HoverHandler {
            id: hover
        }

        Loader {
            id: tooltipLoader
            active: false
            sourceComponent: DankTooltip {}
        }

        onWantsTooltipChanged: wantsTooltip ? showTooltip() : hideTooltip()

        // DankTooltip is a layer-shell window placed in screen coordinates, so
        // it has to be told where the bar edge is; the arithmetic here is the
        // same one every built-in bar widget does. See DiskUsage.qml.
        function showTooltip() {
            const screen = root.parentScreen
            if (!screen)
                return

            tooltipLoader.active = true
            if (!tooltipLoader.item)
                return

            const edge = root.axis?.edge ?? "top"
            const text = root.tooltipText()

            if (barPill.vertical) {
                const left = edge === "left"
                const x = left
                    ? root.barThickness + root.barSpacing + Theme.spacingXS
                    : screen.width - root.barThickness - root.barSpacing - Theme.spacingXS
                // A bar on a screen stacked below another reports window
                // coordinates that leave out its own thickness. Auto-hide bars
                // do not, since they are not reserving space to begin with.
                const autoHide = root.barConfig?.autoHide ?? false
                const offset = (!autoHide && screen.y > 0)
                    ? root.barThickness + (root.barConfig?.spacing ?? 4) : 0
                const at = barPill.mapToItem(null, barPill.width / 2, barPill.height / 2)
                tooltipLoader.item.show(text, x, at.y + offset, screen, left, !left)
            } else {
                const height = Theme.fontSizeSmall * 1.5 + Theme.spacingS * 2
                const y = edge === "bottom"
                    ? screen.height - root.barThickness - root.barSpacing
                      - Theme.spacingXS - height
                    : root.barThickness + root.barSpacing + Theme.spacingXS
                const at = barPill.mapToItem(null, barPill.width / 2, 0)
                tooltipLoader.item.show(text, at.x, y, screen, false, false)
            }
        }

        function hideTooltip() {
            if (tooltipLoader.item)
                tooltipLoader.item.hide()
            tooltipLoader.active = false
        }
    }

    horizontalBarPill: Component {
        BarPill {}
    }

    verticalBarPill: Component {
        BarPill { vertical: true }
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
                            visible: root.showClaudeSection
                            first: !root.showCodexLimits
                            providerName: "Claude"
                            providerIcon: Qt.resolvedUrl("assets/claude.svg")
                            providerColor: Theme.primary
                            freshness: root.freshness(root.usageData?.claude)
                            limits: root.claudeLimits
                            spend: root.claudeSpend
                        }

                        StyledText {
                            width: parent.width
                            visible: root.claudeAuthNote.length > 0
                            wrapMode: Text.WordWrap
                            text: root.claudeAuthNote
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                        }

                        StyledText {
                            width: parent.width
                            // Yields to the note above, which says the same
                            // thing about Claude and says it precisely.
                            visible: !root.hasData && root.claudeAuthNote.length === 0
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
                        source: Qt.resolvedUrl("UsageProviderPage.qml" + root.reloadToken)
                    }

                    Binding {
                        target: providerLoader.item
                        when: providerLoader.item !== null
                        property: "reloadToken"
                        value: root.reloadToken
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
                        property: "authLabel"
                        value: root.authLabel(root.activeProvider)
                    }
                    Binding {
                        target: providerLoader.item
                        when: providerLoader.item !== null
                        property: "authNote"
                        value: root.authNote(root.activeProvider)
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
                        property: "spend"
                        value: root.activeProvider === "claude" ? root.claudeSpend : null
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
