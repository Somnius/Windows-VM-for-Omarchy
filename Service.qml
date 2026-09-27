import QtQuick
import Quickshell
import Quickshell.Io
import "Logic.js" as Logic

Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
  readonly property string logDir: stateHome + "/windows-vm/logs"
  readonly property string configDir: home + "/.config/omarchy/windows-vm"
  readonly property string configPath: configDir + "/config.json"
  readonly property string launchScript: decodeURIComponent(
    String(Qt.resolvedUrl("Launch.sh")).replace(/^file:\/\//, ""))
  readonly property string repoUrl: "https://github.com/Somnius/Windows-VM-for-Omarchy"
  readonly property string webConsoleUrl: Logic.WEB_CONSOLE

  // Live state, refreshed by the poll timer.
  property bool loaded: false
  property bool installed: true
  property string state: ""          // see Logic.parseInspect
  property string detail: ""
  property string startedAt: ""
  property string ramSize: ""        // e.g. "16 GB", from the container's RAM_SIZE
  property string uptime: ""
  property bool rdpOpen: false
  property string rdpAddress: ""
  property string rdpWorkspace: ""

  // Settings (config.json).
  property bool hideWhenStopped: false
  // Off: closing RDP shuts Windows down (Omarchy's default). On: Windows keeps
  // running, and holding its RAM, until it is shut down.
  property bool keepAlive: false

  // The action the user is waiting on, if any.
  property var pending: null
  readonly property string pendingKind: pending ? pending.kind : ""
  readonly property bool busy: pending !== null
  readonly property bool running: state === "running"
  property string lastError: ""

  function summary() {
    return Logic.summary({
      pendingKind: root.pendingKind, installed: root.installed, state: root.state,
      uptime: root.uptime, rdpOpen: root.rdpOpen
    })
  }

  // ---- actions -----------------------------------------------------------

  // Focus the open RDP window, or start Windows / reconnect RDP.
  function showRdp() {
    if (root.rdpOpen && /^0x[0-9a-fA-F]+$/.test(root.rdpAddress)) {
      Quickshell.execDetached(["bash", "-c",
        'hyprctl dispatch "hl.dsp.focus({ window = \\"address:$1\\" })" >/dev/null 2>&1'
        + ' || hyprctl dispatch focuswindow "address:$1" >/dev/null',
        "focus-rdp", root.rdpAddress])
      return true
    }
    return root.run("launch")
  }

  function restart() { return root.run("restart") }
  function shutdown() { return root.run("stop") }

  function run(kind) {
    if (root.busy) {
      root.lastError = "Wait for the current action to finish."
      return false
    }
    if (!root.installed) {
      root.lastError = "The Windows VM is not installed. Run: omarchy-windows-vm install"
      return false
    }
    root.lastError = ""
    root.pending = { kind: kind, since: Date.now(), sawStopped: root.state !== "running" }
    // Detached into its own uwsm scope: RDP keeps running if the shell restarts.
    var command = ["uwsm-app", "--", root.launchScript, kind]
    if (kind !== "stop" && root.keepAlive) command.push("keep")
    Quickshell.execDetached(command)
    Qt.callLater(root.poll)
    return true
  }

  function openWebConsole() { Qt.openUrlExternally(root.webConsoleUrl) }
  function openLogs() {
    Quickshell.execDetached(["mkdir", "-p", root.logDir])
    Qt.openUrlExternally("file://" + root.logDir)
  }

  function setHideWhenStopped(value) {
    root.hideWhenStopped = value === true
    root.saveConfig()
  }

  function setKeepAlive(value) {
    root.keepAlive = value === true
    root.saveConfig()
  }

  function saveConfig() {
    if (!configDirProc.running) configDirProc.running = true
  }

  // ---- polling -----------------------------------------------------------

  function poll() {
    if (!inspectProc.running) inspectProc.running = true
    if (!clientsProc.running) clientsProc.running = true
  }

  function applyInspect(exitCode) {
    var r = Logic.parseInspect(exitCode, inspectOut.text, inspectErr.text)
    root.state = r.state
    root.detail = r.detail
    root.startedAt = r.startedAt
    if (r.ramSize !== "") root.ramSize = r.ramSize
    root.uptime = Logic.formatUptime(r.startedAt, Date.now())
    if (r.state === "absent") {
      if (!installedProc.running) installedProc.running = true
    } else if (r.state === "running" || r.state === "stopped") {
      root.installed = true
    }
    root.loaded = true
    root.settlePending()
  }

  function applyClients() {
    var w = Logic.findRdpWindow(clientsOut.text)
    root.rdpOpen = w !== null
    root.rdpAddress = w ? w.address : ""
    root.rdpWorkspace = w ? w.workspace : ""
    root.settlePending()
  }

  function settlePending() {
    var p = root.pending
    if (!p) return
    if (root.state !== "running" && !p.sawStopped)
      root.pending = { kind: p.kind, since: p.since, sawStopped: true }
    if (Logic.pendingDone(root.pending, root.state, root.rdpOpen)) {
      root.pending = null
    } else if (Date.now() - p.since > Logic.PENDING_TIMEOUT_MS) {
      root.pending = null
      root.lastError = "That took too long. Check the log: " + root.logDir
    }
  }

  Timer {
    // Faster while an action is in progress.
    interval: root.busy ? 2000 : 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  Process {
    id: inspectProc
    command: ["docker", "inspect", "--format", Logic.INSPECT_FORMAT, Logic.CONTAINER]
    stdout: StdioCollector { id: inspectOut; waitForEnd: true }
    stderr: StdioCollector { id: inspectErr; waitForEnd: true }
    onExited: function(exitCode) { root.applyInspect(exitCode) }
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector { id: clientsOut; waitForEnd: true }
    onExited: root.applyClients()
  }

  // No container yet: is the VM installed at all? (Current or legacy compose path.)
  Process {
    id: installedProc
    command: ["bash", "-c", 'test -e /var/lib/omarchy/windows/docker-compose.yml || test -e "$HOME/.config/windows/docker-compose.yml"']
    onExited: function(exitCode) { root.installed = exitCode === 0 }
  }

  // ---- settings ------------------------------------------------------------

  function applyConfig(text) {
    try {
      var c = JSON.parse(String(text || "{}"))
      root.hideWhenStopped = !!c && c.hideWhenStopped === true
      root.keepAlive = !!c && c.keepAlive === true
    } catch (e) {
      root.hideWhenStopped = false
      root.keepAlive = false
    }
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyConfig(text())
  }

  Process {
    id: configDirProc
    command: ["mkdir", "-p", root.configDir]
    onExited: configFile.setText(JSON.stringify({ hideWhenStopped: root.hideWhenStopped, keepAlive: root.keepAlive }, null, 2) + "\n")
  }
}
