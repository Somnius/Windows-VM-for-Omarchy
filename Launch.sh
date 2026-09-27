#!/usr/bin/env bash
# Runs one Windows VM action for the plugin and keeps its output.
#   Launch.sh launch  [keep]   start the VM if needed and open RDP
#   Launch.sh restart [keep]   shut Windows down cleanly, then launch again
#   Launch.sh stop             shut Windows down cleanly
# With "keep", the VM stays up when the RDP window closes; without it, closing
# RDP shuts Windows down (Omarchy's default).
# The plugin starts this detached via uwsm, so RDP survives shell restarts.
set -euo pipefail

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

log_dir="${XDG_STATE_HOME:-$HOME/.local/state}/windows-vm/logs"
mkdir -p -m 700 -- "$log_dir"
exec >>"$log_dir/$action-$(date +%Y%m%d-%H%M%S).log" 2>&1

# Keep the 30 newest logs.
find "$log_dir" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\n' |
  sort -rn | tail -n +31 | cut -d' ' -f2- | xargs -r -d '\n' rm -f --

# FreeRDP logs why a session ends at INFO level; WARN (the default) hides it.
export WLOG_LEVEL=INFO

echo "== $(date '+%F %T') $action ${keep_alive[*]}"

# Omarchy's launcher requires ~/Windows to be mode 700, but Dockur's Samba sets
# the setgid bit, which `chmod 0700` keeps (omacom/omarchy#10256). Clear only
# that bit on the user's own directory so the launcher's own check passes.
shared="$HOME/Windows"
if [[ $action != stop && -d $shared && ! -L $shared && -O $shared ]]; then
  chmod g-s -- "$shared"
fi

case $action in
stop)
  exec omarchy-windows-vm stop
  ;;
restart)
  omarchy-windows-vm stop
  exec omarchy-windows-vm launch "${keep_alive[@]}"
  ;;
launch)
  exec omarchy-windows-vm launch "${keep_alive[@]}"
  ;;
esac
