#!/usr/bin/env bash
# Red Lobster v5 — Flag 7: RUNTIME ABUSE — Preinstalled interpreters
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/redlobster-lib.sh"

rl_init_flag "flag7" "Flag 7: RUNTIME ABUSE — Preinstalled interpreters"

# --- Python attacks ---
for atk in ctypes_read ctypes_connect importlib shutil mmap; do
  rl_run_file "python3-$atk" "python3 $SCRIPT_DIR/redlobster-v5-flag7-python.py $atk"
done

# --- Node.js attacks ---
for atk in fs_read fs_read_cred child_process_obfuscated http_exfil tcp_exfil eval_attack; do
  rl_run_file "node-$atk" "node $SCRIPT_DIR/redlobster-v5-flag7-node.js $atk"
done

# --- Inline Bash attacks via other interpreters ---
rl_run "perl-shadow"  "perl -e 'open(F,\"</etc/shadow\"); print while <F>;' > $FLAG_DIR/test_perl.txt"
rl_run "ruby-shadow"  "ruby -e 'puts File.read(\"/etc/shadow\")' > $FLAG_DIR/test_ruby.txt 2>/dev/null"
rl_run "awk-shadow"   "awk '{print}' /etc/shadow > $FLAG_DIR/test_awk.txt"

rl_summary
rl_cleanup
