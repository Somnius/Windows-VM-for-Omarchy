#!/usr/bin/env bash
# Runs one Windows VM action for the plugin and keeps its output.
#   Launch.sh launch  [keep]   start the VM if needed and open RDP
#   Launch.sh restart [keep]   shut Windows down cleanly, then launch again
#   Launch.sh stop             shut Windows down cleanly
# With "keep", the VM stays up when the RDP window closes; without it, closing
# RDP shuts Windows down (Omarchy's default).
# The plugin starts this detached via uwsm, so RDP survives shell restarts.
#
# Stopping hands over to a waiting launcher when there is one, an idea from
# bin/winvm-stop in jonspinks/omarchy-winvm (MIT, Copyright (c) 2026 Jon
# Spinks, commit 7d62aab). See NOTICE.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

action=${1:-}
keep_alive=()
[[ ${2:-} == keep ]] && keep_alive=(--keep-alive)
case $action in
launch | restart | stop) ;;
*)
  echo "usage: Launch.sh launch|restart|stop [keep]" >&2
  exit 2
  ;;
esac

umask 077
log_dir="${XDG_STATE_HOME:-$HOME/.local/state}/windows-vm/logs"
mkdir -p -m 700 -- "$log_dir"
chmod 700 -- "$log_dir"
exec >>"$log_dir/$action-$(date +%Y%m%d-%H%M%S).log" 2>&1

# Tell the plugin how the action ended, so a declined password prompt or a
# failure shows up in the panel at once instead of after a timeout.
status_dir="${XDG_RUNTIME_DIR:-/tmp}/windows-vm"
json_text() { local t=${1//\\/\\\\}; t=${t//\"/\\\"}; printf '%s' "${t//$'\n'/ }"; }
report() { # exit code, message
  mkdir -p -m 700 -- "$status_dir" 2>/dev/null || return 0
  printf '{"kind":"%s","rc":%d,"at":%s,"message":"%s"}\n' \
    "$action" "$1" "$(date +%s%3N)" "$(json_text "$2")" >"$status_dir/status.json.tmp" &&
    mv -f -- "$status_dir/status.json.tmp" "$status_dir/status.json"
}
trap 'rc=$?; ((rc)) && report "$rc" "$action failed, see the newest log"' EXIT

# Keep the 30 newest logs.
find "$log_dir" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\n' |
  sort -rn | tail -n +31 | cut -d' ' -f2- | xargs -r -d '\n' rm -f --

# FreeRDP logs why a session ends at INFO level; WARN (the default) hides it.
export WLOG_LEVEL=INFO
# The launcher runs `xfreerdp3` by name: this shim adds auto-reconnect.
export PATH="$here/bin/shim:$PATH"

echo "== $(date '+%F %T') $action ${keep_alive[*]}"

vm_running() {
  "$here/bin/Sample.sh" --state | grep -q '"running":true'
}

# The container can be up before qemu is (Windows still starting). Only
# answerable with Docker access; without it, count on qemu alone.
container_up() {
  [[ $(docker inspect --format '{{.State.Running}}' omarchy-windows 2>/dev/null) == true ]]
}

rdp_windows() {
  hyprctl clients -j 2>/dev/null |
    jq -r '.[] | select(.title == "Windows VM - Omarchy") | .address' 2>/dev/null |
    grep -E '^0x[0-9a-fA-F]+$' || true
}

close_rdp_windows() {
  local address
  for address in $(rdp_windows); do
    echo "closing RDP window $address"
    hyprctl dispatch "hl.dsp.window.close({ window = \"address:$address\" })" >/dev/null 2>&1 ||
      hyprctl dispatch closewindow "address:$address" >/dev/null 2>&1 || true
  done
}

# Launchers of this user waiting on their RDP window (an xfreerdp3 child)
# without --keep-alive: they stop the VM themselves once that window closes.
# One still at its password prompt or booting the VM doesn't count.
# Matched on exact arguments: `bash /usr/bin/omarchy-windows-vm launch [flag]`.
waiting_launchers() {
  local pid argv
  for pid in $(pgrep -u "$UID" -f omarchy-windows-vm || true); do
    mapfile -t argv < <(tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null)
    [[ ${argv[1]:-} == */omarchy-windows-vm ]] || continue
    [[ ${argv[2]:-} == launch || ${argv[2]:-} == start ]] || continue
    [[ ${argv[3]:-} == --keep-alive || ${argv[3]:-} == -k ]] && continue
    pgrep -P "$pid" -x xfreerdp3 >/dev/null || continue
    echo "$pid"
  done
}

wait_for() { # seconds, command...
  local limit=$1 i
  shift
  for ((i = 0; i < limit; i++)); do
    "$@" && return 0
    sleep 1
  done
  return 1
}

no_waiting_launchers() { [[ -z $(waiting_launchers) ]]; }
vm_stopped() { ! vm_running && ! container_up; }

# Close every RDP window first. A launcher still waiting on its window then
# stops the VM itself; stopping underneath it would make it ask for a
# password again, and its late `down` could hit a VM started after it.
stop_vm() {
  local waiting
  waiting=$(waiting_launchers)
  close_rdp_windows
  if [[ -n $waiting ]]; then
    echo "handing the stop to waiting launcher(s): $waiting"
    wait_for 180 no_waiting_launchers || echo "launcher still waiting after 180s"
  fi
  if vm_running || container_up; then
    omarchy-windows-vm stop || { echo "stop declined or failed"; exit 1; }
  fi
  wait_for 180 vm_stopped || { echo "VM still running after 180s"; exit 1; }
}

# Omarchy's launcher requires ~/Windows to be mode 700, but Dockur's Samba sets
# the setgid bit, which `chmod 0700` keeps (omacom/omarchy#10256). Clear only
# that bit on the user's own directory so the launcher's own check passes.
fix_shared_dir() {
  local shared="$HOME/Windows"
  if [[ -d $shared && ! -L $shared && -O $shared ]]; then
    chmod g-s -- "$shared"
  fi
}

case $action in
stop)
  stop_vm
  ;;
restart)
  stop_vm
  fix_shared_dir
  omarchy-windows-vm launch "${keep_alive[@]}"
  ;;
launch)
  fix_shared_dir
  omarchy-windows-vm launch "${keep_alive[@]}"
  ;;
esac
