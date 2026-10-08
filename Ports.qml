import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property bool opened: false
  property string currentTab: "ports"
  property string scriptPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/nimbus.launchpad/list-ports.sh"
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int cardWidth: Math.min(Style.space(840), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(480), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(40), Style.font.body + Style.spacing.rowPaddingX * 2)
  // first-run state from list-ports.sh --setup-status (default "configured" so the panel does not flash)
  property var setup: ({ configured: true, missing: [] })
  property string setupError: ""
  property var startingBackend: ({})
  property var startingFrontend: ({})

  function markStarting(map, path, value) {
    var next = {}
    for (var k in map) next[k] = map[k]
    if (value) next[path] = true
    else delete next[path]
    return next
  }

  function open() {
    root.opened = true
    root.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { root.opened = false }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function refresh() {
    if (!listProc.running) listProc.running = true
    if (!nimbusProc.running) nimbusProc.running = true
    if (!personalProc.running) personalProc.running = true
    if (!setupProc.running) setupProc.running = true
  }

  function saveSetup(nimbusDir, personalDir) {
    root.setupError = ""
    saveProc.command = [root.scriptPath, "--save-config", nimbusDir, personalDir]
    saveProc.running = true
  }

  readonly property var tabs: ["ports", "nimbus", "personal"]
  function nextTab() { root.currentTab = root.tabs[(root.tabs.indexOf(root.currentTab) + 1) % root.tabs.length] }

  function killRow(pid) {
    if (!pid || pid === "-") return
    Quickshell.execDetached(["kill", "-9", pid])
    refreshTimer.restart()
  }

  // Stop a docker container (or the nimbus-shared stack) that owns a port
  function stopTarget(target) {
    if (!target) return
    Quickshell.execDetached([root.scriptPath, "--stop", target])
    refreshTimer.restart()
  }

  // Cancel button for a service still in the "Starting…" stage: no bound-port
  // pid exists yet to kill, so instead kill the whole process group recorded
  // in the .pid file the --background launch wrote (see list-ports.sh).
  function cancelStarting(path, service) {
    var pidFile = root.logDir + "/" + path.split("/").pop() + "-" + service + ".pid"
    Quickshell.execDetached(["sh", "-c",
      "p=$(cat \"$1\" 2>/dev/null); [ -n \"$p\" ] || exit 0; kill -TERM -\"$p\" 2>/dev/null; sleep 1; kill -9 -\"$p\" 2>/dev/null; true",
      "cancel", pidFile])
    if (service === "backend") root.startingBackend = root.markStarting(root.startingBackend, path, false)
    else root.startingFrontend = root.markStarting(root.startingFrontend, path, false)
    refreshTimer.restart()
  }

  // nimbus projects use their own Makefile flow; personal ones start via .devports
  function startArgs(kind, path, service) {
    return kind === "personal"
      ? [root.scriptPath, "--start-personal", path, service]
      : [root.scriptPath, service === "backend" ? "--start-backend" : "--start-frontend", path]
  }

  // starts run in the background; output goes to a log file the Log button tails
  property string logDir: Quickshell.env("HOME") + "/.local/state/nimbus-launchpad/logs"

  function openLog(path, service) {
    var log = root.logDir + "/" + path.split("/").pop() + "-" + service + ".log"
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "sh", "-c",
      "touch \"$1\"; tail -n 300 -f \"$1\"", "tail", log])
  }

  // terminal in <project>/<backend|frontend> (falls back to the project root)
  function openTerminal(path, service) {
    Quickshell.execDetached(["sh", "-c",
      "d=\"$1/$2\"; [ -d \"$d\" ] || d=\"$1\"; exec setsid uwsm-app -- xdg-terminal-exec --dir=\"$d\"",
      "term", path, service])
  }

  function startBackend(path, currentPid, kind) {
    if (currentPid && currentPid !== "-") Quickshell.execDetached(["kill", "-9", currentPid])
    Quickshell.execDetached([root.scriptPath, "--background"].concat(root.startArgs(kind, path, "backend").slice(1)))
    root.startingBackend = root.markStarting(root.startingBackend, path, true)
    refreshTimer.restart()
  }

  function startFrontend(path, currentPid, kind) {
    if (currentPid && currentPid !== "-") Quickshell.execDetached(["kill", "-9", currentPid])
    Quickshell.execDetached([root.scriptPath, "--background"].concat(root.startArgs(kind, path, "frontend").slice(1)))
    root.startingFrontend = root.markStarting(root.startingFrontend, path, true)
    refreshTimer.restart()
  }

  ListModel { id: portModel }
  ListModel { id: nimbusModel }
  ListModel { id: personalModel }

  // the same start/stop bookkeeping for both project lists
  function loadProjects(model, text) {
    model.clear()
    try {
      var rows = JSON.parse(text)
      for (var i = 0; i < rows.length; i++) {
        model.append(rows[i])
        if (rows[i].backendRunning && root.startingBackend[rows[i].path]) {
          root.startingBackend = root.markStarting(root.startingBackend, rows[i].path, false)
        }
        if (rows[i].frontendRunning && root.startingFrontend[rows[i].path]) {
          root.startingFrontend = root.markStarting(root.startingFrontend, rows[i].path, false)
        }
      }
    } catch (e) { /* ignore malformed output */ }
  }

  Process {
    id: listProc
    command: [root.scriptPath, "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        portModel.clear()
        try {
          var rows = JSON.parse(text)
          for (var i = 0; i < rows.length; i++) portModel.append(rows[i])
        } catch (e) { /* ignore malformed output */ }
      }
    }
  }

  Process {
    id: nimbusProc
    command: [root.scriptPath, "--nimbus-json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadProjects(nimbusModel, text)
    }
  }

  Process {
    id: personalProc
    command: [root.scriptPath, "--personal-json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadProjects(personalModel, text)
    }
  }

  Process {
    id: setupProc
    command: [root.scriptPath, "--setup-status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.setup = JSON.parse(text) } catch (e) { /* ignore malformed output */ }
      }
    }
  }

  Process {
    id: saveProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.setupError = text.trim()
    }
    onExited: root.refresh()
  }

  Timer {
    id: refreshTimer
    interval: 300
    onTriggered: root.refresh()
  }

  // Keeps polling while a backend/frontend refresh-database+start is in flight
  // (that can take a while), so the UI flips from "Starting…" to "Running" on
  // its own instead of only refreshing once, 300ms after the click.
  Timer {
    id: pollTimer
    interval: 1500
    repeat: true
    running: root.opened && (Object.keys(root.startingBackend).length > 0 || Object.keys(root.startingFrontend).length > 0)
    onTriggered: root.refresh()
  }

  // one row per project (Nimbus or personal): status dot, name, backend/frontend start/stop
  Component {
    id: projectRow
    Rectangle {
      required property string name
      required property string path
      required property string kind
      required property bool hasBackend
      required property bool hasFrontend
      required property bool backendRunning
      required property string backendPid
      required property bool frontendRunning
      required property string frontendPid

      width: ListView.view.width
      height: root.rowHeight
      radius: root.cornerRadius
      color: "transparent"

      Row {
        anchors.fill: parent
        anchors.leftMargin: Style.space(4)
        spacing: Style.space(8)

        Rectangle {
          width: Style.space(8)
          height: Style.space(8)
          radius: Style.space(4)
          color: (backendRunning || frontendRunning) ? "#2ecc71" : "#555"
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          width: parent.width * 0.24
          text: name
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          width: Style.space(56)
          text: "Backend"
          color: root.foreground
          opacity: 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          visible: hasBackend
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          text: "Starting…"
          color: "#f1c40f"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          visible: hasBackend && !!root.startingBackend[path] && !backendRunning
          anchors.verticalCenter: parent.verticalCenter
        }

        ServiceButton {
          label: "Start"
          active: hasBackend && !backendRunning
          visible: hasBackend && !root.startingBackend[path]
          color1: "#1e8449"
          color2: "#27ae60"
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.startBackend(path, backendPid, kind)
        }

        ServiceButton {
          label: root.startingBackend[path] ? "Cancel" : "Stop"
          active: hasBackend && (backendRunning || !!root.startingBackend[path])
          visible: hasBackend
          color1: "#992d22"
          color2: "#c0392b"
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.startingBackend[path] ? root.cancelStarting(path, "backend") : root.killRow(backendPid)
        }

        ServiceButton {
          label: "Log"
          visible: hasBackend
          color1: "#34495e"
          color2: "#4a6278"
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.openLog(path, "backend")
        }

        ServiceButton {
          label: "Term"
          visible: hasBackend
          color1: "#6c3483"
          color2: "#8e44ad"
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.openTerminal(path, "backend")
        }

        Text {
          width: Style.space(56)
          text: "Frontend"
          color: root.foreground
          opacity: 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          visible: hasFrontend
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          text: "Starting…"
          color: "#f1c40f"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          visible: hasFrontend && !!root.startingFrontend[path] && !frontendRunning
          anchors.verticalCenter: parent.verticalCenter
        }

        ServiceButton {
          label: "Start"
          active: hasFrontend && !frontendRunning
          visible: hasFrontend && !root.startingFrontend[path]
          color1: "#1e8449"
          color2: "#27ae60"
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.startFrontend(path, frontendPid, kind)
        }

        ServiceButton {
          label: root.startingFrontend[path] ? "Cancel" : "Stop"
          active: hasFrontend && (frontendRunning || !!root.startingFrontend[path])
          visible: hasFrontend
          color1: "#992d22"
          color2: "#c0392b"
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.startingFrontend[path] ? root.cancelStarting(path, "frontend") : root.killRow(frontendPid)
        }

        ServiceButton {
          label: "Log"
          visible: hasFrontend
          color1: "#34495e"
          color2: "#4a6278"
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.openLog(path, "frontend")
        }

        ServiceButton {
          label: "Term"
          visible: hasFrontend
          color1: "#6c3483"
          color2: "#8e44ad"
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.openTerminal(path, "frontend")
        }
      }
  }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "nimbus-launchpad"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }

    MouseArea { anchors.fill: parent; onClicked: root.close() }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
          else if (event.key === Qt.Key_R) { root.refresh(); event.accepted = true }
          else if (event.key === Qt.Key_Tab) { root.nextTab(); event.accepted = true }
        }

        Column {
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.rightMargin: card.contentRightInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset
          spacing: Style.spacing.md

          Row {
            width: parent.width
            spacing: Style.space(8)

            Rectangle {
              width: Style.space(110)
              height: root.rowHeight * 0.8
              radius: root.cornerRadius
              color: root.currentTab === "ports" ? Color.menu.selectedBackground : "transparent"
              Text {
                anchors.centerIn: parent
                text: "Ports"
                color: root.currentTab === "ports" ? Color.menu.selectedText : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.currentTab = "ports" }
            }

            Rectangle {
              width: Style.space(140)
              height: root.rowHeight * 0.8
              radius: root.cornerRadius
              color: root.currentTab === "nimbus" ? Color.menu.selectedBackground : "transparent"
              Text {
                anchors.centerIn: parent
                text: "Nimbus Projects"
                color: root.currentTab === "nimbus" ? Color.menu.selectedText : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.currentTab = "nimbus" }
            }

            Rectangle {
              width: Style.space(150)
              height: root.rowHeight * 0.8
              radius: root.cornerRadius
              color: root.currentTab === "personal" ? Color.menu.selectedBackground : "transparent"
              Text {
                anchors.centerIn: parent
                text: "Personal Projects"
                color: root.currentTab === "personal" ? Color.menu.selectedText : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.currentTab = "personal" }
            }
          }

          Item {
            width: parent.width
            height: parent.height - root.rowHeight * 0.8 - Style.spacing.md - Style.font.caption - Style.spacing.md
            visible: root.currentTab === "ports"

            Column {
              anchors.fill: parent
              spacing: Style.spacing.md

              Row {
                width: parent.width
                height: root.rowHeight * 0.7
                Text { width: parent.width * 0.15; text: "PORT"; color: root.foreground; opacity: 0.6; font.pixelSize: Style.font.caption; font.family: root.fontFamily }
                Text { width: parent.width * 0.35; text: "PROCESS"; color: root.foreground; opacity: 0.6; font.pixelSize: Style.font.caption; font.family: root.fontFamily }
                Text { width: parent.width * 0.30; text: "PROJECT"; color: root.foreground; opacity: 0.6; font.pixelSize: Style.font.caption; font.family: root.fontFamily }
              }

              ListView {
                width: parent.width
                height: parent.height - root.rowHeight * 0.7 - Style.spacing.md
                clip: true
                model: portModel
                spacing: Style.space(2)

                delegate: Rectangle {
                  required property int port
                  required property string process
                  required property string pid
                  required property string project
                  required property string stop

                  width: ListView.view.width
                  height: root.rowHeight
                  radius: root.cornerRadius
                  color: "transparent"

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(4)
                    spacing: 0

                    Text { width: parent.parent.width * 0.15; text: String(port); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; anchors.verticalCenter: parent.verticalCenter }
                    Text { width: parent.parent.width * 0.35; text: process; opacity: /\((free|down)\)$/.test(process) ? 0.5 : 1; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; elide: Text.ElideRight; anchors.verticalCenter: parent.verticalCenter }
                    Text { width: parent.parent.width * 0.30; text: project; color: root.foreground; opacity: 0.75; font.family: root.fontFamily; font.pixelSize: Style.font.body; elide: Text.ElideRight; anchors.verticalCenter: parent.verticalCenter }

                    Rectangle {
                      width: Style.space(64)
                      height: root.rowHeight * 0.7
                      radius: root.cornerRadius
                      color: killArea.containsMouse ? "#c0392b" : "#992d22"
                      visible: pid !== "-"
                      anchors.verticalCenter: parent.verticalCenter

                      Text {
                        anchors.centerIn: parent
                        text: "Kill"
                        color: "white"
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      MouseArea {
                        id: killArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.killRow(pid)
                      }
                    }

                    Rectangle {
                      width: Style.space(64)
                      height: root.rowHeight * 0.7
                      radius: root.cornerRadius
                      color: stopArea.containsMouse ? "#d68910" : "#b9770e"
                      visible: stop !== "" && pid === "-"
                      anchors.verticalCenter: parent.verticalCenter

                      Text {
                        anchors.centerIn: parent
                        text: "Stop"
                        color: "white"
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      MouseArea {
                        id: stopArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.stopTarget(stop)
                      }
                    }
                  }
                }
              }
            }
          }

          Item {
            width: parent.width
            height: parent.height - root.rowHeight * 0.8 - Style.spacing.md - Style.font.caption - Style.spacing.md
            visible: root.currentTab === "nimbus"

            Column {
              anchors.fill: parent
              spacing: Style.spacing.md

              ListView {
                width: parent.width
                height: parent.height
                clip: true
                visible: root.setup.configured
                model: nimbusModel
                spacing: Style.space(2)

                delegate: projectRow
              }
            }

            // first run: no projects folder configured yet
            Column {
              anchors.centerIn: parent
              width: Math.min(parent.width, Style.space(520))
              spacing: Style.spacing.md
              visible: !root.setup.configured

              Text {
                text: "Set up Nimbus Launchpad"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                width: parent.width
                text: "Which folder contains your Nimbus projects?"
                color: root.foreground
                opacity: 0.7
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Rectangle {
                width: parent.width
                height: root.rowHeight * 0.9
                radius: root.cornerRadius
                color: "transparent"
                border.width: 1
                border.color: nimbusField.activeFocus ? root.foreground : Qt.rgba(1, 1, 1, 0.25)

                TextInput {
                  id: nimbusField
                  anchors.fill: parent
                  anchors.margins: Style.space(6)
                  verticalAlignment: TextInput.AlignVCenter
                  color: root.foreground
                  clip: true
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  Text {
                    visible: nimbusField.text.length === 0
                    anchors.verticalCenter: parent.verticalCenter
                    text: "~/work/Nimbus"
                    color: root.foreground
                    opacity: 0.35
                    font: nimbusField.font
                  }
                }
              }

              Text {
                width: parent.width
                text: "Personal projects folder (optional, projects with a .devports file)"
                color: root.foreground
                opacity: 0.7
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Rectangle {
                width: parent.width
                height: root.rowHeight * 0.9
                radius: root.cornerRadius
                color: "transparent"
                border.width: 1
                border.color: personalField.activeFocus ? root.foreground : Qt.rgba(1, 1, 1, 0.25)

                TextInput {
                  id: personalField
                  anchors.fill: parent
                  anchors.margins: Style.space(6)
                  verticalAlignment: TextInput.AlignVCenter
                  color: root.foreground
                  clip: true
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }

              ServiceButton {
                label: "Save"
                color1: "#1e8449"
                color2: "#27ae60"
                onClicked: root.saveSetup(nimbusField.text.trim(), personalField.text.trim())
              }

              Text {
                width: parent.width
                visible: root.setupError !== ""
                text: root.setupError
                color: "#e74c3c"
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                width: parent.width
                visible: root.setup.missing && root.setup.missing.length > 0
                text: "Missing tools: " + (root.setup.missing || []).join(", ") + " (gh-login = run `gh auth login`)"
                color: "#f1c40f"
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Item {
            width: parent.width
            height: parent.height - root.rowHeight * 0.8 - Style.spacing.md - Style.font.caption - Style.spacing.md
            visible: root.currentTab === "personal"

            ListView {
              anchors.fill: parent
              clip: true
              model: personalModel
              spacing: Style.space(2)
              delegate: projectRow
            }

            Text {
              anchors.centerIn: parent
              visible: personalModel.count === 0
              text: "Set PERSONAL_DIR in ~/.config/nimbus-launchpad/config and add a .devports file to a project in it to list it here"
              color: root.foreground
              opacity: 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            text: "Esc close · Tab switch · R refresh"
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
