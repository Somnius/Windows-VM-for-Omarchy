import QtQuick
import QtTest
import "../Logic.js" as Logic

TestCase {
  name: "Logic"

  function sample(t, over) {
    var s = {
      running: true, container: "abc", cpuUsec: 0, memBytes: 8 * 1073741824,
      ioRead: 0, ioWrite: 0, netRx: 0, netTx: 0, vcpus: 8, ramBytes: 16 * 1073741824,
      uptime: 3900, diskSize: 100, diskUsed: 25, hostCores: 32, hostMem: 64 * 1073741824, __t: t
    }
    for (var k in over) s[k] = over[k]
    return s
  }

  function test_container_state() {
    verify(Logic.containerRunning(0, "running\n"))
    verify(!Logic.containerRunning(0, "exited"))
    verify(!Logic.containerRunning(1, ""))
  }

  function test_parse_sample() {
    compare(Logic.parseSample('{"running":false}\n').running, false)
    compare(Logic.parseSample("garbage"), null)
    compare(Logic.parseSample(""), null)
  }

  function test_derive_rates() {
    var a = sample(0, {})
    var b = sample(2000, { cpuUsec: 4e6, netRx: 2048, netTx: 1024, ioRead: 400, ioWrite: 600 })
    var d = Logic.derive(b, a)
    compare(d.cpuCores, 2)             // 4 s of CPU in 2 s
    compare(d.cpu, 0.25)               // of 8 vCPUs
    compare(d.cpuHost, 2 / 32)
    compare(d.netRx, 1024)
    compare(d.netTx, 512)
    compare(d.ioRead + d.ioWrite, 500)
    compare(d.memHost, 0.125)          // 8 of 64 GB
    compare(d.container, "abc")
  }

  function test_derive_first_and_reset() {
    compare(Logic.derive(sample(0, { cpuUsec: 9e6 }), null).cpu, 0)
    // Container changed: no diff across two different containers.
    var d = Logic.derive(sample(2000, { container: "new", cpuUsec: 1e6 }), sample(0, {}))
    compare(d.cpu, 0)
    // Counter went backwards (restart): not negative traffic.
    compare(Logic.derive(sample(2000, { netRx: 10 }), sample(0, { netRx: 5000 })).netRx, 0)
    verify(!Logic.derive({ running: false }, null).running)
  }

  function test_history() {
    var h = []
    for (var i = 0; i < 70; i++) h = Logic.pushHistory(h, i)
    compare(h.length, Logic.HISTORY)
    compare(h[h.length - 1], 69)
    compare(h[0], 10)
  }

  function test_format() {
    compare(Logic.bytes(512), "512 B")
    compare(Logic.bytes(16 * 1073741824), "16.0 GB")
    compare(Logic.bytes(200 * 1048576), "200 MB")
    compare(Logic.rateText(2048), "2.0 kB/s")
    compare(Logic.percent(0.256), "26%")
    compare(Logic.percent(3), "100%")
    compare(Logic.uptimeText(45), "45s")
    compare(Logic.uptimeText(12 * 60), "12m")
    compare(Logic.uptimeText(3900), "1h 5m")
    compare(Logic.uptimeText(2 * 86400 + 3 * 3600), "2d 3h")
  }

  function test_rdp_window() {
    var json = JSON.stringify([
      { title: "kitty", address: "0x1", workspace: { name: "1" } },
      { title: "Windows VM - Omarchy", address: "0xabc", workspace: { name: "4" } }
    ])
    var w = Logic.findRdpWindow(json)
    compare(w.address, "0xabc")
    compare(w.workspace, "4")
    compare(Logic.findRdpWindow(JSON.stringify([{ title: "Windows VM - Omarchy", address: "$(x)" }])), null)
    compare(Logic.findRdpWindow("[]"), null)
    compare(Logic.findRdpWindow("not json"), null)
  }

  function test_pending() {
    verify(Logic.pendingDone({ kind: "launch" }, "running", true))
    verify(!Logic.pendingDone({ kind: "launch" }, "starting", false))
    verify(Logic.pendingDone({ kind: "connect" }, "running", true))
    verify(!Logic.pendingDone({ kind: "restart", sawStopped: false }, "running", true))
    verify(Logic.pendingDone({ kind: "restart", sawStopped: true }, "running", true))
    verify(Logic.pendingDone({ kind: "stop" }, "stopped", false))
    verify(!Logic.pendingDone({ kind: "stop" }, "starting", false))
    verify(Logic.pendingDone(null, "running", false))
  }

  function test_summary() {
    compare(Logic.summary({ installed: true, state: "running", uptime: "1h 5m", rdpOpen: true }),
      "Windows running · up 1h 5m · RDP open")
    compare(Logic.summary({ installed: true, state: "stopped" }), "Windows stopped")
    compare(Logic.summary({ installed: true, state: "running", uptime: "5m", rdpOpen: false, rdpKnown: false }),
      "Windows running · up 5m")
    compare(Logic.summary({ installed: true, state: "starting" }), "Windows is starting…")
    compare(Logic.summary({ installed: false, state: "stopped" }), "Windows VM not installed")
    compare(Logic.summary({ pendingKind: "connect", installed: true, state: "running" }), "Connecting…")
  }

  function test_stats_line() {
    compare(Logic.statsLine(Logic.derive({ running: false }, null)), "")
    var d = Logic.derive(sample(2000, { cpuUsec: 4e6, netRx: 2048 }), sample(0, {}))
    compare(Logic.statsLine(d), "CPU 25% · 8.0 GB RAM · ↓ 1.0 kB/s ↑ 0 B/s")
  }
}
