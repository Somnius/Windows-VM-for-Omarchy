# Changelog

## 1.1.0 (2026-09-27)

Live resource use, direct reconnect and RDP auto-reconnect. Several ideas and parts come from
[jonspinks/omarchy-winvm](https://github.com/jonspinks/omarchy-winvm) by Jon Spinks (MIT); see
[NOTICE](NOTICE).

- **Costs nothing while you aren't looking:** with the panel closed, the plugin only checks
  whether Windows is running (one small process every 5 s). There's no resource tracking, no
  Docker calls and no window polling in the background. Numbers and graphs are gathered only
  while the panel is open, and are thrown away when it closes.
- **Resource use in the panel, on demand:** CPU (against the guest's vCPUs and the host), memory
  held on the host, disk I/O, allocated disk image, network down/up, uptime and container ID
  (click to copy). CPU and network come with live graphs. The first numbers arrive in about a
  second, with an animated placeholder until then.
- **No Docker access needed for status:** everything is read from the container's cgroup and
  `/proc`, so the icon and numbers work without the docker group.
- **Connect without a password prompt:** when Windows is running and no RDP window is open,
  Connect opens one directly with the credentials Omarchy saved, and passes the password
  through a file descriptor instead of the command line.
- **RDP auto-reconnect:** a dropped connection through Docker's port forward now reconnects
  instead of closing the window. This covers windows opened by Connect and by Start/Restart,
  through a small `xfreerdp3` shim on the launcher's PATH.
- **"Starting" state:** a click first checks whether Windows is still booting, so Start never
  launches twice; with the panel open, the icon pulses while it boots.
- **Safer Restart and Shut down:** RDP windows are closed first, and a launcher waiting on its
  window is left to stop the VM itself, so there is no second password prompt and no late stop
  hitting a freshly started VM.
- **More ways in:** Shared folder (`~/Windows`), an optional Terminal button
  (`terminalCommand`, e.g. `ssh winvm`), and a Docker button that opens lazydocker when it's
  installed.
- **Failures show at once:** a declined password prompt, missing credentials or an already
  open session is reported in the panel straight away, instead of after a timeout.
- A rotating "Taking Windows' pulse…" placeholder, centred in the theme's accent, while the
  first numbers load.
- The web console's login is explained: it's the Windows username and password.
- Settings and Help are now collapsible sections. Settings keep unknown keys, and a broken
  `config.json` is never overwritten.
- Logs are private (mode 700).

## 1.0.0 (2026-09-27)

First release: bar status, show/start, restart, shut down, web console, logs, help, optional
keep-alive with a RAM warning, hide-when-stopped.
