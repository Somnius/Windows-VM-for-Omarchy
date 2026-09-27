import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Logic.js" as Logic

Panel {
  id: root
  moduleName: "lef.windows-vm"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  readonly property var barIdentity: hostWidget || root
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool ready: service !== null && service.loaded
  readonly property bool running: ready && service.running
  readonly property bool starting: ready && service.state === "starting"
  readonly property bool busy: ready && service.busy
  readonly property bool canControl: ready && service.installed && !busy
  readonly property var st: ready ? service.stats : Logic.derive(null, null)
  readonly property bool hasTerminal: ready && service.terminalCommand !== ""

  // Restart and shut down need a second click within a few seconds, because
  // they close every app running in Windows.
  property string confirming: ""
  property bool helpOpen: false
  property bool settingsOpen: false
  property bool copied: false

  // Counted by the service; a panel destroyed while open gives its count back.
  property bool counted: false
  function syncCount() {
    if (!service || opened === counted) return
    counted = opened
    service.panelOpened(opened)
  }
  onOpenedChanged: syncCount()
  // The service can be handed over after the panel opened (just after a reload).
  onServiceChanged: syncCount()
  Component.onDestruction: if (counted && service) service.panelOpened(false)

  function open() {
    root.confirming = ""
    controller.show()
  }
  function close() {
    root.confirming = ""
    controller.hide()
  }
  function toggle() { opened ? close() : open() }

  function confirmOrRun(kind) {
    if (!root.canControl || !root.running) return
    if (root.confirming !== kind) {
      root.confirming = kind
      confirmTimer.restart()
      return
    }
    root.confirming = ""
    if (kind === "restart") root.service.restart()
    else root.service.shutdown()
  }

  function showDesktop() {
    if (!root.canControl) return
    var wasOpen = root.service.rdpOpen
    root.service.showRdp()
    if (wasOpen) root.close()
  }

  Timer {
    id: confirmTimer
    interval: 4000
    onTriggered: root.confirming = ""
  }

  Timer {
    id: copiedTimer
    interval: 1500
    onTriggered: root.copied = false
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      ColumnLayout {
        id: content
        anchors.fill: parent
        spacing: Style.space(10)

        PanelHero {
          Layout.fillWidth: true
          title: "Windows VM"
          meta: root.ready ? root.service.summary() : "Checking…"
          detail: root.running && root.service.rdpOpen && root.service.rdpWorkspace !== ""
            ? "RDP window on workspace " + root.service.rdpWorkspace : ""
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.running ? 1 : 0.45
          iconComponent: Component {
            Text {
              text: ""
              textFormat: Text.PlainText
              color: root.running ? Color.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

        // ---- placeholder until the first two readings are in (about a second) ----
        Item {
          id: measuring
          Layout.fillWidth: true
          // Only while the panel is actually open: its timer and animations
          // must not tick in the background.
          visible: root.opened && root.running && !root.service.statsReady
          implicitHeight: skeleton.implicitHeight

          // Rotates while the numbers load; each line is a real step in spirit.
          readonly property var lines: [
            "Taking Windows' pulse…",
            "Counting vCPUs…",
            "Weighing the RAM hostage…",
            "Asking the cgroup nicely…",
            "Listening to the network…"
          ]
          property int line: 0

          Timer {
            interval: 650
            repeat: true
            running: measuring.visible
            onTriggered: measuring.line = (measuring.line + 1) % measuring.lines.length
          }
          onVisibleChanged: if (visible) line = 0

          ColumnLayout {
            id: skeleton
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Style.space(10)

            Repeater {
              model: ["CPU", "Memory", "Disk I/O", "Network"]
              delegate: RowLayout {
                required property string modelData
                required property int index
                Layout.fillWidth: true
                spacing: Style.space(8)

                Text {
                  Layout.preferredWidth: Style.space(58)
                  text: modelData
                  textFormat: Text.PlainText
                  color: root.foreground
                  opacity: 0.4
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                // A skeleton bar that breathes, staggered per row.
                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: Math.max(3, Style.space(4))
                  radius: height / 2
                  color: root.foreground
                  opacity: 0.08

                  SequentialAnimation on opacity {
                    running: measuring.visible
                    loops: Animation.Infinite
                    PauseAnimation { duration: index * 120 }
                    NumberAnimation { to: 0.28; duration: 450; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 0.08; duration: 450; easing.type: Easing.InOutQuad }
                  }
                }
              }
            }
          }

          // The message, centred over the bars in the theme's accent, with a
          // backing so it reads cleanly over them.
          Rectangle {
            anchors.centerIn: parent
            width: message.implicitWidth + Style.space(20)
            height: message.implicitHeight + Style.space(10)
            radius: Style.cornerRadius
            color: Color.background
            border.width: 1
            border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.45)

            Text {
              id: message
              anchors.centerIn: parent
              text: measuring.lines[measuring.line].toUpperCase()
              textFormat: Text.PlainText
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.5
            }
          }
        }

        PanelSeparator {
          Layout.fillWidth: true
          visible: measuring.visible
          foreground: root.foreground
        }

        // ---- live resource use (only while the panel is open and running) ----
        ColumnLayout {
          Layout.fillWidth: true
          visible: root.running && root.service.statsReady
          spacing: Style.space(8)

          MeterRow {
            Layout.fillWidth: true
            label: "CPU"
            value: root.st.cpu
            valueText: Logic.percent(root.st.cpu)
            note: root.st.cpuCores.toFixed(1) + " of " + root.st.vcpus + " vCPUs · "
              + (root.st.cpuHost * 100).toFixed(1) + "% of host (" + root.st.hostCores + " threads)"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Sparkline {
            Layout.fillWidth: true
            series: root.ready ? root.service.cpuHistory : []
            ceiling: 1
            color: Color.accent
          }

          MeterRow {
            Layout.fillWidth: true
            label: "Memory"
            value: root.st.memHost
            valueText: Logic.bytes(root.st.memBytes)
            note: "held on host for a " + Logic.bytes(root.st.ramBytes) + " guest · "
              + Logic.percent(root.st.memHost) + " of host RAM"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          MeterRow {
            Layout.fillWidth: true
            label: "Disk I/O"
            value: root.st.io
            valueText: Logic.rateText(root.st.ioRead + root.st.ioWrite)
            note: "read " + Logic.rateText(root.st.ioRead) + " · write " + Logic.rateText(root.st.ioWrite)
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          MeterRow {
            Layout.fillWidth: true
            visible: root.st.diskSize > 0
            label: "Image"
            value: root.st.diskSize > 0 ? root.st.diskUsed / root.st.diskSize : 0
            valueText: Logic.bytes(root.st.diskUsed)
            note: "allocated of a " + Logic.bytes(root.st.diskSize) + " virtual disk"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
              Layout.preferredWidth: Style.space(58)
              text: "Network"
              textFormat: Text.PlainText
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              Layout.fillWidth: true
              text: "↓ " + Logic.rateText(root.st.netRx) + "   ↑ " + Logic.rateText(root.st.netTx)
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Sparkline {
            Layout.fillWidth: true
            series: root.ready ? root.service.rxHistory : []
            series2: root.ready ? root.service.txHistory : []
            color: Color.accent
            color2: root.foreground
          }

          GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: Style.space(8)
            rowSpacing: Style.space(4)

            Text {
              Layout.preferredWidth: Style.space(58)
              text: "Uptime"
              textFormat: Text.PlainText
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              Layout.fillWidth: true
              text: root.ready ? root.service.uptime : ""
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              Layout.preferredWidth: Style.space(58)
              text: "Container"
              textFormat: Text.PlainText
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              Layout.fillWidth: true
              text: root.copied ? "copied ✓" : root.st.container
              textFormat: Text.PlainText
              color: root.copied ? Color.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.service && root.service.copyContainerId()) {
                  root.copied = true
                  copiedTimer.restart()
                }
              }
            }
          }

          PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }
        }

        // ---- actions ----
        Button {
          Layout.fillWidth: true
          text: root.starting ? "Windows is starting…"
            : !root.running ? "Start Windows"
            : root.service.rdpOpen ? "Show Windows desktop" : "Connect (RDP)"
          iconText: !root.running ? "󰐊" : "󰍹"
          bordered: true
          focusable: true
          enabled: root.canControl && !root.starting
          foreground: root.foreground
          accent: Color.accent
          fontFamily: root.fontFamily
          onClicked: root.showDesktop()
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Button {
            Layout.fillWidth: true
            text: root.confirming === "restart" ? "Click again to restart" : "Restart"
            iconText: "󰜉"
            bordered: true
            focusable: true
            selected: root.confirming === "restart"
            enabled: root.canControl && root.running
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            onClicked: root.confirmOrRun("restart")
          }

          Button {
            Layout.fillWidth: true
            text: root.confirming === "stop" ? "Click again to shut down" : "Shut down"
            iconText: "󰐥"
            bordered: true
            focusable: true
            selected: root.confirming === "stop"
            enabled: root.canControl && root.running
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            onClicked: root.confirmOrRun("stop")
          }
        }

        Text {
          Layout.fillWidth: true
          visible: root.confirming !== ""
          text: "Windows will close all its apps. Save your work in Windows first."
          textFormat: Text.PlainText
          color: Color.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          Layout.fillWidth: true
          visible: root.ready && root.service.lastError !== ""
          text: root.ready ? root.service.lastError : ""
          textFormat: Text.PlainText
          color: Color.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          Layout.fillWidth: true
          visible: root.ready && !root.service.installed
          text: "The Windows VM isn't installed. Set it up with: omarchy-windows-vm install"
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Button {
            Layout.fillWidth: true
            text: "Console"
            iconText: "󰖟"
            tooltipText: "The VM's screen in your browser. Log in with your Windows username and password."
            bordered: true
            enabled: root.running || root.starting
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            onClicked: { root.service.openWebConsole(); root.close() }
          }

          Button {
            Layout.fillWidth: true
            text: "Shared"
            iconText: "󰉋"
            tooltipText: "Open ~/Windows, which Windows sees as \\\\host.lan\\Data"
            bordered: true
            enabled: root.ready
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            onClicked: { root.service.openShared(); root.close() }
          }

          Button {
            Layout.fillWidth: true
            visible: root.hasTerminal
            text: "Terminal"
            iconText: "\uf120"
            tooltipText: root.ready ? "Runs: " + root.service.terminalCommand : ""
            bordered: true
            enabled: root.running
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            onClicked: { root.service.openTerminal(); root.close() }
          }

          Button {
            Layout.fillWidth: true
            visible: root.ready && root.service.hasLazydocker
            text: "Docker"
            iconText: "\ue7b0"
            tooltipText: "Open lazydocker to inspect the container"
            bordered: true
            enabled: root.ready
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            onClicked: { root.service.openLazydocker(); root.close() }
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Button {
            Layout.fillWidth: true
            text: "Logs"
            iconText: "󰈙"
            tooltipText: "Each start and connection, including why RDP sessions ended"
            bordered: true
            enabled: root.ready
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            onClicked: { root.service.openLogs(); root.close() }
          }

          Button {
            Layout.fillWidth: true
            text: "Settings"
            iconText: "󰒓"
            bordered: true
            selected: root.settingsOpen
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            onClicked: root.settingsOpen = !root.settingsOpen
          }

          Button {
            Layout.fillWidth: true
            text: "Help"
            iconText: "󰋖"
            bordered: true
            selected: root.helpOpen
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            onClicked: root.helpOpen = !root.helpOpen
          }
        }

        // ---- settings ----
        ColumnLayout {
          Layout.fillWidth: true
          visible: root.settingsOpen
          spacing: Style.space(8)

          Toggle {
            Layout.fillWidth: true
            label: "Keep Windows running"
            description: "Closing the RDP window no longer shuts Windows down. Applies from the next start."
            checked: root.ready && root.service.keepAlive
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            enabled: root.ready
            onClicked: root.service.setKeepAlive(!root.service.keepAlive)
          }

          Text {
            Layout.fillWidth: true
            visible: root.ready && root.service.keepAlive
            text: "Heads-up: Windows stays on, holding "
              + (root.ready && root.service.ramSize !== "" ? "its " + root.service.ramSize + " of RAM" : "all of its RAM")
              + " hostage, even with no RDP window open, until you press Shut down here or shut it down from Windows."
            textFormat: Text.PlainText
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Toggle {
            Layout.fillWidth: true
            label: "Hide icon while stopped"
            description: "Show the bar icon only while Windows is running."
            checked: root.ready && root.service.hideWhenStopped
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            enabled: root.ready
            onClicked: root.service.setHideWhenStopped(!root.service.hideWhenStopped)
          }

          Text {
            Layout.fillWidth: true
            text: "Terminal button: set \"terminalCommand\" (e.g. \"ssh winvm\") in ~/.config/omarchy/windows-vm/config.json."
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ---- help ----
        ColumnLayout {
          Layout.fillWidth: true
          visible: root.helpOpen
          spacing: Style.space(6)

          Repeater {
            model: [
              "The icon is bright while Windows runs, dim when it's stopped, and pulses while it starts or shuts down. Hover it for its status.",
              "The numbers and graphs here are only gathered while this panel is open. Closed, the plugin just checks every 5 seconds whether Windows is running, so it costs your machine nothing.",
              "Left-click the icon for this panel. Right-click goes straight to the Windows desktop.",
              "Connect opens a new RDP window to the running Windows, without a password prompt. Closing that window never stops Windows.",
              "RDP windows opened here reconnect by themselves if the connection drops, instead of closing.",
              "With \"Keep Windows running\" on (Settings), closing the RDP window only closes the window: your apps, SSH and background jobs keep going. Connect again any time.",
              "Restart and Shut down ask for a second click, because Windows closes every app. Shutting down from Windows' Start menu works too.",
              "Console shows the VM's screen in the browser, handy while Windows boots. It asks for your Windows username and password (Omarchy turns that protection on). Shared opens ~/Windows. Docker opens lazydocker, when it's installed.",
              "Memory is what the VM holds on this machine: Windows claims its RAM at boot, whatever Task Manager says."
            ]
            delegate: Text {
              required property string modelData
              Layout.fillWidth: true
              text: "• " + modelData
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Button {
            Layout.fillWidth: true
            text: "Source code · MIT · credits"
            bordered: true
            enabled: root.service !== null
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            onClicked: if (root.service) Qt.openUrlExternally(root.service.repoUrl + "#credits")
          }
        }
      }
    }
  }
}
