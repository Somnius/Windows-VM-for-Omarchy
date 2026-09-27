import QtQuick
import QtTest
import "../Logic.js" as Logic

TestCase {
  name: "Logic"

  function test_running() {
    var r = Logic.parseInspect(0, "running 2026-09-27T07:15:46.098Z RAM_SIZE=16G\n", "")
    compare(r.state, "running")
    compare(r.startedAt, "2026-09-27T07:15:46.098Z")
    compare(r.ramSize, "16 GB")
  }

  function test_stopped_and_missing_env() {
    var r = Logic.parseInspect(0, "exited 0001-01-01T00:00:00Z", "")
    compare(r.state, "stopped")
    compare(r.ramSize, "")
  }

  function test_errors() {
    compare(Logic.parseInspect(1, "", "Error: No such object: omarchy-windows").state, "absent")
    compare(Logic.parseInspect(1, "", "permission denied while trying to connect to the Docker daemon socket").state, "no-access")
    compare(Logic.parseInspect(1, "", "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?").state, "docker-down")
    compare(Logic.parseInspect(125, "", "boom").state, "error")
  }

  function test_ram() {
    compare(Logic.ramFrom("RAM_SIZE=8G"), "8 GB")
    compare(Logic.ramFrom("RAM_SIZE=4096M"), "4096 MB")
    compare(Logic.ramFrom("RAM_SIZE=16GiB"), "16 GB")
    compare(Logic.ramFrom("PASSWORD=secret"), "")
  }

  function test_rdp_window() {
    var json = JSON.stringify([
      { title: "kitty", address: "0x1", workspace: { name: "1" } },
      { title: "Windows VM - Omarchy", address: "0xabc", workspace: { name: "4" } }
    ])
    var w = Logic.findRdpWindow(json)
    compare(w.address, "0xabc")
    compare(w.workspace, "4")
    compare(Logic.findRdpWindow("[]"), null)
    compare(Logic.findRdpWindow("not json"), null)
  }

  function test_uptime() {
    var start = "2026-09-27T07:00:00Z"
    var t = Date.parse(start)
    compare(Logic.formatUptime(start, t + 30 * 1000), "<1m")
    compare(Logic.formatUptime(start, t + 12 * 60000), "12m")
    compare(Logic.formatUptime(start, t + 65 * 60000), "1h 5m")
    compare(Logic.formatUptime(start, t + (2 * 1440 + 180) * 60000), "2d 3h")
    compare(Logic.formatUptime("", t), "")
  }

  function test_pending() {
    verify(Logic.pendingDone({ kind: "launch" }, "running", true))
    verify(!Logic.pendingDone({ kind: "launch" }, "running", false))
    verify(!Logic.pendingDone({ kind: "restart", sawStopped: false }, "running", true))
    verify(Logic.pendingDone({ kind: "restart", sawStopped: true }, "running", true))
    verify(Logic.pendingDone({ kind: "stop" }, "absent", false))
    verify(Logic.pendingDone(null, "running", false))
  }

  function test_summary() {
    compare(Logic.summary({ installed: true, state: "running", uptime: "1h 5m", rdpOpen: true }),
      "Windows running · up 1h 5m · RDP open")
    compare(Logic.summary({ installed: true, state: "absent" }), "Windows stopped")
    compare(Logic.summary({ installed: false, state: "absent" }), "Windows VM not installed")
    compare(Logic.summary({ pendingKind: "stop", installed: true, state: "running" }), "Shutting down Windows…")
  }
}
