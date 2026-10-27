#!/bin/bash
# emergency.sh: fire-risk cutoff. Token-free, run every 30 s by emergency.timer.
# - Any device at or above HARD_MAX (default 100 C): power off at once, no second strike.
# - Any device at or above its cutoff (CPU_CUTOFF, GPU_CUTOFF, RAM_CUTOFF) on 2 consecutive runs: ALERT line, 20 s, power off.
# - An unreadable GPU temperature is treated as unsafe: ALERT line (deduplicated, BLIND_EVERY seconds), never a power off
#   on blindness alone, so a dead sensor cannot boot-loop the machine.
# Limits are set far above normal peaks; the ordinary thermal limits are enforced by gputemp-guard and heavy-guard.
# Test hooks: EMERGENCY_DRY=1 (log, do not power off), EMERGENCY_FAKE_GPU="idx,temp" lines for host GPUs,
# EMERGENCY_FAKE_VM="label=temp ..." for VM GPUs, EMERGENCY_FAKE_DOMSTATE (libvirt state used for every VM).
case ${1-} in -h|--help) echo "usage: emergency.sh   (configuration: rigwatch.conf, see README; --help exits 2 without side effects)"; exit 2;; esac
. "$(dirname "$(readlink -f "$0")")/rigwatch-conf.sh"
: "${EXPECTED_HOST_GPUS:=0}"          # number of GPUs expected on the host driver; fewer is an ALERT, never a power off
: "${EMERGENCY_STRIKES:=${XDG_RUNTIME_DIR:-/tmp}/rigwatch-emergency.strikes}"
: "${BLIND_DIR:=${XDG_RUNTIME_DIR:-/tmp}/rigwatch-emergency.blind}"
: "${BLIND_EVERY:=3600}"
A=$ALERT_FILE; S=$EMERGENCY_STRIKES
bad=""; hot=""; blind=""
dstate() { if [ -n "${EMERGENCY_FAKE_DOMSTATE+x}" ]; then echo "$EMERGENCY_FAKE_DOMSTATE"; else virsh -c qemu:///system domstate "$1" 2>/dev/null; fi; }
num() { [[ "$1" =~ ^[0-9]+$ ]]; }
hard() { [ "$2" -ge "$HARD_MAX" ] 2>/dev/null && hot+="$1 $2C; "; }
# CPU (AMD Tctl) and RAM (spd5118 SPD hub sensors)
for l in /sys/class/hwmon/hwmon*/temp*_label; do [ -r "$l" ] && [ "$(cat "$l")" = Tctl ] && c=$(( $(cat "${l%_label}_input")/1000 )) && { hard CPU "$c"; [ "$c" -ge "$CPU_CUTOFF" ] && bad+="CPU ${c}C; "; }; done
for d in /sys/class/hwmon/hwmon*; do [ "$(cat "$d/name" 2>/dev/null)" = spd5118 ] && r=$(( $(cat "$d/temp1_input")/1000 )) && { hard RAM "$r"; [ "$r" -ge "$RAM_CUTOFF" ] && bad+="RAM ${r}C; "; }; done
# host GPUs
GPU_BUSY=0; rw_gpu_busy && GPU_BUSY=1
gn=0
while IFS=, read -r i t; do gn=$((gn+1)); num "${t// /}" || { blind+="GPU${i// /} '${t// /}'; "; continue; }
  hard "GPU$i" "${t// /}"; [ "${t// /}" -ge "$GPU_CUTOFF" ] 2>/dev/null && bad+="GPU$i ${t// /}C; "
done < <(if [ -n "$EMERGENCY_FAKE_GPU" ]; then echo "$EMERGENCY_FAKE_GPU"
         elif [ "$GPU_BUSY" = 1 ] || [ "$EXPECTED_HOST_GPUS" = 0 ] || ! rw_host_gpu_present; then :
         else timeout 10 nvidia-smi --query-gpu=index,temperature.gpu --format=csv,noheader,nounits; fi)
[ "$gn" -eq 0 ] && [ "$GPU_BUSY" = 0 ] && [ "$EXPECTED_HOST_GPUS" != 0 ] && blind+="GPUhost no-nvidia-smi-output; "
[ "$gn" -gt 0 ] && [ "$gn" -lt "$EXPECTED_HOST_GPUS" ] && blind+="GPUcount host-has-$gn-expected-$EXPECTED_HOST_GPUS; "
# GPUs passed through to VMs: read over ssh (5 s timeout). A VM that is shut off is skipped quietly; a running VM that stays silent is a blind alert.
while IFS='|' read -r lbl via cap dom; do
  case $via in ssh:*) ;; *) continue;; esac
  if [ -n "${EMERGENCY_FAKE_VM+x}" ]; then
    vt=$(tr ' ' '\n' <<<"$EMERGENCY_FAKE_VM" | sed -n "s/^$lbl=//p" | head -1)
  else
    vt=$(RW_SSH_TIMEOUT=5 rw_ssh "${via#ssh:}" "nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits" 2>/dev/null | head -1 | tr -d ' ')
  fi
  [ -n "$dom" ] && [ "$(dstate "$dom")" = "shut off" ] && continue
  num "$vt" || { blind+="GPU${lbl//[^A-Za-z0-9]/_}vm '${vt:-none}'; "; continue; }
  hard "GPU$lbl" "$vt"; [ "$vt" -ge "$GPU_CUTOFF" ] 2>/dev/null && bad+="GPU$lbl ${vt}C; "
done < <(rw_gpu_lines)
if [ -n "$blind" ]; then
  mkdir -p "$BLIND_DIR"; now=$(date +%s); new=""
  IFS=';' read -ra BL <<< "$blind"
  for b in "${BL[@]}"; do b="${b# }"; [ -z "$b" ] && continue; k=${b%% *}; f="$BLIND_DIR/$k"
    last=$(cat "$f" 2>/dev/null || echo 0); [ $((now-last)) -ge "$BLIND_EVERY" ] && { new+="$b; "; echo "$now" > "$f"; }; done
  [ -n "$new" ] && { mkdir -p "$(dirname "$A")"; echo "$(rw_now) ALERT EMERGENCY-BLIND GPU temp unreadable, treated unsafe: $new" >> "$A"; }
fi
mkdir -p "$(dirname "$A")" "$(dirname "$S")"
if [ -n "$hot" ]; then
  echo "$(rw_now) EMERGENCY fire-risk IMMEDIATE: $hot powering off now" >> "$A"
  [ -n "$EMERGENCY_DRY" ] && exit 0
  sync; $POWEROFF_CMD; exit 0
fi
[ -z "$bad" ] && { rm -f "$S"; exit 0; }
n=$(( $(cat "$S" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$S"
[ "$n" -lt 2 ] && exit 0
echo "$(rw_now) EMERGENCY fire-risk: $bad powering off in 20 s" >> "$A"
[ -n "$EMERGENCY_DRY" ] && exit 0
sleep 20; sync
$POWEROFF_CMD
