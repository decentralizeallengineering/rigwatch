User units (emergency, hwwatch, gputemp-guard, heavy-guard, thermal-mesh, vm-reaper, r1-enforcer):
  mkdir -p ~/.config/systemd/user && cp *.service *.timer ~/.config/systemd/user/
  rm ~/.config/systemd/user/llm-gpu-check.service
  systemctl --user daemon-reload && systemctl --user enable --now emergency.timer gputemp-guard.timer heavy-guard.timer
heavy-guard.sh and thermal-mesh.sh freeze a user slice: create ~/.config/systemd/user/heavy.slice and run heavy jobs with
  systemd-run --user --slice=heavy.slice ...
System unit (llm-gpu-check, runs once at boot):
  sudo install -m 755 llm-gpu-check /usr/local/bin/ && sudo cp llm-gpu-check.service /etc/systemd/system/ && sudo systemctl enable llm-gpu-check.service
