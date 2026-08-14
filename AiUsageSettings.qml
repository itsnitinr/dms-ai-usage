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
}
