import QtQuick
import Quickshell
import Quickshell.Io
import "Logic.js" as Logic

Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
  readonly property string logDir: stateHome + "/windows-vm/logs"
  readonly property string sharedDir: home + "/Windows"
  readonly property string configDir: home + "/.config/omarchy/windows-vm"
  readonly property string configPath: configDir + "/config.json"
  readonly property string pluginDir: decodeURIComponent(
    String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string launchScript: pluginDir + "/Launch.sh"
  readonly property string connectScript: pluginDir + "/bin/Connect.sh"
  readonly property string sampleScript: pluginDir + "/bin/Sample.sh"
  readonly property string statusPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/windows-vm/status.json"
  readonly property string repoUrl: "https://github.com/Somnius/Windows-VM-for-Omarchy"
  readonly property string webConsoleUrl: Logic.WEB_CONSOLE

  // Live state.
  property bool loaded: false
  property bool installed: true
  property string state: ""          // running | starting | stopped
  property var stats: Logic.derive(null, null)
  property var lastSample: null
  // True once two readings have been taken with the panel open, so rates
  // (CPU, disk, network) mean something. Until then the panel shows a placeholder.
  property bool statsReady: false
  property var cpuHistory: []
  property var rxHistory: []
  property var txHistory: []
  // When the running VM started (ms since epoch), from its uptime: a new
  // value means a new VM, even if a restart was too quick to see "stopped".
  property real vmStartedAt: 0
  property bool rdpOpen: false
  property bool rdpKnown: false  // false until checked; reset when nobody looks
  property string rdpAddress: ""
  property string rdpWorkspace: ""

  // Resource numbers and graphs are collected only while the panel is open;
  // closed, the plugin only checks whether Windows runs. The bar widget sets
  // `hovering` so the tooltip can show whether the RDP window is open.
  // Counted, not flags: a panel or bar per monitor, and a bar reload that
  // destroys a widget mid-hover must not leave detailed sampling on.
  property int openPanels: 0
  property int hovers: 0
  readonly property bool panelOpen: openPanels > 0
  readonly property bool hovering: hovers > 0
  readonly property bool detailed: panelOpen
  // A click's request to show Windows, waiting for fresh window (and, when
  // not running, Docker) state. Expires, so it can't fire much later.
  property real wantShowAt: 0

  function panelOpened(open) { root.openPanels = Math.max(0, root.openPanels + (open ? 1 : -1)) }
  function hoverChanged(on) { root.hovers = Math.max(0, root.hovers + (on ? 1 : -1)) }

  // Settings (config.json).
  property bool hideWhenStopped: false
  // Off: closing RDP shuts Windows down (Omarchy's default). On: Windows keeps
  // running, and holding its RAM, until it is shut down.
  property bool keepAlive: false
  // Optional command for the Terminal button, e.g. "ssh winvm".
  property string terminalCommand: ""
  // lazydocker installed? Then the panel offers it.
  property bool hasLazydocker: false

  // The action the user is waiting on, if any.
  property var pending: null
  readonly property string pendingKind: pending ? pending.kind : ""
  readonly property bool busy: pending !== null
  readonly property bool running: state === "running"
  readonly property string ramSize: stats.ramBytes > 0 ? Logic.bytes(stats.ramBytes) : ""
  readonly property string uptime: running ? Logic.uptimeText(stats.uptime) : ""
  property string lastError: ""

  readonly property string summaryText: Logic.summary({
    pendingKind: root.pendingKind, installed: root.installed, state: root.state,
    uptime: root.uptime, rdpOpen: root.rdpOpen, rdpKnown: root.rdpKnown
  })
  function summary() { return root.summaryText }

  // ---- actions -----------------------------------------------------------

  // Focus the open RDP window; else reconnect to a running VM; else start it.
  // Window state isn't tracked in the background, so look first, then act.
  function showRdp() {
    if (root.busy) {
      root.lastError = "Wait for the current action to finish."
      return false
    }
    if (!root.installed) {
      root.lastError = "The Windows VM is not installed. Run: omarchy-windows-vm install"
      return false
    }
    root.wantShowAt = Date.now()
    root.refreshRdp()
    // Not running as far as we know: ask Docker whether it's actually still
    // starting (e.g. started outside the plugin), so a click never launches twice.
    if (!root.running && !inspectProc.running) inspectProc.running = true
    return true
  }

  function serveShow() {
    if (root.wantShowAt === 0 || clientsProc.running || inspectProc.running) return
    var fresh = Date.now() - root.wantShowAt < 3000
    root.wantShowAt = 0
    if (fresh) root.doShowRdp()
  }

  function refreshRdp() {
    if (!clientsProc.running) clientsProc.running = true
  }

  function doShowRdp() {
    if (root.rdpOpen) {
      Quickshell.execDetached(["bash", "-c",
        'hyprctl dispatch "hl.dsp.focus({ window = \\"address:$1\\" })" >/dev/null 2>&1'
        + ' || hyprctl dispatch focuswindow "address:$1" >/dev/null',
        "focus-rdp", root.rdpAddress])
      return true
    }
    if (root.state === "starting") {
      root.lastError = "Windows is still starting. Try again in a moment, or open the web console."
      return false
    }
    if (root.running) return root.begin("connect", ["uwsm-app", "--", root.connectScript])
    return root.run("launch")
  }

  function restart() { return root.requireRunning() && root.run("restart") }
  function shutdown() { return root.requireRunning() && root.run("stop") }

  function requireRunning() {
    if (root.running) return true
    root.lastError = root.state === "starting"
      ? "Windows is still starting. Wait until it's running." : "Windows isn't running."
    return false
  }

  function run(kind) {
    var command = ["uwsm-app", "--", root.launchScript, kind]
    if (kind !== "stop" && root.keepAlive) command.push("keep")
    return root.begin(kind, command)
  }

  function begin(kind, command) {
    if (root.busy) {
      root.lastError = "Wait for the current action to finish."
      return false
    }
    if (!root.installed) {
      root.lastError = "The Windows VM is not installed. Run: omarchy-windows-vm install"
      return false
    }
    root.lastError = ""
    root.pending = { kind: kind, since: Date.now(), sawStopped: root.state === "stopped",
      startedAt: root.vmStartedAt }
    // Detached into its own uwsm scope: RDP keeps running if the shell restarts.
    Quickshell.execDetached(command)
    Qt.callLater(root.poll)
    return true
  }

  function openWebConsole() { Qt.openUrlExternally(root.webConsoleUrl) }
  function openShared() { Qt.openUrlExternally("file://" + root.sharedDir) }
  function openLogs() {
    Quickshell.execDetached(["mkdir", "-p", "-m", "700", root.logDir])
    Qt.openUrlExternally("file://" + root.logDir)
  }
  function openTerminal() {
    var cmd = String(root.terminalCommand || "").trim()
    if (cmd === "") return false
    // The command comes from the user's own config.json; passed as one argv entry.
    Quickshell.execDetached(["xdg-terminal-exec", "sh", "-c", cmd])
    return true
  }
  // Omarchy's own launcher: handles Docker access (polkit prompt without the
  // docker group) and focuses lazydocker if it is already open.
  function openLazydocker() {
    if (!root.hasLazydocker) return false
    Quickshell.execDetached(["bash", "-c",
      'if command -v omarchy-launch-docker-tui >/dev/null; then'
      + ' exec omarchy-launch-or-focus-tui omarchy-launch-docker-tui;'
      + ' else exec xdg-terminal-exec lazydocker; fi'])
    return true
  }

  function copyContainerId() {
    if (root.stats.container === "") return false
    Quickshell.execDetached(["wl-copy", root.stats.container])
    return true
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
    if (root.configBroken) return
    if (!configDirProc.running) configDirProc.running = true
  }

  // ---- polling -----------------------------------------------------------

  // Closed panel: one light check (is Windows running, since when). Open
  // panel or an action in progress: counters, window state and Docker too.
  function poll() {
    if (sampleProc.running) {
      // A light sample is still out; take a detailed one right after it.
      if (root.detailed && !sampleProc.detailed) sampleProc.again = true
    } else {
      sampleProc.detailed = root.detailed
      sampleProc.command = root.detailed
        ? ["bash", root.sampleScript] : ["bash", root.sampleScript, "--state"]
      sampleProc.running = true
    }
    if (root.detailed || root.busy || root.hovering) root.refreshRdp()
  }

  onHoveringChanged: if (!root.hovering && !root.panelOpen) root.rdpKnown = false

  function clearStats() {
    root.statsReady = false
    root.lastSample = null
    root.cpuHistory = []
    root.rxHistory = []
    root.txHistory = []
  }

  onPanelOpenChanged: {
    root.clearStats()
    if (!root.panelOpen && !root.hovering) root.rdpKnown = false
    if (root.panelOpen) {
      root.stats = Logic.derive(null, null)
      if (!installedProc.running) installedProc.running = true
      root.poll()
      // Rates need a second reading; take it soon rather than on the next tick.
      secondReading.restart()
    }
  }

  Timer {
    id: secondReading
    interval: 800
    onTriggered: if (root.detailed) root.poll()
  }

  function applySample(detailed) {
    var s = Logic.parseSample(sampleOut.text)
    if (!s) return
    s.__t = Date.now()
    // A sample taken with the panel closed carries no counters: never diff
    // against it, and never let it into the graphs.
    var usable = detailed && root.detailed
    var hadPrev = usable && root.lastSample !== null
    var d = Logic.derive(s, usable ? root.lastSample : null)
    root.lastSample = usable ? s : null
    if (usable || !d.running) root.stats = d
    else root.stats = Logic.derive({ running: true, uptime: s.uptime }, null)
    if (d.running) {
      // Rounded to 10 s, so sampling jitter doesn't look like a new VM.
      root.vmStartedAt = Math.round((s.__t - d.uptime * 1000) / 10000) * 10000
      root.state = "running"
      root.installed = true
      // The first reading has no rates yet: keep it out of the graphs.
      if (hadPrev) {
        root.statsReady = true
        root.cpuHistory = Logic.pushHistory(root.cpuHistory, d.cpu)
        root.rxHistory = Logic.pushHistory(root.rxHistory, d.netRx)
        root.txHistory = Logic.pushHistory(root.txHistory, d.netTx)
      }
      root.loaded = true
      root.settlePending()
    } else {
      root.clearStats()
      // No qemu: stopped, or still starting? Docker knows, if we may ask; only
      // worth asking while someone is looking or waiting on an action.
      if (root.detailed || root.busy) {
        if (!inspectProc.running) inspectProc.running = true
      } else {
        root.state = "stopped"
        root.loaded = true
        root.settlePending()
      }
    }
  }

  function applyInspect(exitCode) {
    if (root.stats.running) return
    root.state = Logic.containerRunning(exitCode, inspectOut.text) ? "starting" : "stopped"
    root.loaded = true
    root.settlePending()
    root.serveShow()
  }

  function applyClients() {
    var w = Logic.findRdpWindow(clientsOut.text)
    root.rdpOpen = w !== null
    root.rdpKnown = true
    root.rdpAddress = w ? w.address : ""
    root.rdpWorkspace = w ? w.workspace : ""
    root.settlePending()
    root.serveShow()
  }

  function settlePending() {
    var p = root.pending
    if (!p) return
    var newVm = root.state === "running" && p.startedAt > 0
      && Math.abs(root.vmStartedAt - p.startedAt) > 30000
    if ((root.state === "stopped" || newVm) && !p.sawStopped)
      p = root.pending = { kind: p.kind, since: p.since, sawStopped: true, startedAt: p.startedAt }
    if (Logic.pendingDone(p, root.state, root.rdpOpen)) {
      root.pending = null
      return
    }
    var limit = p.kind === "connect" ? Logic.CONNECT_TIMEOUT_MS : Logic.PENDING_TIMEOUT_MS
    if (Date.now() - p.since > limit) {
      root.pending = null
      root.lastError = "That didn't finish. The newest log in " + root.logDir + " says why."
    }
  }

  Timer {
    // Faster while the panel is open or an action is in progress.
    interval: root.busy || root.detailed ? 2000 : 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  Process {
    id: sampleProc
    // Whether this run reads counters (set when it starts).
    property bool detailed: false
    property bool again: false
    command: ["bash", root.sampleScript, "--state"]
    stdout: StdioCollector { id: sampleOut; waitForEnd: true }
    onExited: {
      root.applySample(sampleProc.detailed)
      if (sampleProc.again) {
        sampleProc.again = false
        Qt.callLater(root.poll)
      }
    }
  }

  Process {
    id: inspectProc
    command: ["docker", "inspect", "--format", Logic.INSPECT_FORMAT, Logic.CONTAINER]
    stdout: StdioCollector { id: inspectOut; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) { root.applyInspect(exitCode) }
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector { id: clientsOut; waitForEnd: true }
    onExited: root.applyClients()
  }

  // Installed at all? Checked at startup and whenever the panel opens.
  Process {
    id: installedProc
    running: true
    command: ["bash", "-c", 'test -e /var/lib/omarchy/windows/docker-compose.yml || test -e "$HOME/.config/windows/docker-compose.yml"']
    onExited: function(exitCode) { root.installed = exitCode === 0 }
  }

  Process {
    id: lazydockerProc
    command: ["bash", "-c", "command -v lazydocker"]
    running: true
    onExited: function(exitCode) { root.hasLazydocker = exitCode === 0 }
  }

  // How the last action ended, written by Launch.sh and bin/Connect.sh.
  // A failure (declined password prompt, no credentials, ...) releases the
  // panel at once, with the reason.
  function applyStatus(text) {
    var st = null
    try { st = JSON.parse(String(text || "")) } catch (e) { return }
    var p = root.pending
    if (!st || !p || Number(st.rc) === 0 || Number(st.at) < p.since) return
    if (st.kind !== p.kind && !(p.kind === "restart" && st.kind === "restart")) return
    root.pending = null
    root.lastError = String(st.message || (p.kind + " failed")) + ". Details are in the newest log."
  }

  // $XDG_RUNTIME_DIR is emptied at every boot, and a FileView whose folder is
  // missing never starts watching: create the folder, then watch.
  Process {
    command: ["mkdir", "-p", "-m", "700", root.statusPath.replace(/\/[^\/]*$/, "")]
    running: true
    onExited: statusFile.path = root.statusPath
  }

  FileView {
    id: statusFile
    path: ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyStatus(text())
  }

  // ---- settings ------------------------------------------------------------

  // The file as last read, so saving keeps keys this version doesn't know.
  property var configRaw: ({})
  // A file that doesn't parse (a typo, a half-written save) is never
  // overwritten: settings stay as they were until it is fixed.
  property bool configBroken: false

  function applyConfig(text) {
    var c = null
    try { c = JSON.parse(String(text || "{}")) } catch (e) { c = null }
    if (!c || typeof c !== "object" || Array.isArray(c)) {
      root.configBroken = true
      root.lastError = "config.json isn't valid JSON; settings won't be saved until it's fixed."
      return
    }
    if (root.configBroken) root.lastError = ""
    root.configBroken = false
    root.configRaw = c
    root.hideWhenStopped = c.hideWhenStopped === true
    root.keepAlive = c.keepAlive === true
    root.terminalCommand = typeof c.terminalCommand === "string" ? c.terminalCommand : ""
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
    onExited: {
      var c = JSON.parse(JSON.stringify(root.configRaw || {}))
      c.hideWhenStopped = root.hideWhenStopped
      c.keepAlive = root.keepAlive
      c.terminalCommand = root.terminalCommand
      configFile.setText(JSON.stringify(c, null, 2) + "\n")
    }
  }
}
