#!/bin/bash
# heavy-guard: CPU, GPU and disk thermal guard. Token-free, run every 30 s by heavy-guard.timer.
#  CPU:  freeze heavy.slice at >= CPU_FREEZE_C (default CPU_MAX_C-2), thaw at <= CPU_THAW_C (default CPU_MAX_C-8).
#  GPU:  per card in gpus.conf with a numeric cap: at >= GPU_GUARD_HOT step the power limit down 10 W (to the card minimum);
#        at <= GPU_GUARD_COOL step it back up to the cap.
#  NVMe: alarm at >= NVME_HOT_C.
#  SAS:  for the drives listed in SAS_DRIVES (e.g. "sda sdb sdc"): at >= SAS_WARN_C freeze heavy.slice, pause a running
#        zpool scrub and alarm; resume at <= SAS_RESUME_C. If SAS_POOL is set, drives are only probed while that pool is
#        imported, so spun-down drives are never woken.
# Also calls ram-guard (same directory) on every run. TEMP_C overrides the CPU sensor for tests.
case ${1-} in -h|--help) echo "usage: heavy-guard.sh   (configuration: rigwatch.conf, see README; --help exits 2 without side effects)"; exit 2;; esac
. "$(dirname "$(readlink -f "$0")")/rigwatch-conf.sh"
: "${SAS_DRIVES:=}"; : "${SAS_POOL:=}"
: "${FREEZE_SLICE:=heavy.slice}"
: "${STATSD_ADDR:=}"   # optional host:port; gauges are sent over UDP in statsd format
D=$RIGWATCH_STATE_DIR; ST=$D/heavy-guard.state; SST=$D/heavy-guard.sas.state; LOG=$D/heavy-guard.log; mkdir -p "$D"
H=$NODE_NAME
alarm() { echo "$(date '+%F %H:%M') $H heavy-guard: $1" >> "$LOG"; rw_alarm heavy-guard "$1"; }
timeout 20 "$(dirname "$(readlink -f "$0")")/ram-guard" >/dev/null 2>&1 || true
emit() { [ -n "$STATSD_ADDR" ] && echo "$1:$2|g" > "/dev/udp/${STATSD_ADDR%:*}/${STATSD_ADDR#*:}"; } 2>/dev/null
# --- CPU
t=${TEMP_C:-$(sensors 2>/dev/null | grep -oP '^(?:Tctl|Package id 0):\s*\+\K[0-9.]+' | head -1)}
if [ -n "$t" ]; then ti=${t%.*}
  if [ "$ti" -ge "$CPU_FREEZE_C" ] && [ ! -e "$ST" ]; then
    systemctl --user freeze "$FREEZE_SLICE" && touch "$ST" && alarm "CPU ${t}C >= ${CPU_FREEZE_C}C, $FREEZE_SLICE FROZEN"
  elif [ "$ti" -le "$CPU_THAW_C" ] && [ -e "$ST" ]; then
    rm -f "$ST"; [ -e "$SST" ] || [ -e "$D/thermal-mesh/frozen" ] || systemctl --user thaw "$FREEZE_SLICE"
    alarm "CPU ${t}C <= ${CPU_THAW_C}C, $FREEZE_SLICE thawed"
  fi
fi
# --- GPU
Q="--query-gpu=temperature.gpu,power.limit,power.min_limit --format=csv,noheader,nounits"
rw_gpu_lines | while IFS='|' read -r lbl via cap dom; do
  [ -n "$cap" ] || continue
  case $via in
    local:*) i=${via#local:}; out=$(nvidia-smi -i "$i" $Q 2>/dev/null); set_pl() { sudo -n nvidia-smi -i "$i" -pl "$1" >/dev/null 2>&1; } ;;
    ssh:*)   h=${via#ssh:}; out=$(rw_ssh "$h" "nvidia-smi $Q" 2>/dev/null); set_pl() { rw_ssh "$h" "sudo -n nvidia-smi -pl $1" >/dev/null 2>&1; } ;;
    *) continue ;;
  esac
  IFS=', ' read -r gt pl mn <<<"$out"; [ -n "$gt" ] || continue
  gt=${gt%.*}; pl=${pl%.*}; mn=${mn%.*}
  emit "gpu.${lbl//-/_}.temp" "$gt"; emit "gpu.${lbl//-/_}.watts" "$pl"
  [ "$cap" = - ] && continue
  if [ "$gt" -ge "$GPU_GUARD_HOT" ] && [ "$pl" -gt "$mn" ]; then
    n=$((pl-10)); [ $n -lt "$mn" ] && n=$mn; set_pl $n && alarm "GPU $lbl ${gt}C >= ${GPU_GUARD_HOT}C, power limit ${pl}W -> ${n}W"
  elif [ "$gt" -le "$GPU_GUARD_COOL" ] && [ "$pl" -lt "$cap" ]; then
    n=$((pl+10)); [ $n -gt "$cap" ] && n=$cap; set_pl $n && echo "$(date '+%F %H:%M') $H heavy-guard: GPU $lbl ${gt}C, limit ${pl}W -> ${n}W (cap ${cap}W)" >> "$LOG"
  fi
done
# --- disk: NVMe
nv=$(sensors 2>/dev/null | awk '/^nvme-/{f=1} f&&/Composite/{gsub(/[+°C]/,"",$2); print int($2); exit}')
[ -n "$nv" ] && emit nvme.temp "$nv"
if [ -n "$nv" ] && [ "$nv" -ge "$NVME_HOT_C" ] && [ ! -e "$D/heavy-guard.nvme.state" ]; then touch "$D/heavy-guard.nvme.state"; alarm "NVMe ${nv}C >= ${NVME_HOT_C}C"
elif [ -n "$nv" ] && [ "$nv" -lt $((NVME_HOT_C-6)) ]; then rm -f "$D/heavy-guard.nvme.state"; fi
# --- disk: SAS (never wake spun-down drives)
if [ -n "$SAS_DRIVES" ] && { [ -z "$SAS_POOL" ] || { command -v zpool >/dev/null && sudo -n zpool list -H "$SAS_POOL" >/dev/null 2>&1; }; }; then
  mx=0; for d in $SAS_DRIVES; do
    dt=$(sudo -n smartctl -d scsi -A "/dev/$d" 2>/dev/null | awk -F: '/Current Drive Temperature/{gsub(/[^0-9]/,"",$2); print $2}')
    [ -n "$dt" ] && { emit "sas.$d.temp" "$dt"; [ "$dt" -gt "$mx" ] && mx=$dt; }
  done
  if [ "$mx" -ge "$SAS_WARN_C" ] && [ ! -e "$SST" ]; then
    : > "$SST"; systemctl --user freeze "$FREEZE_SLICE"
    if [ -n "$SAS_POOL" ] && sudo -n zpool status "$SAS_POOL" 2>/dev/null | grep -q 'scrub in progress'; then echo scrub > "$SST"; sudo -n zpool scrub -p "$SAS_POOL" >/dev/null 2>&1; fi
    alarm "SAS ${mx}C >= ${SAS_WARN_C}C, $FREEZE_SLICE FROZEN, scrub paused"
  elif [ "$mx" -gt 0 ] && [ "$mx" -le "$SAS_RESUME_C" ] && [ -e "$SST" ]; then
    sc=$(cat "$SST"); rm -f "$SST"; [ -e "$ST" ] || [ -e "$D/thermal-mesh/frozen" ] || systemctl --user thaw "$FREEZE_SLICE"
    [ "$sc" = scrub ] && sudo -n zpool scrub "$SAS_POOL" >/dev/null 2>&1; alarm "SAS ${mx}C <= ${SAS_RESUME_C}C, $FREEZE_SLICE thawed, scrub resumed"
  fi
fi
exit 0
