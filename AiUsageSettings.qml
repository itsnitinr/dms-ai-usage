import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    pluginId: "aiUsage"

    ToggleSetting {
        settingKey: "showClaude"
        label: "Show Claude Code"
        description: "5-hour and weekly subscription limits"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showCodex"
        label: "Show Codex"
        description: "Live subscription limits from Codex App Server"
        defaultValue: true
    }

    SelectionSetting {
        settingKey: "barDisplay"
        label: "Bar pill contents"
        description: "The percentage shown is the highest across everything enabled"
        defaultValue: "icon"
        options: [
            {"label": "Icon only", "value": "icon"},
            {"label": "Icon and percentage", "value": "iconValue"},
            {"label": "Percentage only", "value": "value"}
        ]
    }

    ToggleSetting {
        settingKey: "tintBarIcon"
        label: "Tint the bar icon by usage"
        description: "Amber past 70%, red past 90%. Off keeps the normal bar text color."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "notifyThresholds"
        label: "Notify at usage thresholds"
        description: "Once per window as a limit passes 70%, again at 90%"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "tintOnSpend"
        label: "Count credit spend in the bar tint"
        description: "Let Claude usage credits warn the bar too, not just rate limits"
        defaultValue: false
    }
}
