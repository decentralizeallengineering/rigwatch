# vm-lib.sh: shared by vm-lease, vm-reaper and ram-guard (sourced). libvirt system URI, no sudo needed (libvirt group).
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/rigwatch-conf.sh"
export LC_ALL=C LIBVIRT_DEFAULT_URI=qemu:///system
: "${LEASE_DIR:=$RIGWATCH_STATE_DIR/vm-leases}"
: "${RAM_REFUSE_GB:=10}"   # below this much available RAM: new VM starts/leases are refused and an alarm is logged
: "${RAM_STOP_GB:=6}"      # below this: ram-guard cleanly shuts down the lowest-priority running VM
vm_state() { virsh domstate "$1" 2>/dev/null | head -1; }
ram_avail_gb() { if [ -n "${MC_RAM_AVAIL_GB:-}" ]; then echo "$MC_RAM_AVAIL_GB"; else awk '/MemAvailable/{printf "%.1f",$2/1048576}' /proc/meminfo; fi; }
ram_ge() { awk -v a="$(ram_avail_gb)" -v t="$1" 'BEGIN{exit !(a>=t)}'; }   # available >= t GB
mc_alarm() {  # mc_alarm <who> <text>; set MC_DRYRUN=1 to print instead of notifying
  [ "${MC_DRYRUN:-}" = 1 ] && export RIGWATCH_DRYRUN=1
  rw_alarm "$1" "$2"
}
vm_lease_set() { mkdir -p "$LEASE_DIR"; echo "$(( $(date +%s) + $2 * 60 )) ${3:-}" > "$LEASE_DIR/$1"; }
# libvirt domains of GPU VMs from gpus.conf (4th field), one per line: these are the "model server" VMs
gpu_vm_domains() { rw_gpu_lines | awk -F'|' '$4!=""{print $4}'; }
gpu_vm_host() { rw_gpu_lines | awk -F'|' -v d="$1" '$4==d && $2 ~ /^ssh:/{sub(/^ssh:/,"",$2); print $2; exit}'; }
