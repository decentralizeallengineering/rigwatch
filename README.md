# rigwatch

[![tests](https://github.com/decentralizeallengineering/rigwatch/actions/workflows/tests.yml/badge.svg)](https://github.com/decentralizeallengineering/rigwatch/actions/workflows/tests.yml) ![license](https://img.shields.io/badge/license-Apache--2.0-blue)

Thermal and resource safety scripts for a homelab machine with GPUs, VMs and hot storage.

It exists because GPU boxes with passthrough VMs fail in boring ways: a card creeps past 70 C, a forgotten VM eats the RAM,
a model container comes up at boot without CUDA and runs on the CPU for days. rigwatch is a set of small shell and Python
scripts, driven by systemd timers, that notice and act. No daemons, no network services, no ML.

| Script | What it does |
| --- | --- |
| `emergency.sh` | Fire-risk cutoff. Any device at or above `HARD_MAX` (100 C) powers the machine off at once; lower cutoffs need two strikes. An unreadable GPU sensor alerts but never powers off. |
| `gputemp-guard` | Steps a GPU's power limit down while it is hot, back up when it has been cool, and re-applies the configured cap. Never powers anything off. |
| `heavy-guard.sh` | Freezes `heavy.slice` when the CPU is too hot, steps GPU limits, watches NVMe and SAS drives (pauses a ZFS scrub when SAS is hot). Calls `ram-guard`. |
| `thermal-mesh.sh` | Graded watcher for CPU, GPU, NVMe, SAS: warn, freeze, restore, ESCALATE if the action does not help. One status row per node. |
| `hwwatch.sh` | Every-minute checks: GPU count and slowdown flags, power limit above cap, CPU, fan service, disk fill and fast fill. |
| `vm-lease`, `vm-reaper` | Every libvirt VM needs a lease; expired VMs are shut down cleanly, then forced. Model-server VMs renew themselves while serving. |
| `ram-guard` | Refuses new VM leases under 10 GB free RAM; under 6 GB shuts down the lowest-priority VM. |
| `gpu-lease` | Advisory GPU leases (`take`, `run`, `release`, `play`) that pick a cool card and stop jobs on a card that stays too hot. |
| `r1-enforcer` | Logs (or kills) pytest, mutmut or stress runs started outside `heavy.slice`, so the guards can freeze them. |
| `llm-gpu-check` | Run once at boot: restart a GPU container that started without CUDA. |

## Install

```
install -m 755 bin/* ~/.local/bin/
mkdir -p ~/.config/rigwatch && cp etc/rigwatch.conf.example ~/.config/rigwatch/rigwatch.conf && cp etc/gpus.conf.example ~/.config/rigwatch/gpus.conf
```

Then install the systemd units from `systemd/` (see `systemd/README.txt`). Needed tools: bash, python3, `lm-sensors`,
`nvidia-smi`, and for VM features `virsh` and ssh access to the VMs. SAS checks also need `smartctl`.
Passwordless sudo is needed only for what you enable: `nvidia-smi -pl` (power limits), `smartctl`/`zpool` (SAS),
and `systemctl poweroff` (or your `POWEROFF_CMD`) for `emergency.sh`.

## Configure

Settings come from the environment, then `~/.config/rigwatch/rigwatch.conf` (plain `KEY=VALUE`), then defaults.
The three limits are `GPU_MAX_C=70`, `CPU_MAX_C=70`, `SAS_MAX_C=60`; freeze, thaw, warn and resume levels are derived from
them (`etc/rigwatch.conf.example` lists every key). GPUs are listed in `gpus.conf`:

```
host-gpu0|local:0|220                 # label | where | power cap in W
vm-gpu1|ssh:192.0.2.10|170|gpu-vm-1   # card inside a VM, read over ssh, libvirt domain gpu-vm-1
```

## Example

```
# lower every limit by 5 C and record what happened
printf 'GPU_MAX_C=65\nCPU_MAX_C=65\nSAS_MAX_C=55\n' >> ~/.config/rigwatch/rigwatch.conf
systemctl --user enable --now gputemp-guard.timer heavy-guard.timer emergency.timer
tail -f ~/.local/state/rigwatch/alerts.log ~/.local/state/rigwatch/alarms.log
```

Dry run of the fire-risk check: `EMERGENCY_DRY=1 EXPECTED_HOST_GPUS=1 EMERGENCY_FAKE_GPU="0, 105" emergency.sh`.

## Tests

`python3 -m pytest tests -q` (no root, GPU or libvirt needed).

## License

Apache-2.0, see `LICENSE` and `NOTICE`.
