#!/bin/bash
# thermal-mesh: token-free thermal watcher, identical on every node, run every 30 s by thermal-mesh.timer.
# Limits (rigwatch.conf): every CPU, GPU and NVMe under CPU_MAX_C/GPU_MAX_C (default 70 C), SAS drives under SAS_MAX_C (default 60 C).
# It extends heavy-guard.sh and adds graded actions, one status row per node, a per-node alarm log and an ESCALATE rule.
#  warn   (>= MESH_WARN_C, SAS >= SAS_WARN_C): concurrency cap of 1 (file $TM_DIR/concurrency.cap, for your job runner to read),
#         GPU power limit cut to TM_PL_PCT percent (reversible); a SAS warning also writes the no-new-jobs flag.
#  freeze (>= MESH_FREEZE_C, SAS >= SAS_FREEZE_C): systemctl --user freeze of FREEZE_SLICES (default heavy.slice).
#  restore: after 3 consecutive cool readings (every sensor 3 C under its warn level) everything above is undone.
#  ESCALATE: 5 minutes after the first action a sensor is still at or over its warn level, or a sensor is unreadable for 5 minutes.
# Never reboots, never touches a zpool. SAS drives that are spun down report "standby" and are never woken.
# SAS drives to watch: SAS_DRIVES="sda sdb sdc" (empty disables). GPUs come from gpus.conf.
# Multi-node: set MESH_DEST="user@host:/dir" to also push this node's one-line status row to a collector host.
# Test overrides: TM_FAKE_FILE (lines sensor=value, value may be na or standby), TM_FAKE_GPUS, TM_NOW (epoch), TM_DRY=1
# (print actions, run none), TM_DIR (state dir), TM_ALARMS (alarm log path), TM_NODE (node name).
case ${1-} in -h|--help) echo "usage: thermal-mesh.sh   (configuration: rigwatch.conf, see README; --help exits 2 without side effects)"; exit 2;; esac
. "$(dirname "$(readlink -f "$0")")/rigwatch-conf.sh"
set -u
NODE=${TM_NODE:-$NODE_NAME}
: "${SAS_DRIVES:=}"; : "${FREEZE_SLICES:=heavy.slice}"; : "${MESH_DEST:=}"
TM_DIR=${TM_DIR:-$RIGWATCH_STATE_DIR/thermal-mesh}; ALARMS=${TM_ALARMS:-$RIGWATCH_STATE_DIR/thermal-mesh-$NODE.log}
DRY=${TM_DRY:-0}; NOW=${TM_NOW:-$(date +%s)}
WARN=${TM_WARN:-$MESH_WARN_C}; FREEZE=${TM_FREEZE:-$MESH_FREEZE_C}; SAS_WARN=${TM_SAS_WARN:-$SAS_WARN_C}; SAS_FREEZE=${TM_SAS_FREEZE:-$SAS_FREEZE_C}; HYST=${TM_HYST:-3}
ESC_S=${TM_ESC_S:-300}; COOL_N=${TM_COOL_N:-3}; PL_PCT=${TM_PL_PCT:-80}
mkdir -p "$TM_DIR" "$(dirname "$ALARMS")"
exec 9>"$TM_DIR/lock"; flock -n 9 || exit 0
W=$(mktemp -d "$TM_DIR/read.XXXXXX"); trap 'rm -rf "$W"' EXIT
ST=$TM_DIR/state; [ -r "$ST" ] && . "$ST"
LEVEL=${LEVEL:-0}; COOL=${COOL:-0}; SINCE=${SINCE:-0}; ESC=${ESC:-0}; HOT=${HOT:-all}; HOTT=${HOTT:-ok}
SSHN="-o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR"
SLICES=$FREEZE_SLICES

log() { # log <sensor> <temp> <action>: one line per state change
  echo "$(date -d "@$NOW" '+%FT%T%z') $NODE $1 $2 $3" >> "$ALARMS"
  [ "$DRY" = 1 ] && echo "ALARM $(date -d "@$NOW" '+%T') $NODE $1 $2 $3"
  case $3 in *ESCALATE*) [ "$DRY" = 1 ] || { rw_alert "thermal-mesh $NODE $1 $2 $3"; rw_alarm thermal-mesh "$1 $2 $3"; };; esac
}
run() { if [ "$DRY" = 1 ]; then echo "DRY $*" >&2; else "$@"; fi; }

# ---------- read sensors into $W/<name> (parallel, every read bounded) ----------
SENS=()   # expected sensors, in row order
declare -A GVIA GIDX
add() { SENS+=("$1"); }
fake() { [ -n "${TM_FAKE_FILE:-}" ] && [ -r "$TM_FAKE_FILE" ]; }
if fake; then
  while IFS='=' read -r k v; do [ -n "$k" ] && [[ $k != \#* ]] && { add "$k"; echo "$v" > "$W/$k"; }; done < "$TM_FAKE_FILE"
  for g in ${TM_FAKE_GPUS:-}; do GVIA[$g]=fake:$g; done   # fake GPU labels (their temperatures come from the fake file)
else
  add cpu; ( v=$(timeout 5 sensors 2>/dev/null | grep -oP '^(?:Tctl|Package id 0):\s*\+\K[0-9.]+' | head -1); echo "${v%.*}" > "$W/cpu" ) &
  if [ -d /sys/class/nvme ] && [ -n "$(ls /sys/class/nvme 2>/dev/null)" ]; then add nvme
    ( v=$(timeout 5 sensors 2>/dev/null | awk '/^nvme-/{f=1} f&&/Composite/{gsub(/[+°C]/,"",$2); v=int($2); if(v>m)m=v; f=0} END{print m}'); echo "$v" > "$W/nvme" ) &
  fi
  # GPUs: lines "label|local:IDX or ssh:HOST|capW[|libvirt-domain]" in gpus.conf
  if [ -r "$GPU_CONF" ]; then
    while IFS='|' read -r lbl via cap dom; do
      [ -n "${cap:-}" ] || continue; [[ $lbl == \#* ]] && continue
      add "$lbl"; GVIA[$lbl]=$via
      case $via in
        local:*) ( o=$(timeout 8 nvidia-smi -i "${via#local:}" --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1); echo "${o// /}" > "$W/$lbl" ) & ;;
        ssh:*)   ( o=$(rw_ssh "${via#ssh:}" "nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits" 2>/dev/null | head -1)
                   # a stopped VM means its card is idle and unreadable: report "<domain>-shut-off", not a fault (non-numeric values are skipped by the limit checks)
                   if [ -z "$o" ] && [ -n "$dom" ] && [ "$(timeout 8 virsh -c qemu:///system domstate "$dom" 2>/dev/null | head -1)" = "shut off" ]; then o=${dom}-shut-off; fi
                   echo "${o// /}" > "$W/$lbl" ) & ;;
      esac
    done < <(rw_gpu_lines)
  fi
  # SAS drives: a spun-down drive is "standby" and is never woken; a failed or hung read is "na" (10 s timeout)
  if [ -n "$SAS_DRIVES" ]; then for d in $SAS_DRIVES; do add "sas-$d"
    ( g=/dev/$(ls /sys/block/$d/device/scsi_generic/ 2>/dev/null | head -1); timeout 10 sudo -n sg_turs "$g" >/dev/null 2>&1; rc=$?
      if [ $rc = 2 ]; then echo standby > "$W/sas-$d"
      elif [ $rc = 0 ]; then t=$(timeout 10 sudo -n smartctl -d scsi -A "$g" 2>/dev/null | awk -F: '/Current Drive Temperature/{gsub(/[^0-9]/,"",$2); print $2}'); echo "${t:-na}" > "$W/sas-$d"
      else echo na > "$W/sas-$d"; fi ) &
  done; fi
  wait
fi

declare -A T
for s in "${SENS[@]}"; do v=$(cat "$W/$s" 2>/dev/null); v=${v// /}; [[ $v =~ ^[0-9]+(\.[0-9]+)?$ ]] && v=${v%.*}; T[$s]=${v:-na}; done

warn_of() { case $1 in sas-*) echo $SAS_WARN;; *) echo $WARN;; esac; }
frz_of()  { case $1 in sas-*) echo $SAS_FREEZE;; *) echo $FREEZE;; esac; }

# ---------- unreadable tracking (ESCALATE after ESC_S) ----------
for s in "${SENS[@]}"; do k=${s//[^A-Za-z0-9]/_}; v=${T[$s]}
  eval "u=\${UNK_$k:-0}; ue=\${UNKESC_$k:-0}"
  if [ "$v" = na ]; then
    [ "$u" = 0 ] && { u=$NOW; eval "UNK_$k=$u"; }
    if [ "$ue" = 0 ] && [ $((NOW - u)) -ge "$ESC_S" ]; then eval "UNKESC_$k=1"; log "$s" na "ESCALATE sensor unreadable for $((NOW - u)) s, no automatic action possible"; fi
  else
    [ "$ue" = 1 ] && log "$s" "$v" "readable again"
    eval "UNK_$k=0; UNKESC_$k=0"
  fi
done

# ---------- evaluate ----------
newlevel=0; hot=""; hott=0; allcool=1; stillwarn=0; saswarn=0
for s in "${SENS[@]}"; do v=${T[$s]}; [[ $v =~ ^[0-9]+$ ]] || continue
  w=$(warn_of "$s"); f=$(frz_of "$s"); lv=0
  [ "$v" -ge "$w" ] && lv=1; [ "$v" -ge "$f" ] && lv=2
  [ "$v" -ge $((w - HYST)) ] && allcool=0
  [ "$v" -ge "$w" ] && stillwarn=1
  case $s in sas-*) [ "$v" -ge "$w" ] && saswarn=1;; esac
  if [ $lv -gt $newlevel ] || { [ $lv -eq $newlevel ] && [ $lv -gt 0 ] && [ "$v" -gt "$hott" ]; }; then newlevel=$lv; hot=$s; hott=$v; fi
done

CAPF=$TM_DIR/concurrency.cap; NOJOB=$TM_DIR/no-new-jobs; FROZEN=$TM_DIR/frozen
do_gpu_cap() { # cut every GPU to PL_PCT percent of its limit, remember the original
  for s in "${SENS[@]}"; do via=${GVIA[$s]:-}; [ -n "$via" ] || continue; k=${s//[^A-Za-z0-9]/_}
    if [ "$DRY" = 1 ]; then echo "DRY nvidia-smi -pl ${PL_PCT} percent of limit on $s" >&2; eval "PL_$k=300"; continue; fi
    case $via in local:*) q() { timeout 8 nvidia-smi -i "${via#local:}" "$@"; }; set_pl() { timeout 8 sudo -n nvidia-smi -i "${via#local:}" -pl "$1"; };;
                 ssh:*)   q() { rw_ssh "${via#ssh:}" "nvidia-smi $*"; }; set_pl() { rw_ssh "${via#ssh:}" "sudo -n nvidia-smi -pl $1"; };; esac
    IFS=', ' read -r pl mn <<<"$(q --query-gpu=power.limit,power.min_limit --format=csv,noheader,nounits 2>/dev/null)"; pl=${pl%.*}; mn=${mn%.*}
    [[ ${pl:-} =~ ^[0-9]+$ && ${mn:-} =~ ^[0-9]+$ ]] || continue
    eval "[ -n \"\${PL_$k:-}\" ]" && continue   # already capped this episode
    n=$((pl * PL_PCT / 100)); [ $n -lt "$mn" ] && n=$mn
    [ $n -lt "$pl" ] && set_pl "$n" >/dev/null 2>&1 && eval "PL_$k=$pl"
  done
}
do_gpu_restore() {
  for s in "${SENS[@]}"; do via=${GVIA[$s]:-}; [ -n "$via" ] || continue; k=${s//[^A-Za-z0-9]/_}; eval "o=\${PL_$k:-}"; [ -n "$o" ] || continue
    if [ "$DRY" = 1 ]; then echo "DRY nvidia-smi restore power limit of $s" >&2
    else case $via in local:*) timeout 8 sudo -n nvidia-smi -i "${via#local:}" -pl "$o" >/dev/null 2>&1;; ssh:*) rw_ssh "${via#ssh:}" "sudo -n nvidia-smi -pl $o" >/dev/null 2>&1;; esac; fi
    eval "PL_$k="
  done
}
has_gpu() { [ -n "${GVIA[*]:-}" ]; }
act_warn() { # act_warn: concurrency cap, GPU power cap, SAS job stop
  echo 1 > "$CAPF"; [ $saswarn = 1 ] && : > "$NOJOB"
  [ $saswarn = 1 ] || { has_gpu && do_gpu_cap; }
}
act_freeze() { for sl in $SLICES; do run systemctl --user freeze "$sl"; done; : > "$FROZEN"; [ $saswarn = 1 ] && : > "$NOJOB"; return 0; }
act_restore() { for sl in $SLICES; do [ -e "$RIGWATCH_STATE_DIR/heavy-guard.state" ] || [ -e "$RIGWATCH_STATE_DIR/heavy-guard.sas.state" ] || run systemctl --user thaw "$sl"; done
  rm -f "$CAPF" "$NOJOB" "$FROZEN"; has_gpu && do_gpu_restore; }
describe_warn() { if [ $saswarn = 1 ]; then echo "WARN no new jobs (flag), concurrency cap 1"; else echo "WARN concurrency cap 1, GPU power limit ${PL_PCT}%"; fi; }

if [ $newlevel -ge 1 ]; then HOT=$hot; HOTT=$hott; fi
if [ "$LEVEL" = 0 ] && [ $newlevel -ge 1 ]; then
  act_warn; LEVEL=1; COOL=0; ESC=0; SINCE=$NOW
  if [ $newlevel = 2 ]; then act_freeze; LEVEL=2; log "$hot" "$hott" "$(describe_warn); FREEZE ${SLICES// /+}"; else log "$hot" "$hott" "$(describe_warn)"; fi
elif [ "$LEVEL" = 1 ] && [ $newlevel = 2 ]; then
  act_freeze; LEVEL=2; log "$hot" "$hott" "FREEZE ${SLICES// /+}"
elif [ "$LEVEL" -ge 1 ]; then
  if [ $allcool = 1 ]; then COOL=$((COOL + 1)); else COOL=0; fi
  if [ $COOL -ge "$COOL_N" ]; then act_restore; LEVEL=0; COOL=0; ESC=0; SINCE=0; log "$HOT" "$HOTT" "RESTORED after $COOL_N cool readings (thaw, concurrency cap and GPU power limit back)"
  elif [ "$ESC" = 0 ] && [ $stillwarn = 1 ] && [ $((NOW - SINCE)) -ge "$ESC_S" ]; then
    ESC=1; log "${hot:-?}" "${hott:-?}" "ESCALATE automatic action did not bring the sensor under its limit in $((NOW - SINCE)) s"
  fi
fi

# ---------- persist state ----------
{ echo "LEVEL=$LEVEL; COOL=$COOL; SINCE=$SINCE; ESC=$ESC; HOT=$HOT; HOTT=$HOTT"
  for s in "${SENS[@]}"; do k=${s//[^A-Za-z0-9]/_}; eval "echo \"UNK_$k=\${UNK_$k:-0}; UNKESC_$k=\${UNKESC_$k:-0}; PL_$k=\${PL_$k:-}\""; done; } > "$ST.tmp" && mv "$ST.tmp" "$ST"

# ---------- one row per node (local file, optionally pushed to a collector): mesh,<node>,<time>,<state>,<sensor>=<temp>,... ----------
case $LEVEL in 0) state=ok;; 1) state=warn;; *) state=freeze;; esac; [ "$ESC" = 1 ] && state="$state+escalated"
row="mesh,$NODE,$(date -d "@$NOW" '+%F %T'),$state"; for s in "${SENS[@]}"; do row="$row,$s=${T[$s]}"; done
echo "$row" > "$TM_DIR/last.row"
if [ "$DRY" = 1 ]; then echo "ROW $row"
else mkdir -p "$RIGWATCH_STATE_DIR/mesh"; echo "$row" > "$RIGWATCH_STATE_DIR/mesh/$NODE.row.tmp" && mv "$RIGWATCH_STATE_DIR/mesh/$NODE.row.tmp" "$RIGWATCH_STATE_DIR/mesh/$NODE.row"
  if [ -n "$MESH_DEST" ]; then  # push the row to a collector: MESH_DEST=user@host:/dir
    h=${MESH_DEST%%:*}; dd=${MESH_DEST#*:}
    echo "$row" | timeout 8 ssh $SSHN "$h" "mkdir -p '$dd' && cat > '$dd/$NODE.row.tmp' && mv '$dd/$NODE.row.tmp' '$dd/$NODE.row'" 2>/dev/null || true
  fi
fi
exit 0
