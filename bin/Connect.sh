#!/usr/bin/env bash
# Opens an RDP window to the Windows VM when it is already running, without
# going through `omarchy-windows-vm launch`, which would re-run the privileged
# bring-up (and may ask for a password) just to reconnect.
#
# Uses the credentials Omarchy's installer saved and the launcher's own flags,
# plus auto-reconnect. Arguments reach FreeRDP through a file descriptor, so
# the password is never on a command line. Closing this window never stops
# the VM. Output is logged next to the plugin's other logs.
#
# Idea and credential handling adapted from bin/winvm-connect in
# jonspinks/omarchy-winvm (MIT, Copyright (c) 2026 Jon Spinks, commit
# 7d62aab). See NOTICE.

set -u

umask 077
log_dir="${XDG_STATE_HOME:-$HOME/.local/state}/windows-vm/logs"
mkdir -p -m 700 -- "$log_dir"
chmod 700 -- "$log_dir"
exec >>"$log_dir/connect-$(date +%Y%m%d-%H%M%S).log" 2>&1
echo "== $(date '+%F %T') connect"

json_text() { local t=${1//\\/\\\\}; t=${t//\"/\\\"}; printf '%s' "${t//$'\n'/ }"; }

# Tells the plugin why a connection couldn't start, so the panel says so at once.
fail() {
  echo "$1"
  local dir="${XDG_RUNTIME_DIR:-/tmp}/windows-vm"
  if mkdir -p -m 700 -- "$dir" 2>/dev/null; then
    printf '{"kind":"connect","rc":1,"at":%s,"message":"%s"}\n' "$(date +%s%3N)" "$(json_text "$1")" \
      >"$dir/status.json.tmp" && mv -f -- "$dir/status.json.tmp" "$dir/status.json"
  fi
  notify-send -u critical "Windows VM" "$1" 2>/dev/null
  exit 1
}

# Windows allows one session. Another client that is connecting or
# reconnecting (even with no window yet) would be kicked, then kick back.
if pgrep -u "$UID" -x xfreerdp3 >/dev/null; then
  fail "An RDP session to Windows is already open or reconnecting."
fi

credentials="$HOME/.config/windows/credentials"
read_credential() {
  local want=$1 key value
  [[ -f $credentials ]] || return 1
  while IFS='=' read -r key value; do
    [[ $key == "$want" ]] && { printf '%s' "$value"; return 0; }
  done <"$credentials"
  return 1
}

# No guessing the image's well-known default password.
if ! user=$(read_credential USERNAME) || ! pass=$(read_credential PASSWORD) ||
  [[ -z $user || -z $pass ]]; then
  fail "No saved Windows credentials in ~/.config/windows/credentials. Start Windows with: omarchy-windows-vm launch"
fi
if [[ $user == *$'\n'* || $pass == *$'\n'* ]]; then
  fail "The saved Windows credentials can't be used for a direct connection. Use: omarchy-windows-vm launch"
fi

# Same realm-less Kerberos config as the launcher: without it FreeRDP looks
# for MIT's KDC and hangs when offline.
krb5="$HOME/.config/windows/krb5.conf"
if [[ ! -f $krb5 ]]; then
  mkdir -p -- "${krb5%/*}"
  printf '[libdefaults]\n  dns_lookup_kdc = false\n  dns_lookup_realm = false\n' >"$krb5"
fi
export KRB5_CONFIG=$krb5
export WLOG_LEVEL=INFO

# Match the launcher's scaling, so a reconnect looks like a launch.
scale=$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.focused == true) | .scale' 2>/dev/null)
pct=$(awk -v s="${scale:-1}" 'BEGIN { print int(s * 100) }')
rdp_scale=""
if ((pct >= 170)); then rdp_scale=/scale:180
elif ((pct >= 130)); then rdp_scale=/scale:140
fi

# /cert:ignore is safe only because the target is always the local container.
exec 3< <(printf '%s\n' \
  "/u:$user" "/p:$pass" /v:127.0.0.1:3389 -grab-keyboard /sound /microphone /clipboard \
  /cert:ignore "/title:Windows VM - Omarchy" /dynamic-resolution /gfx:AVC444 \
  /floatbar:sticky:off,default:visible,show:fullscreen \
  /auto-reconnect /auto-reconnect-max-retries:5 ${rdp_scale:+"$rdp_scale"})
unset pass

real=/usr/bin/xfreerdp3
[[ -x $real ]] || real=$(command -v xfreerdp3) || fail "FreeRDP (xfreerdp3) is not installed."
exec "$real" /args-from:fd:3
