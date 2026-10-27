"""Smoke and unit tests for rigwatch. Run: python3 -m pytest tests -q   (no root, no GPU, no libvirt needed)."""
import importlib.machinery, importlib.util, os, stat, subprocess, textwrap

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "bin")

def load(name):
    path = os.path.join(BIN, name)
    loader = importlib.machinery.SourceFileLoader(name.replace("-", "_"), path)
    mod = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(mod)
    return mod

def sh(cmd, env=None, **kw):
    e = dict(os.environ, RIGWATCH_CONF="/nonexistent", **(env or {}))
    return subprocess.run(cmd, capture_output=True, text=True, timeout=60, env=e, **kw)

def test_help_exits_without_side_effects(tmp_path):
    for name in ("emergency.sh", "hwwatch.sh", "heavy-guard.sh", "thermal-mesh.sh", "vm-lease", "vm-reaper",
                 "ram-guard", "r1-enforcer", "llm-gpu-check"):
        r = sh([os.path.join(BIN, name), "--help"], env={"RIGWATCH_STATE_DIR": str(tmp_path)})
        assert r.returncode == 2 and "usage" in (r.stdout + r.stderr), name
    for name in ("gpu-lease", "gputemp-guard"):
        r = sh(["python3", "-I", os.path.join(BIN, name), "--help"])
        assert r.returncode == 0 and "gpu" in r.stdout.lower(), name
    assert not os.listdir(tmp_path)

def test_config_file_defaults_and_precedence(tmp_path):
    conf = tmp_path / "rigwatch.conf"
    conf.write_text("GPU_MAX_C=75\nSAS_MAX_C=58  # comment\nCPU_MAX_C=\"65\"\n")
    probe = f'. {BIN}/rigwatch-conf.sh; echo $GPU_MAX_C $CPU_MAX_C $SAS_MAX_C $GPU_GUARD_HOT $CPU_FREEZE_C $SAS_WARN_C'
    r = subprocess.run(["bash", "-c", probe], capture_output=True, text=True, env=dict(os.environ, RIGWATCH_CONF=str(conf)))
    assert r.stdout.split() == ["75", "65", "58", "73", "63", "53"], r.stdout
    r = subprocess.run(["bash", "-c", probe], capture_output=True, text=True, env=dict(os.environ, RIGWATCH_CONF=str(conf), GPU_MAX_C="80"))
    assert r.stdout.split()[0] == "80"
    r = subprocess.run(["bash", "-c", probe], capture_output=True, text=True, env=dict(os.environ, RIGWATCH_CONF="/nonexistent"))
    assert r.stdout.split() == ["70", "70", "60", "68", "68", "55"], r.stdout

def test_emergency_hard_max_powers_off_at_once(tmp_path):
    env = {"RIGWATCH_STATE_DIR": str(tmp_path), "EMERGENCY_DRY": "1", "EMERGENCY_FAKE_GPU": "0, 105", "EXPECTED_HOST_GPUS": "1",
           "XDG_RUNTIME_DIR": str(tmp_path)}
    r = sh([os.path.join(BIN, "emergency.sh")], env=env)
    assert r.returncode == 0
    assert "EMERGENCY fire-risk IMMEDIATE: GPU0 105C" in (tmp_path / "alerts.log").read_text()

def test_emergency_needs_two_strikes_below_hard_max(tmp_path):
    env = {"RIGWATCH_STATE_DIR": str(tmp_path), "EMERGENCY_DRY": "1", "EMERGENCY_FAKE_GPU": "0, 93", "EXPECTED_HOST_GPUS": "1",
           "XDG_RUNTIME_DIR": str(tmp_path)}
    sh([os.path.join(BIN, "emergency.sh")], env=env)
    assert not (tmp_path / "alerts.log").exists()
    sh([os.path.join(BIN, "emergency.sh")], env=env)
    assert "powering off in 20 s" in (tmp_path / "alerts.log").read_text()

def test_emergency_unreadable_gpu_is_alert_not_poweroff(tmp_path):
    env = {"RIGWATCH_STATE_DIR": str(tmp_path), "EMERGENCY_DRY": "1", "EMERGENCY_FAKE_GPU": "0, N/A", "EXPECTED_HOST_GPUS": "1",
           "XDG_RUNTIME_DIR": str(tmp_path)}
    sh([os.path.join(BIN, "emergency.sh")], env=env)
    text = (tmp_path / "alerts.log").read_text()
    assert "EMERGENCY-BLIND" in text and "powering off" not in text

def test_emergency_vm_gpu_from_inventory(tmp_path):
    gpus = tmp_path / "gpus.conf"
    gpus.write_text("vm1|ssh:192.0.2.10|170|vm-one\n")
    env = {"RIGWATCH_STATE_DIR": str(tmp_path), "EMERGENCY_DRY": "1", "GPU_CONF": str(gpus), "EMERGENCY_FAKE_VM": "vm1=101",
           "EMERGENCY_FAKE_DOMSTATE": "running", "XDG_RUNTIME_DIR": str(tmp_path)}
    sh([os.path.join(BIN, "emergency.sh")], env=env)
    assert "GPUvm1 101C" in (tmp_path / "alerts.log").read_text()

def test_thermal_mesh_dry_run_freezes_and_logs(tmp_path):
    fake = tmp_path / "fake"
    fake.write_text("cpu=69\nnvme=40\n")
    env = {"RIGWATCH_STATE_DIR": str(tmp_path), "TM_FAKE_FILE": str(fake), "TM_DRY": "1", "TM_NODE": "testnode"}
    r = sh([os.path.join(BIN, "thermal-mesh.sh")], env=env)
    assert "DRY systemctl --user freeze heavy.slice" in r.stderr and "ROW mesh,testnode," in r.stdout and ",freeze,cpu=69" in r.stdout
    assert "testnode cpu 69 WARN" in (tmp_path / "thermal-mesh-testnode.log").read_text()

def test_thermal_mesh_limits_follow_config(tmp_path):
    fake = tmp_path / "fake"
    fake.write_text("cpu=69\n")
    env = {"RIGWATCH_STATE_DIR": str(tmp_path), "TM_FAKE_FILE": str(fake), "TM_DRY": "1", "TM_NODE": "testnode", "CPU_MAX_C": "80"}
    r = sh([os.path.join(BIN, "thermal-mesh.sh")], env=env)
    assert ",ok,cpu=69" in r.stdout

def test_ram_guard_dry_run_orders_vms(tmp_path):
    gpus = tmp_path / "gpus.conf"
    gpus.write_text("vm1|ssh:192.0.2.10|170|model-vm\n")
    env = {"RIGWATCH_STATE_DIR": str(tmp_path), "GPU_CONF": str(gpus), "MC_RAM_AVAIL_GB": "5", "MC_DRYRUN": "1",
           "MC_VMS": "keep-vm test-vm model-vm", "RAM_PROTECT_VMS": "keep-vm"}
    r = sh([os.path.join(BIN, "ram-guard")], env=env)
    assert "shutdown order: 1 model-vm 2 test-vm 4 keep-vm" in r.stdout and "WOULD virsh shutdown model-vm" in r.stdout

def test_llm_gpu_check_restarts_only_when_cuda_failed(tmp_path):
    stub = tmp_path / "stubs"; stub.mkdir()
    def tool(name, body):
        p = stub / name; p.write_text("#!/bin/sh\n" + textwrap.dedent(body)); p.chmod(p.stat().st_mode | stat.S_IEXEC)
    tool("nvidia-smi", "exit 0\n")
    tool("logger", "exit 0\n")
    tool("docker", f'''
        case "$1" in
          inspect) echo 2026-01-01T00:00:00Z;;
          logs) echo "$FAKE_LOG";;
          restart) echo "restart $2" >> {tmp_path}/calls;;
        esac
    ''')
    env = {"PATH": f"{stub}:{os.environ['PATH']}", "FAKE_LOG": "ggml_cuda_init: failed to initialize CUDA: no CUDA-capable device"}
    assert sh([os.path.join(BIN, "llm-gpu-check")], env=env).returncode == 0
    assert (tmp_path / "calls").read_text() == "restart llm\n"
    (tmp_path / "calls").unlink()
    env["FAKE_LOG"] = "ggml_cuda_init: found 1 CUDA devices"
    sh([os.path.join(BIN, "llm-gpu-check")], env=env)
    assert not (tmp_path / "calls").exists()

# ---- gputemp-guard core (pure function run)
g = load("gputemp-guard")

def rd(t, lim, mn=70, d=125):
    return dict(temp=t, power=50, limit=lim, minlimit=mn, default=d, fan=40, util=50)

class H:
    def __init__(s):
        s.alerts, s.sets = [], []
        g.INV.clear(); g.INV.update({"gpuA": dict(via="local:0", cap=220.0, dom=""), "gpuB": dict(via="ssh:192.0.2.10", cap=170.0, dom="vm-one"),
                                     "gpuC": dict(via="local:1", cap=80.0, dom="")})
        g.EXPECTED[:] = list(g.INV); g.SKIPPED.clear(); g.ABSENT.clear()
    def alert(s, x): s.alerts.append(x)
    def setter(s, gpu, w): s.sets.append((gpu, w)); return True
    def step(s, st, now, **r):
        full = {k: rd(30, g.INV[k]["cap"]) for k in g.INV}; full.update(r)
        full = {k: v for k, v in full.items() if v is not None}
        g.run(full, s.setter, now, st, s.alert, lambda gpu, x: None)

def test_limits_default_to_70_68_60():
    assert (g.HOT, g.HOT2, g.COOL) == (68, 70, 60)

def test_below_hot_no_action():
    h = H(); h.step({}, 1000, gpuC=rd(67, 80))
    assert h.sets == [] and h.alerts == []

def test_hot_lowers_power_limit_by_20():
    h = H(); h.step({}, 1000, gpuC=rd(68, 80, 50))
    assert h.sets == [("gpuC", 60)] and "gpuC 68C, power limit -> 60" in h.alerts[0]

def test_never_below_card_minimum():
    h = H(); h.step({}, 1000, gpuC=rd(69, 75))
    assert h.sets == [("gpuC", 70)]

def test_max_temp_at_min_power_alerts_once_per_window():
    h = H(); st = {}
    h.step(st, 1000, gpuC=rd(70, 70)); assert h.alerts == []
    h.step(st, 1030, gpuC=rd(71, 70))
    assert len(h.alerts) == 1 and "at min power and still >=70C" in h.alerts[0]
    h.step(st, 1060, gpuC=rd(71, 70)); assert len(h.alerts) == 1

def test_cool_card_steps_back_up_after_ten_minutes():
    h = H(); st = {}
    h.step(st, 0, gpuA=rd(55, 150, 150, 320))
    h.step(st, 300, gpuA=rd(55, 150, 150, 320)); assert h.sets == []
    h.step(st, 600, gpuA=rd(55, 150, 150, 320)); assert h.sets == [("gpuA", 160)]
    h.step(st, 630, gpuA=rd(55, 160, 150, 320)); assert len(h.sets) == 1

def test_cap_from_inventory_is_enforced_and_throttled():
    h = H(); st = {}
    h.step(st, 0, gpuC=rd(40, 100, 60, 125))
    assert st["gpuC"]["baseline"] == 80 and h.sets == [("gpuC", 80)] and "100 -> 80 (baseline)" in h.alerts[0]
    h.step(st, 30, gpuC=rd(40, 100, 60, 125)); assert len(h.sets) == 1
    h.step(st, 61, gpuC=rd(40, 100, 60, 125)); assert len(h.sets) == 2

def test_silent_running_vm_warns_after_grace_only():
    h = H(); st = {}
    h.step(st, 5000, gpuB=None); h.step(st, 5030, gpuB=None)
    assert h.alerts == []
    h.step(st, 5301, gpuB=None); assert len(h.alerts) == 1 and "stale" in h.alerts[0]
    h.step(st, 5400, gpuB=None); assert len(h.alerts) == 1

def test_shut_off_vm_and_absent_card_skipped_quietly():
    h = H(); st = {}
    g.SKIPPED.add("gpuB"); g.ABSENT.add("gpuC")
    for t in (0, 400, 2000): h.step(st, t, gpuB=None, gpuC=None)
    assert h.alerts == []

def test_inventory_parser(tmp_path):
    p = tmp_path / "gpus.conf"
    p.write_text("# comment\n\na|local:0|220\nb|ssh:ann@192.0.2.5|-|dom-b\nbad line\n")
    inv = g.load_inventory(str(p))
    assert inv == {"a": dict(via="local:0", cap=220.0, dom=""), "b": dict(via="ssh:ann@192.0.2.5", cap=None, dom="dom-b")}

def test_parse_host_rows():
    out = "0, 41, 120.5, 220, 150, 320, 40, 5\n1, 42, 100, 80, 60, 125, 30, 5\n"
    r = g.parse_host(out)
    assert set(r) == {"0", "1"} and r["0"]["limit"] == 220 and r["1"]["minlimit"] == 60
