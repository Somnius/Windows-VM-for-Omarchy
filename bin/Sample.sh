#!/usr/bin/env bash
# One JSON line describing the running Windows VM, read without privileges
# (no docker group, no sudo): the container's cgroup has CPU, memory and I/O
# counters, and the qemu process's /proc entry has its network namespace and
# its own command line (vCPUs and RAM given to the guest).
#
# Counters are raw and cumulative; the plugin keeps the previous sample and
# computes rates, so a dropped tick costs one refresh, not a wrong number.
#
# Adapted from bin/winvm-sample in jonspinks/omarchy-winvm (MIT,
# Copyright (c) 2026 Jon Spinks, commit 7d62aab). See NOTICE.

set -u
shopt -s nullglob

# --state: only whether Windows runs, and since when. This is all the plugin
# asks for while its panel is closed; counters are read only while it's open.
state_only=false
[[ ${1:-} == --state ]] && state_only=true

# dockurr/windows starts qemu with `-name Windows,process=windows`, so the
# guest's comm is "windows". Look in the cgroup of each Docker container:
# systemd driver (system.slice/docker-<id>.scope) or cgroupfs (docker/<id>).
pid="" scope="" cid=""
for s in /sys/fs/cgroup/system.slice/docker-*.scope /sys/fs/cgroup/docker/*/; do
  s=${s%/}
  [[ -r $s/cgroup.procs ]] || continue
  while read -r p; do
    [[ -r /proc/$p/comm && $(<"/proc/$p/comm") == windows ]] || continue
    exe=$(tr '\0' '\n' <"/proc/$p/cmdline" 2>/dev/null | head -1)
    [[ $exe == qemu-system-* || $exe == */qemu-system-* ]] || continue
    pid=$p scope=$s
    break 2
  done <"$s/cgroup.procs" 2>/dev/null
done

if [[ -z $pid ]]; then
  printf '{"running":false}\n'
  exit 0
fi

# Uptime from qemu's start time (field 22 of /proc/<pid>/stat, in clock ticks).
start_ticks=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)
uptime_s=$(awk -v st="${start_ticks:-0}" -v hz="$(getconf CLK_TCK)" '{printf "%d", $1 - st/hz}' /proc/uptime)

if $state_only; then
  printf '{"running":true,"uptime":%d}\n' "${uptime_s:-0}"
  exit 0
fi

cid=${scope##*/}
cid=${cid#docker-}
cid=${cid%.scope}

cpu_usec=$(awk '$1=="usage_usec"{print $2}' "$scope/cpu.stat" 2>/dev/null)
mem_bytes=$(cat "$scope/memory.current" 2>/dev/null)

# io.stat can list a disk and the dm-crypt device on top of it with the same
# bytes; summing would double-count, so take the busiest single device.
read -r io_read io_write < <(awk '
  { r=0; w=0
    for (i=2;i<=NF;i++) { split($i,kv,"="); if (kv[1]=="rbytes") r=kv[2]; if (kv[1]=="wbytes") w=kv[2] }
    if (r+w > best) { best=r+w; br=r; bw=w } }
  END { printf "%d %d\n", br, bw }' "$scope/io.stat" 2>/dev/null)

# eth0 in qemu's network namespace is the guest's uplink:
# rx = what the guest downloaded, tx = what it sent.
read -r net_rx net_tx < <(awk -F'[: ]+' '$2=="eth0"{print $3, $11}' "/proc/$pid/net/dev" 2>/dev/null)

# The guest's allocation, from qemu's own arguments: `-smp 8,...` and `-m 16G`.
mapfile -t args < <(tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null)
vcpus=0 ram=""
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
  -smp) vcpus=${args[i + 1]%%,*} ;;
  -m) ram=${args[i + 1]%%,*} ;;
  esac
done
case $ram in
*[Gg]) ram_bytes=$((${ram%?} * 1024 * 1024 * 1024)) ;;
*[Mm]) ram_bytes=$((${ram%?} * 1024 * 1024)) ;;
*[0-9]) ram_bytes=$((ram * 1024 * 1024)) ;; # qemu's default unit is MiB
*) ram_bytes=0 ;;
esac
[[ $vcpus =~ ^[0-9]+$ ]] || vcpus=0

# The sparse disk image: apparent size is the virtual disk, allocated blocks
# are what Windows has written so far. Omarchy keeps it in ~/.windows.
img="$HOME/.windows/data.img"
disk_size=0 disk_used=0
if [[ -f $img && -r $img ]]; then
  read -r disk_size blocks < <(stat -c '%s %b' "$img")
  disk_used=$((blocks * 512))
fi

host_cores=$(nproc)
host_mem=$(awk '/^MemTotal:/{print $2 * 1024}' /proc/meminfo)

printf '{"running":true,"container":"%s","cpuUsec":%d,"memBytes":%d,"ioRead":%d,"ioWrite":%d,"netRx":%d,"netTx":%d,"vcpus":%d,"ramBytes":%d,"uptime":%d,"diskSize":%d,"diskUsed":%d,"hostCores":%d,"hostMem":%d}\n' \
  "${cid:0:12}" "${cpu_usec:-0}" "${mem_bytes:-0}" "${io_read:-0}" "${io_write:-0}" \
  "${net_rx:-0}" "${net_tx:-0}" "$vcpus" "$ram_bytes" "${uptime_s:-0}" "$disk_size" "$disk_used" \
  "$host_cores" "${host_mem:-0}"
