import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// Loads the stage layout into the running Hyprland while the plugin is
// enabled. Nothing is written to your Hyprland config; see
// hypr/stage-service.sh for what each step does.
Item {
    id: root

    readonly property string script: decodeURIComponent(Qt.resolvedUrl("hypr/stage-service.sh").toString().replace(/^file:\/\//, ""))

    Process {
        id: start
        command: ["bash", root.script, "start"]
    }

    Process {
        id: load
        command: ["bash", root.script, "load"]
    }

    // A config reload (save, `hyprctl reload`, `omarchy refresh`) starts a
    // fresh Lua state without stage; load it again once the reload settles.
    Timer {
        id: reloadDebounce
        interval: 150
        onTriggered: load.running = true
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "configreloaded")
                reloadDebounce.restart();
        }
    }

    Component.onCompleted: start.running = true

    // Disabled, removed or the shell restarting: drop the layout. A restarting
    // shell loads it again right away.
    Component.onDestruction: Quickshell.execDetached(["bash", root.script, "stop"])
}
