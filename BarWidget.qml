import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "lef.windows-vm"

  readonly property var service: bar && bar.shell
    ? bar.shell.serviceFor(root.moduleName) : null
  readonly property bool ready: service !== null && service.loaded
  readonly property bool running: ready && service.running
  readonly property bool busy: ready && (service.busy || service.state === "starting")
  readonly property bool hidden: ready && service.hideWhenStopped && !running && !busy

  property bool hovered: false
  // Destroyed mid-hover (bar reload): release the hover.
  Component.onDestruction: if (hovered && service) service.hoverChanged(false)
  readonly property string tip: ready ? service.summaryText : "Windows VM"
  // Keep an open tooltip current, e.g. once the RDP window check comes back.
  onTipChanged: if (hovered && bar) bar.showTooltip(root, tip)

  visible: !hidden
  implicitWidth: hidden ? 0 : glyph.implicitWidth + Style.space(12)
  implicitHeight: barSize

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.anchorItem = root
    target.hostWidget = root
    target.service = root.service
  }

  onBarChanged: injectPanel()
  onServiceChanged: injectPanel()

  Text {
    id: glyph
    anchors.centerIn: parent
    text: "\uf17a"   // Nerd Font: Windows logo
    textFormat: Text.PlainText
    color: root.bar ? root.bar.barForeground : Color.foreground
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.bar.iconFont
    opacity: root.running ? 1 : 0.4

    SequentialAnimation on opacity {
      running: root.busy
      loops: Animation.Infinite
      NumberAnimation { to: 0.25; duration: 700; easing.type: Easing.InOutQuad }
      NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutQuad }
      onRunningChanged: if (!running) glyph.opacity = Qt.binding(function () { return root.running ? 1 : 0.4 })
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton

    onClicked: function (mouse) {
      if (!root.ready) return
      // Right-click: straight to the Windows desktop.
      if (mouse.button === Qt.RightButton) root.service.showRdp()
      else root.toggle()
    }
    onEntered: {
      root.hovered = true
      if (root.service) {
        root.service.hoverChanged(true)
        root.service.refreshRdp()
      }
      if (root.bar) root.bar.showTooltip(root, root.tip)
    }
    onExited: {
      if (root.hovered && root.service) root.service.hoverChanged(false)
      root.hovered = false
      if (root.bar) root.bar.hideTooltip(root)
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: root.moduleName

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function connect(): string { return show() }
    function show(): string {
      if (!root.ready) return "service not ready"
      return root.service.showRdp() ? "requested (see: status)" : root.service.lastError
    }
    function restart(): string {
      if (!root.ready) return "service not ready"
      return root.service.restart() ? "restarting" : root.service.lastError
    }
    function stop(): string {
      if (!root.ready) return "service not ready"
      return root.service.shutdown() ? "shutting down" : root.service.lastError
    }
    function status(): string {
      if (!root.ready) return "service not ready"
      var s = root.service
      return JSON.stringify({
        installed: s.installed, state: s.state, uptime: s.uptime,
        rdpOpen: s.rdpOpen, rdpKnown: s.rdpKnown, rdpWorkspace: s.rdpWorkspace,
        statsLive: s.detailed,
        keepAlive: s.keepAlive, ramSize: s.ramSize,
        pending: s.pendingKind, error: s.lastError,
        stats: s.stats
      })
    }
  }
}
