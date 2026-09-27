.pragma library

// Pure helpers for the Windows VM plugin. No Quickshell imports, so the
// qmltestrunner tests can load this file directly.
//
// derive() and the formatting helpers are adapted from Model.js in
// jonspinks/omarchy-winvm (MIT, Copyright (c) 2026 Jon Spinks, commit
// 7d62aab). See NOTICE.

var CONTAINER = "omarchy-windows"
var RDP_TITLE = "Windows VM - Omarchy"
var WEB_CONSOLE = "http://127.0.0.1:8006"
var HISTORY = 60

// ---- container state --------------------------------------------------------

// Only used while bin/Sample.sh finds no running qemu: tells "Windows is still
// starting" (container up, qemu not yet) from "stopped". Needs Docker access;
// without it the answer is simply "stopped".
var INSPECT_FORMAT = "{{.State.Status}}"

function containerRunning(exitCode, stdout) {
  return exitCode === 0 && String(stdout || "").trim() === "running"
}

// ---- samples ----------------------------------------------------------------

function parseSample(text) {
  try {
    var s = JSON.parse(String(text || "").trim())
    return s && typeof s === "object" ? s : null
  } catch (e) {
    return null
  }
}

function clamp01(v) {
  if (!isFinite(v)) return 0
  return v < 0 ? 0 : (v > 1 ? 1 : v)
}

function rate(cur, prev, key, dt) {
  if (!prev || dt <= 0) return 0
  var d = (Number(cur[key]) || 0) - (Number(prev[key]) || 0)
  // A container restart resets the counters; a negative delta is that, not traffic.
  return d > 0 ? d / dt : 0
}

// Disk I/O has no natural ceiling; 200 MB/s of sustained guest I/O counts as busy.
var IO_BUSY = 200 * 1024 * 1024

// Two raw samples (each with __t = wall-clock ms) -> rates and shares.
function derive(sample, prev) {
  var out = {
    running: !!(sample && sample.running),
    cpuCores: 0, cpu: 0, cpuHost: 0,
    memBytes: 0, ramBytes: 0, memHost: 0,
    ioRead: 0, ioWrite: 0, io: 0,
    netRx: 0, netTx: 0,
    vcpus: 0, hostCores: 1, uptime: 0,
    diskSize: 0, diskUsed: 0, container: ""
  }
  if (!out.running) return out

  // Diffing across a restart would compare two different containers.
  if (prev && (!prev.running || prev.container !== sample.container)) prev = null
  var dt = prev ? (sample.__t - prev.__t) / 1000 : 0

  out.vcpus = Number(sample.vcpus) || 0
  out.hostCores = Number(sample.hostCores) || 1
  out.cpuCores = rate(sample, prev, "cpuUsec", dt) / 1e6
  out.cpu = clamp01(out.vcpus > 0 ? out.cpuCores / out.vcpus : 0)
  out.cpuHost = clamp01(out.cpuCores / out.hostCores)

  // memory.current is the whole container (guest RAM qemu touched, qemu
  // itself, page cache): what the VM takes from the host, measured against
  // the host rather than against the guest's allocation.
  out.memBytes = Number(sample.memBytes) || 0
  out.ramBytes = Number(sample.ramBytes) || 0
  var hostMem = Number(sample.hostMem) || 0
  out.memHost = clamp01(hostMem > 0 ? out.memBytes / hostMem : 0)

  out.ioRead = rate(sample, prev, "ioRead", dt)
  out.ioWrite = rate(sample, prev, "ioWrite", dt)
  out.io = clamp01((out.ioRead + out.ioWrite) / IO_BUSY)

  out.netRx = rate(sample, prev, "netRx", dt)
  out.netTx = rate(sample, prev, "netTx", dt)

  out.uptime = Number(sample.uptime) || 0
  out.diskSize = Number(sample.diskSize) || 0
  out.diskUsed = Number(sample.diskUsed) || 0
  out.container = String(sample.container || "")
  return out
}

// Appends a value to a history array (returns a new array, newest last).
function pushHistory(list, value, capacity) {
  var next = (list || []).slice(-(capacity || HISTORY) + 1)
  next.push(Number(value) || 0)
  return next
}

// ---- formatting ---------------------------------------------------------------

function bytes(n) {
  n = Number(n) || 0
  if (n < 1024) return Math.round(n) + " B"
  var units = ["kB", "MB", "GB", "TB"]
  var i = -1
  do { n /= 1024; i++ } while (n >= 1024 && i < units.length - 1)
  return (n >= 100 ? n.toFixed(0) : n.toFixed(1)) + " " + units[i]
}

function rateText(n) { return bytes(n) + "/s" }

function percent(v) { return Math.round(clamp01(v) * 100) + "%" }

// "2d 3h", "1h 5m", "12m", "45s"
function uptimeText(seconds) {
  seconds = Math.max(0, Math.floor(Number(seconds) || 0))
  var d = Math.floor(seconds / 86400)
  var h = Math.floor((seconds % 86400) / 3600)
  var m = Math.floor((seconds % 3600) / 60)
  if (d > 0) return d + "d " + h + "h"
  if (h > 0) return h + "h " + m + "m"
  if (m > 0) return m + "m"
  return seconds + "s"
}

// ---- RDP window ---------------------------------------------------------------

// Finds the FreeRDP window in `hyprctl clients -j` output.
// Returns { address, workspace } or null.
function findRdpWindow(clientsJson) {
  var clients
  try {
    clients = JSON.parse(String(clientsJson || "[]"))
  } catch (e) {
    return null
  }
  if (!Array.isArray(clients)) return null
  for (var i = 0; i < clients.length; i++) {
    var c = clients[i]
    if (c && c.title === RDP_TITLE && /^0x[0-9a-fA-F]+$/.test(String(c.address)))
      return { address: String(c.address), workspace: c.workspace ? String(c.workspace.name) : "" }
  }
  return null
}

// ---- actions ------------------------------------------------------------------

// pending: { kind: "launch"|"connect"|"restart"|"stop", since, sawStopped }
// Returns true when the action has visibly finished.
function pendingDone(pending, state, rdpOpen) {
  if (!pending) return true
  switch (pending.kind) {
  case "launch": return state === "running" && rdpOpen
  case "connect": return rdpOpen
  case "restart": return pending.sawStopped && state === "running" && rdpOpen
  case "stop": return state === "stopped"
  }
  return true
}

var PENDING_TIMEOUT_MS = 5 * 60 * 1000
var CONNECT_TIMEOUT_MS = 45 * 1000

function pendingLabel(kind) {
  if (kind === "launch") return "Starting Windows…"
  if (kind === "connect") return "Connecting…"
  if (kind === "restart") return "Restarting Windows…"
  if (kind === "stop") return "Shutting down Windows…"
  return ""
}

function stateLabel(state) {
  switch (state) {
  case "running": return "Running"
  case "starting": return "Starting"
  case "stopped": return "Stopped"
  }
  return "Checking…"
}

// One line for the bar tooltip and the panel header.
function summary(model) {
  if (model.pendingKind) return pendingLabel(model.pendingKind)
  if (!model.installed) return "Windows VM not installed"
  if (model.state === "starting") return "Windows is starting…"
  var text = "Windows " + stateLabel(model.state).toLowerCase()
  if (model.state === "running") {
    if (model.uptime) text += " · up " + model.uptime
    // Window state is only looked up on demand; say nothing until it's known.
    if (model.rdpKnown !== false) text += model.rdpOpen ? " · RDP open" : " · RDP closed"
  }
  return text
}

// Second tooltip line with live numbers, "" when not running.
function statsLine(d) {
  if (!d || !d.running) return ""
  return "CPU " + percent(d.cpu) + " · " + bytes(d.memBytes) + " RAM · ↓ " + rateText(d.netRx) + " ↑ " + rateText(d.netTx)
}
