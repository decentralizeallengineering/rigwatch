# rigwatch-conf.sh: shared configuration for every rigwatch shell script (sourced, never executed).
#
# Precedence, highest first: environment variable, KEY=VALUE line in the config file, default below.
# Config file: $RIGWATCH_CONF, default ${XDG_CONFIG_HOME:-$HOME/.config}/rigwatch/rigwatch.conf.
# The file is parsed as plain KEY=VALUE lines (never executed as shell); '#' starts a comment.

RIGWATCH_CONF=${RIGWATCH_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/rigwatch/rigwatch.conf}
if [ -r "$RIGWATCH_CONF" ]; then
  while IFS= read -r _l || [ -n "$_l" ]; do
    _l=${_l%%#*}; _k=${_l%%=*}; _v=${_l#*=}
    [ "$_k" != "$_l" ] || continue
    _k=${_k//[[:space:]]/}
    [[ $_k =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
    _v=${_v#"${_v%%[![:space:]]*}"}; _v=${_v%"${_v##*[![:space:]]}"}
    _v=${_v#\"}; _v=${_v%\"}; _v=${_v#\'}; _v=${_v%\'}
    [ -z "${!_k+x}" ] && printf -v "$_k" '%s' "$_v"
  done < "$RIGWATCH_CONF"
fi
unset _l _k _v

# --- locations
: "${RIGWATCH_STATE_DIR:=$HOME/.local/state/rigwatch}"
: "${ALERT_FILE:=$RIGWATCH_STATE_DIR/alerts.log}"   # one line per ALERT, tail it or point your notifier at it
: "${ALARM_FILE:=$RIGWATCH_STATE_DIR/alarms.log}"   # one line per automatic action (freeze, thaw, VM stop, ...)
: "${ALARM_HOOK:=}"                                  # optional command run as: $ALARM_HOOK "<line>" (mail, chat, ssh append, ...)
: "${GPU_CONF:=${XDG_CONFIG_HOME:-$HOME/.config}/rigwatch/gpus.conf}"
: "${NODE_NAME:=$(hostname -s)}"

# --- temperature limits in degrees C. Everything else is derived from these three unless set explicitly.
: "${GPU_MAX_C:=70}"
: "${CPU_MAX_C:=70}"
: "${SAS_MAX_C:=60}"
: "${NVME_MAX_C:=$CPU_MAX_C}"
: "${GPU_GUARD_HOT:=$((GPU_MAX_C - 2))}"       # gputemp-guard and heavy-guard step the power limit down at or above this
: "${GPU_GUARD_COOL:=$((GPU_MAX_C - 10))}"     # ... and step it back up at or below this
: "${CPU_FREEZE_C:=$((CPU_MAX_C - 2))}"        # heavy-guard freezes heavy.slice at or above this
: "${CPU_THAW_C:=$((CPU_MAX_C - 8))}"          # ... and thaws it at or below this
: "${NVME_HOT_C:=$((NVME_MAX_C - 2))}"
: "${MESH_WARN_C:=$((CPU_MAX_C - 5))}"         # thermal-mesh: first graded action
: "${MESH_FREEZE_C:=$((CPU_MAX_C - 2))}"       # thermal-mesh: freeze
: "${SAS_WARN_C:=$((SAS_MAX_C - 5))}"
: "${SAS_FREEZE_C:=$SAS_MAX_C}"
: "${SAS_RESUME_C:=$((SAS_MAX_C - 10))}"
: "${GPU_ALERT_HOT:=$((GPU_MAX_C + 2))}"       # hwwatch alert levels
: "${GPU_ALERT_CRIT:=$((GPU_MAX_C + 8))}"
: "${CPU_ALERT_HOT:=$((CPU_MAX_C + 5))}"

# --- hard fire-risk cutoffs used by emergency.sh (far above the limits above)
: "${HARD_MAX:=100}"      # any device at or above this: power off at once
: "${CPU_CUTOFF:=100}"
: "${GPU_CUTOFF:=92}"
: "${RAM_CUTOFF:=85}"

# --- remote GPUs and VMs
: "${GPU_SSH_USER:=$(id -un)}"
: "${GPU_SSH_KEY:=}"                 # optional identity file for ssh to VM GPUs
: "${POWEROFF_CMD:=sudo -n systemctl poweroff}"
: "${GPU_HANDOFF_LOCK:=}"            # optional lock file held while a GPU is moved between host and VM; host nvidia-smi is skipped meanwhile

rw_now() { date '+%F %T'; }
rw_alert() { mkdir -p "$(dirname "$ALERT_FILE")"; echo "$(rw_now) ALERT $*" >> "$ALERT_FILE"; }
rw_alarm() {  # rw_alarm <who> <text>: log an automatic action, run the optional hook
  local m; m="$(date '+%F %H:%M') $NODE_NAME $1: $2"
  mkdir -p "$(dirname "$ALARM_FILE")"; echo "$m" >> "$ALARM_FILE"
  [ "${RIGWATCH_DRYRUN:-}" = 1 ] && { echo "ALARM(dry) $m"; return 0; }
  [ -n "$ALARM_HOOK" ] && timeout 20 $ALARM_HOOK "$m" >/dev/null 2>&1
  return 0
}
rw_ssh() {  # rw_ssh <[user@]host> <remote command...>
  local h=$1; shift; [[ $h == *@* ]] || h=$GPU_SSH_USER@$h
  local k=(); [ -n "$GPU_SSH_KEY" ] && k=(-i "$GPU_SSH_KEY")
  timeout "${RW_SSH_TIMEOUT:-8}" ssh -n "${k[@]}" -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR "$h" "$@"
}
rw_gpu_lines() {  # prints the GPU inventory lines: label|local:IDX or ssh:HOST|capW[|libvirt-domain]
  [ -r "$GPU_CONF" ] && grep -vE '^[[:space:]]*(#|$)' "$GPU_CONF"
  return 0
}
rw_gpu_busy() {  # true while the handoff lock is held by someone else
  [ -n "$GPU_HANDOFF_LOCK" ] && [ -e "$GPU_HANDOFF_LOCK" ] && ! flock -n "$GPU_HANDOFF_LOCK" true 2>/dev/null
}
rw_host_gpu_present() { ls /sys/bus/pci/drivers/nvidia/0000:* >/dev/null 2>&1; }
