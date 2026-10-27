#!/bin/bash
# hwwatch.sh: hardware watchdog, run every minute by hwwatch.timer. Appends one ALERT line per anomaly to ALERT_FILE
# (deduplicated for an hour) and writes the latest GPU readings to $RIGWATCH_STATE_DIR/last.csv.
# Checks: GPU temperature (alert and critical levels), hardware slowdown flags, power limit above the configured cap,
# GPU count below expectation, CPU temperature, an optional fan-control service, disk fill level and fast disk fill.
# GPUs in VMs are listed from the inventory (gpus.conf) and read over ssh. Per-node rows written by thermal-mesh.sh
# (directory $RIGWATCH_STATE_DIR/mesh/*.row) are appended to last.csv.
case ${1-} in -h|--help) echo "usage: hwwatch.sh   (configuration: rigwatch.conf, see README; --help exits 2 without side effects)"; exit 2;; esac
. "$(dirname "$(readlink -f "$0")")/rigwatch-conf.sh"
: "${EXPECT_HOST_GPUS:=0}"              # GPUs expected on the host NVIDIA driver; fewer is an ALERT
: "${FAN_SERVICE:=}"                    # optional systemd unit that must be active (a fan-curve daemon); empty disables the check
: "${DISK_PATHS:=/}"                    # space-separated mount points to check for fill level
: "${DISK_ALERT_PCT:=85}"
: "${DISK_FILL_GB_10MIN:=15}"           # alert when the first DISK_PATH loses this many GB within 10 minutes
STATE=$RIGWATCH_STATE_DIR/last.csv; RECENT=$RIGWATCH_STATE_DIR/.recent; DF=$RIGWATCH_STATE_DIR/.diskfree
mkdir -p "$RIGWATCH_STATE_DIR"
ts=$(rw_now)
alert(){ grep -qF "$1" "$RECENT" 2>/dev/null || { rw_alert "$1"; echo "$1" >> "$RECENT"; }; }
find "$RECENT" -mmin +60 -delete 2>/dev/null   # de-duplicate within an hour

# --- GPUs
q=""
if rw_gpu_busy; then
  q=$(grep -E '^[0-9]+,' "$STATE" 2>/dev/null); echo "$ts" > "$STATE"; echo "$q" >> "$STATE"
elif [ "$EXPECT_HOST_GPUS" -le 0 ]; then
  # no host GPU in use: record the VM GPU temperatures instead of running a failing nvidia-smi
  echo "$ts" > "$STATE"
  while IFS='|' read -r lbl via cap dom; do
    case $via in ssh:*) t=$(RW_SSH_TIMEOUT=5 rw_ssh "${via#ssh:}" "nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits" 2>/dev/null | head -1 | tr -d ' ')
      echo "vm,$lbl,${t:-na}" >> "$STATE";; esac
  done < <(rw_gpu_lines)
else
  q=$(nvidia-smi --query-gpu=index,name,temperature.gpu,power.draw,power.limit,pcie.link.gen.current,pcie.link.width.current,clocks_throttle_reasons.hw_slowdown,clocks_throttle_reasons.hw_thermal_slowdown,fan.speed --format=csv,noheader,nounits 2>&1)
  # nvidia-smi failing must not skip the CPU, fan and disk checks below.
  if [ $? -ne 0 ]; then alert "nvidia-smi failed: $(echo "$q" | head -1)"; echo "$ts" > "$STATE"; echo "nvidia-smi failed" >> "$STATE"; q=""
  else echo "$ts" > "$STATE"; echo "$q" >> "$STATE"; fi
fi
cat "$RIGWATCH_STATE_DIR"/mesh/*.row >> "$STATE" 2>/dev/null
echo "$q" | grep -viE '^[0-9]+,' | grep -v '^$' | while read -r e; do alert "GPU error: $e"; done
q=$(echo "$q" | grep -E '^[0-9]+,')
n=$(echo "$q" | grep -c .)
[ "$EXPECT_HOST_GPUS" -gt 0 ] && [ "$n" -lt "$EXPECT_HOST_GPUS" ] && alert "GPU count $n < $EXPECT_HOST_GPUS (card dropped off the bus?)"
# per-card power ceiling from the inventory: local:INDEX entries with a numeric cap
declare -A CAP; while IFS='|' read -r lbl via cap dom; do case $via in local:*) [[ $cap =~ ^[0-9]+$ ]] && CAP[${via#local:}]=$cap;; esac; done < <(rw_gpu_lines)
while IFS=', ' read -r idx rest; do
  [ -n "$idx" ] || continue
  IFS=',' read -r name t p pl gen w hws hwt fan <<<"$rest"
  t=${t// /}; p=${p// /}; pl=${pl// /}
  [ "${t%.*}" -ge "$GPU_ALERT_CRIT" ] 2>/dev/null && alert "GPU$idx$name CRITICAL temp ${t}C"
  [ "${t%.*}" -ge "$GPU_ALERT_HOT" ] 2>/dev/null && alert "GPU$idx$name hot ${t}C"
  [ "${hws// /}" = "Active" ] && alert "GPU$idx$name HW slowdown active (power/thermal/memory)"
  [ "${hwt// /}" = "Active" ] && alert "GPU$idx$name HW thermal slowdown active"
  cap=${CAP[$idx]:-}
  [ -n "$cap" ] && [ "${pl%.*}" -gt "$cap" ] 2>/dev/null && alert "GPU$idx$name power limit ${pl}W exceeds ceiling ${cap}W"
done <<<"$q"
# --- CPU (AMD k10temp Tctl, or Intel coretemp package)
t=$(sensors 2>/dev/null | awk '/^(Tctl|Package id 0):/{gsub(/[+°C]/,"",$2); print int($2); exit}')
[ -n "$t" ] && [ "$t" -ge "$CPU_ALERT_HOT" ] && alert "CPU temperature ${t}C"
# --- fan-control service
[ -n "$FAN_SERVICE" ] && { systemctl is-active -q "$FAN_SERVICE" || systemctl --user is-active -q "$FAN_SERVICE" || alert "$FAN_SERVICE not active (fans on firmware control)"; }
# --- disk fill level, and fast fill of the first path
for m in $DISK_PATHS; do
  u=$(df --output=pcent "$m" 2>/dev/null | tail -1 | tr -dc 0-9); [ -n "$u" ] && [ "$u" -ge "$DISK_ALERT_PCT" ] && alert "disk $m ${u}% full"
done
m1=${DISK_PATHS%% *}; f=$(( $(df --output=avail -m "$m1" | tail -1) / 1024 ))
echo "$(date +%s) $f" >> "$DF"; tail -n 15 "$DF" > "$DF.t" && mv "$DF.t" "$DF"
old=$(awk -v c="$(date +%s)" 'c-$1<=660{print $2; exit}' "$DF")
[ -n "$old" ] && [ $(( old - f )) -ge "$DISK_FILL_GB_10MIN" ] && alert "disk $m1 filling fast: $(( old - f )) GB in 10 min, ${f} GB free"
exit 0  # the last check is a "test && alert"; without this a passing check would make the unit report failure
