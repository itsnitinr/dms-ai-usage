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

    ToggleSetting {
        settingKey: "tintBarIcon"
        label: "Tint the bar icon by usage"
        description: "Amber past 70%, red past 90%. Off keeps the normal bar text color."
        defaultValue: true
    }
}
