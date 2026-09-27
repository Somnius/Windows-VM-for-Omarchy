import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

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
  readonly property bool busy: ready && service.busy
  readonly property bool canControl: ready && service.installed && !busy

  // Restart and shut down need a second click within a few seconds, because
  // they close every app running in Windows.
  property string confirming: ""
  property bool helpOpen: false

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
    if (root.confirming !== kind) {
      root.confirming = kind
      confirmTimer.restart()
      return
    }
    root.confirming = ""
    if (kind === "restart") root.service.restart()
    else root.service.shutdown()
  }

  Timer {
    id: confirmTimer
    interval: 4000
    onTriggered: root.confirming = ""
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      ColumnLayout {
        id: content
        anchors.fill: parent
        spacing: Style.space(12)

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
              text: "\uf17a"
              textFormat: Text.PlainText
              color: root.running ? Color.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

        Button {
          Layout.fillWidth: true
          text: !root.running ? "Start Windows"
            : root.service.rdpOpen ? "Show Windows desktop" : "Reconnect RDP"
          iconText: !root.running ? "󰐊" : "󰍹"
          bordered: true
          focusable: true
          enabled: root.canControl
          foreground: root.foreground
          accent: Color.accent
          fontFamily: root.fontFamily
          onClicked: {
            root.service.showRdp()
            if (root.service.rdpOpen) root.close()
          }
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

        Text {
          Layout.fillWidth: true
          visible: root.ready && root.service.detail !== ""
            && (root.service.state === "no-access" || root.service.state === "docker-down" || root.service.state === "error")
          text: root.ready ? root.service.detail : ""
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Button {
            Layout.fillWidth: true
            text: "Web console"
            iconText: "󰖟"
            bordered: true
            focusable: true
            enabled: root.running
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            onClicked: { root.service.openWebConsole(); root.close() }
          }

          Button {
            Layout.fillWidth: true
            text: "Logs"
            iconText: "󰈙"
            bordered: true
            focusable: true
            enabled: root.ready
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            onClicked: { root.service.openLogs(); root.close() }
          }

          Button {
            Layout.fillWidth: true
            text: root.helpOpen ? "Hide help" : "Help"
            iconText: "󰋖"
            bordered: true
            focusable: true
            selected: root.helpOpen
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            onClicked: root.helpOpen = !root.helpOpen
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          visible: root.helpOpen
          spacing: Style.space(6)

          PanelSectionHeader {
            Layout.fillWidth: true
            text: "HOW IT WORKS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: [
              "The icon is bright while Windows runs, dim when it's stopped, and pulses while it starts or shuts down.",
              "Left-click the icon for this panel. Right-click jumps straight to the Windows desktop.",
              "By default, closing the RDP window shuts Windows down, like Omarchy's own launcher. Turn on \"Keep Windows running\" below to only close the window. Windows then keeps your apps, SSH and background jobs going until you shut it down.",
              "Restart and Shut down ask for a second click, because Windows closes every app. Shutting down from Windows' own Start menu works too.",
              "Web console opens the VM's screen in the browser, which is useful while Windows boots or if RDP won't connect.",
              "Logs holds each start's output, including why an RDP session ended.",
              "Everything goes through Omarchy's own omarchy-windows-vm command. Docker access may ask for your password."
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
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

        Toggle {
          Layout.fillWidth: true
          label: "Keep Windows running"
          description: "Closing or losing the RDP window no longer shuts Windows down. Applies from the next start."
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
            + (root.service && root.service.ramSize !== "" ? "its " + root.service.ramSize + " of RAM" : "all of its RAM")
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

        Button {
          Layout.fillWidth: true
          text: "Source code · MIT license"
          bordered: true
          focusable: true
          enabled: root.service !== null
          foreground: root.foreground
          accent: Color.accent
          fontFamily: root.fontFamily
          onClicked: if (root.service) Qt.openUrlExternally(root.service.repoUrl)
        }
      }
    }
  }
}
