// Compact 24-hour usage chart for one provider.
import QtQuick
import qs.Common
import qs.Widgets

Column {
    id: root

    property var buckets: []            // [{start, tokens}], oldest first
    property color barColor: Theme.primary
    property int hovered: -1

    readonly property int count: buckets.length
    readonly property real peak: {
        let value = 0
        for (let i = 0; i < buckets.length; i++)
            value = Math.max(value, buckets[i].tokens || 0)
        return value
    }
    readonly property real total: {
        let value = 0
        for (let i = 0; i < buckets.length; i++)
            value += buckets[i].tokens || 0
        return value
    }
    readonly property int chartHeight: 52
    readonly property int barGap: 2

    // The chart is built empty and populated a moment later, so the first real
    // data must land at its final height. Animating that transition is what
    // makes a tab switch flash: the Repeater builds its delegates before `peak`
    // has caught up with the new buckets, and the bars animate in from the
    // height that stale scale implied. Later refreshes still animate.
    property bool barsSettled: false
    readonly property real barWidth:
        Math.max(1, (width - barGap * Math.max(0, count - 1)) / Math.max(1, count))

    spacing: Theme.spacingS

    // Reads buckets.length rather than `count`: derived bindings have not
    // necessarily re-evaluated yet when this handler runs, which is the same
    // staleness that produced the flash in the first place.
    onBucketsChanged: {
        if (buckets.length > 0 && !barsSettled)
            Qt.callLater(function () { root.barsSettled = true })
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

    function hourLabel(start) {
        const d = new Date(start * 1000)
        return String(d.getHours()).padStart(2, "0") + ":00"
    }

    Item {
        width: parent.width
        height: caption.implicitHeight

        StyledText {
            id: caption
            anchors.left: parent.left
            text: root.hovered >= 0
                  ? root.hourLabel(root.buckets[root.hovered].start)
                  : "Last 24 hours"
            color: Theme.surfaceTextMedium
            font.pixelSize: Theme.fontSizeSmall
        }

        StyledText {
            anchors.right: parent.right
            text: root.hovered >= 0
                  ? root.formatTokens(root.buckets[root.hovered].tokens || 0)
                  : root.formatTokens(root.total) + " total"
            color: Theme.surfaceText
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
        }
    }

    Item {
        id: plot
        width: parent.width
        height: root.chartHeight

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: Theme.outlineLight
        }

        Row {
            anchors.fill: parent
            spacing: root.barGap

            Repeater {
                model: root.buckets

                delegate: Item {
                    required property var modelData
                    required property int index

                    readonly property real value: modelData.tokens || 0
                    width: root.barWidth
                    height: root.chartHeight

                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        // A non-positive peak means the scale has not caught up
                        // with the data yet; dividing by a floor of 1 there turns
                        // a raw token count into a bar height of millions.
                        // Clamping keeps a stale scale inside the plot regardless.
                        height: (value <= 0 || root.peak <= 0)
                                ? 0
                                : Math.max(2, Math.min(parent.height,
                                                       value / root.peak * parent.height))
                        radius: Math.min(2, width / 2)
                        color: root.barColor
                        opacity: root.hovered < 0 || root.hovered === index ? 1 : 0.35

                        Behavior on height {
                            enabled: root.barsSettled
                            NumberAnimation { duration: Theme.shortDuration; easing.type: Easing.OutCubic }
                        }
                        Behavior on opacity {
                            NumberAnimation { duration: Theme.shortDuration }
                        }
                    }
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true

            function pick(x) {
                if (root.count <= 0)
                    return -1
                const i = Math.floor(x / (root.barWidth + root.barGap))
                return Math.max(0, Math.min(root.count - 1, i))
            }

            onPositionChanged: mouse => root.hovered = pick(mouse.x)
            onEntered: root.hovered = pick(mouseX)
            onExited: root.hovered = -1
        }
    }

    Item {
        width: parent.width
        height: axisStart.implicitHeight

        StyledText {
            id: axisStart
            anchors.left: parent.left
            text: root.count > 0 ? root.hourLabel(root.buckets[0].start) : ""
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
        }
        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.count > 0
                  ? root.hourLabel(root.buckets[Math.floor(root.count / 2)].start)
                  : ""
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
        }
        StyledText {
            anchors.right: parent.right
            text: "now"
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
        }
    }
}
