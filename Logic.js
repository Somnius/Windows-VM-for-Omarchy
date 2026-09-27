.pragma library

// Pure helpers for the Windows VM plugin. No Quickshell imports, so the
// qmltestrunner tests can load this file directly.

var CONTAINER = "omarchy-windows"
var RDP_TITLE = "Windows VM - Omarchy"
var WEB_CONSOLE = "http://127.0.0.1:8006"

// Only these fields leave docker; the container's environment also holds the
// Windows password, so RAM_SIZE is picked out inside the template.
var INSPECT_FORMAT = '{{.State.Status}} {{.State.StartedAt}} '
  + '{{range .Config.Env}}{{if eq (index (split . "=") 0) "RAM_SIZE"}}{{.}}{{end}}{{end}}'

// Turns `docker inspect --format INSPECT_FORMAT` output into
// { state, startedAt, ramSize, detail }.
// state: running | stopped | absent | no-access | docker-down | error
function parseInspect(exitCode, stdout, stderr) {
  var out = String(stdout || "").trim()
  var err = String(stderr || "").trim()

  if (exitCode === 0 && out !== "") {
    var parts = out.split(/\s+/)
    var status = parts[0]
    var startedAt = parts.length > 1 ? parts[1] : ""
    var ram = parts.length > 2 ? ramFrom(parts[2]) : ""
    if (status === "running") return { state: "running", startedAt: startedAt, ramSize: ram, detail: status }
    return { state: "stopped", startedAt: "", ramSize: ram, detail: status }
  }

  var low = err.toLowerCase()
  if (low.indexOf("no such object") >= 0 || low.indexOf("no such container") >= 0)
    return { state: "absent", startedAt: "", ramSize: "", detail: "" }
  if (low.indexOf("permission denied") >= 0)
    return { state: "no-access", startedAt: "", ramSize: "", detail: firstLine(err) }
  if (low.indexOf("cannot connect to the docker daemon") >= 0 || low.indexOf("is the docker daemon running") >= 0)
    return { state: "docker-down", startedAt: "", ramSize: "", detail: firstLine(err) }
  return { state: "error", startedAt: "", ramSize: "", detail: firstLine(err) || ("docker exited " + exitCode) }
}

// "RAM_SIZE=16G" -> "16 GB"
function ramFrom(envEntry) {
  var m = /^RAM_SIZE=(\d+(?:\.\d+)?)\s*([KMGT]?)i?B?$/i.exec(String(envEntry || ""))
  if (!m) return ""
  var unit = m[2].toUpperCase()
  return m[1] + " " + (unit === "" ? "B" : unit + "B")
}

function firstLine(text) {
  return String(text || "").split("\n")[0].substring(0, 200)
}

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
    if (c && c.title === RDP_TITLE && c.address)
      return { address: String(c.address), workspace: c.workspace ? String(c.workspace.name) : "" }
  }
  return null
}

// "2d 3h", "1h 5m", "12m", "<1m"
function formatUptime(startedAtIso, nowMs) {
  var started = Date.parse(String(startedAtIso || ""))
  if (isNaN(started) || started <= 0) return ""
  var mins = Math.floor(Math.max(0, nowMs - started) / 60000)
  if (mins < 1) return "<1m"
  var d = Math.floor(mins / 1440)
  var h = Math.floor((mins % 1440) / 60)
  var m = mins % 60
  if (d > 0) return d + "d " + h + "h"
  if (h > 0) return h + "h " + m + "m"
  return m + "m"
}

// What the user is waiting for after pressing a button.
// pending: { kind: "launch"|"restart"|"stop", since, sawStopped }
// Returns true when the action has visibly finished.
function pendingDone(pending, state, rdpOpen) {
  if (!pending) return true
  switch (pending.kind) {
  case "launch": return state === "running" && rdpOpen
  case "restart": return pending.sawStopped && state === "running" && rdpOpen
  case "stop": return state !== "running"
  }
  return true
}

var PENDING_TIMEOUT_MS = 4 * 60 * 1000

function pendingLabel(kind) {
  if (kind === "launch") return "Starting Windows…"
  if (kind === "restart") return "Restarting Windows…"
  if (kind === "stop") return "Shutting down Windows…"
  return ""
}

function stateLabel(state) {
  switch (state) {
  case "running": return "Running"
  case "stopped": return "Stopped"
  case "absent": return "Stopped"
  case "no-access": return "No Docker access"
  case "docker-down": return "Docker is not running"
  case "error": return "Status unavailable"
  }
  return "Checking…"
}

// One line for the bar tooltip and the panel header.
function summary(model) {
  if (model.pendingKind) return pendingLabel(model.pendingKind)
  if (!model.installed) return "Windows VM not installed"
  var text = "Windows " + stateLabel(model.state).toLowerCase()
  if (model.state === "running") {
    if (model.uptime) text += " · up " + model.uptime
    text += model.rdpOpen ? " · RDP open" : " · RDP closed"
  }
  return text
}
