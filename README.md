# 🛡️ ClawAV

**Tamper-proof, OS-level security watchdog for AI agents.**

ClawAV monitors an AI agent's every syscall, network connection, and file access at the kernel level — and **cannot be disabled, modified, or silenced by the agent**, even under full prompt injection compromise. Once installed, the only way to change it is physical access and a recovery boot.

## Install

```bash
# One-line install (latest release, auto-detects arch)
curl -sSL https://raw.githubusercontent.com/coltz108/ClawAV/main/scripts/oneshot-install.sh | sudo bash

# Pin a version
curl -sSL https://raw.githubusercontent.com/coltz108/ClawAV/main/scripts/oneshot-install.sh | sudo bash -s -- --version v0.1.0
```

Supports **x86_64** and **aarch64** (Raspberry Pi, ARM servers). Downloads pre-built binaries from [GitHub Releases](https://github.com/coltz108/ClawAV/releases).

After install, the installer auto-detects your user and opens the config for review. You can also edit later:

```bash
sudo nano /etc/clawav/config.toml
```

```toml
[general]
watched_user = "1000"              # Auto-detected during install
watched_users = ["1000", "1001"]   # Monitor additional users
watch_all_users = false            # Monitor ALL users

[slack]
webhook_url = "https://hooks.slack.com/..."    # Optional — independent alert channel
backup_webhook_url = "https://hooks.slack.com/..."
channel = "#devops"
min_slack_level = "warning"

[auditd]
enabled = true

[api]
enabled = true
port = 18791

[secureclaw]
enabled = false

[policy]
enabled = true
dir = "./policies"
```

See `config.toml` in the repo for all options. Then start the service:

```bash
sudo systemctl start clawav
sudo journalctl -u clawav -f   # watch logs
```

## Why

AI agents like [OpenClaw](https://github.com/openclaw/openclaw) run with real OS access — executing commands, reading files, making network requests. A prompt injection attack can weaponize that access: exfiltrating secrets, disabling firewalls, escalating privileges.

Traditional security tools trust their operator. **ClawAV assumes the operator (the AI) is compromised** and builds an independent monitoring layer the agent cannot touch. Alerts go through an independent Slack webhook — not through the AI agent.

## Architecture

```
Agent command → clawsudo (policy gate) → LD_PRELOAD (syscall intercept) → OS
     ↓                                          ↓
auditd logs → EXECVE parser → behavior engine + policy engine → aggregator
     ↓                                                              ↓
hash-chained audit trail                              Slack webhook (independent)
     ↓                                                              ↓
JSON API on LAN (:18791)                              TUI dashboard
```

**9,800+ lines of Rust/C. 168 tests. 3 binaries.**

## Key Components

### clawsudo — Sudo Proxy

Replaces `sudo` for the AI agent. Every privileged command goes through policy evaluation first.

- **allow** — Execute immediately
- **deny** — Block (exit 77), alert to Slack
- **ask** — Notify human via Slack, wait up to 5 min for approval

**Fail-secure:** No policy files found = ALL commands denied.

```yaml
# policies/clawsudo.yaml
rules:
  - name: "allow-apt"
    match:
      command: ["apt", "apt-get"]
    enforcement: allow

  - name: "deny-raw-shell"
    match:
      command: ["bash", "sh", "zsh"]
    enforcement: deny
```

### LD_PRELOAD — Syscall Interception

`libclawguard.so` intercepts libc calls **before they execute** (unlike auditd which logs after):

- **`execve`** — blocks denied binaries
- **`open`/`openat`** — blocks writes to protected paths
- **`connect`** — blocks connections to denied addresses

Denied calls return `EACCES` and are logged.

### Behavior Engine

Hardcoded rules classifying events as `DATA_EXFIL`, `PRIV_ESC`, `SEC_TAMPER`, `RECON`, or `SIDE_CHAN`. Works independently of the YAML policy engine — two layers of detection.

### YAML Policy Engine

User-configurable rules loaded from `policies/*.yaml`:

```yaml
rules:
  - name: "block-data-exfiltration"
    match:
      command: ["curl", "wget", "nc"]
      exclude_args: ["api.anthropic.com"]
    action: critical

  - name: "deny-shadow-read"
    match:
      file_access: ["/etc/shadow", "/etc/sudoers.d/*"]
    action: critical
```

### Audit Chain

SHA-256 hash-chained append-only log. Each entry includes the hash of the previous entry — any tampering is detectable.

### SecureClaw Integration

Optional integration with [SecureClaw](https://github.com/adversa-ai/secureclaw) pattern databases:
- 70+ prompt injection patterns across 7 categories
- Dangerous command patterns with severity levels
- PII detection (block/warn/rewrite)
- Supply chain IOC detection

## The "Swallowed Key" — 7 Layers of Tamper Protection

The installer implements 7 layers that make ClawAV immutable once installed:

| Layer | Protection |
|-------|-----------|
| 1. System user | `clawav` user with no login shell |
| 2. Binary + config | `/usr/local/bin/clawav` + `/etc/clawav/` |
| 3. systemd service | `Restart=always`, `WatchdogSec=30`, `NoNewPrivileges=true` |
| 4. Immutable flags | `chattr +i` on binary, config, and service file |
| 5. AppArmor | Denies agent user access to all ClawAV paths |
| 6. Capability dropping | Strips `CAP_LINUX_IMMUTABLE`, `CAP_SYS_PTRACE`, `CAP_SYS_MODULE` from agent |
| 7. Kernel hardening | `kernel.modules_disabled=1`, `yama.ptrace_scope=2`, `auditctl -e 2` |

Plus: restricted sudoers, LD_PRELOAD guard, and **installer self-destructs** after completion.

## Threat Model

| Threat | Defense |
|--------|---------|
| Agent exfiltrates data via curl/wget | Behavior engine + policy engine + clawsudo deny |
| Agent reads `/etc/shadow` | Behavior engine + policy engine + LD_PRELOAD deny |
| Agent disables firewall | Behavior engine + clawsudo deny + sudoers restrict |
| Agent kills the watchdog | `Restart=always` + WatchdogSec + sudoers deny |
| Agent modifies watchdog binary | `chattr +i` + AppArmor + capability drop |
| Agent loads kernel module | `kernel.modules_disabled=1` |
| Agent ptraces the watchdog | `yama.ptrace_scope=2` + capability drop |
| Agent tampers with audit trail | Hash chain detects modifications |
| Agent compromises alert channel | ClawAV uses its own independent Slack webhook |
| PII/secrets leaked via LLM API | DLP proxy scans outbound requests |
| Side-channel attacks | Kernel mitigation scanner + perf_event_open monitoring |
| Prompt injection | SecureClaw pattern databases (70+ patterns) |

**Not in scope:** Physical access (by design, that's the recovery path), kernel 0-days, pre-installation compromise.

## JSON API

LAN-only HTTP API on port 18791:

| Endpoint | Description |
|----------|-------------|
| `GET /api/status` | System status, uptime, module states |
| `GET /api/alerts` | Last 100 alerts |
| `GET /api/security` | Alert counts by severity and source |

## Admin Socket

Unix socket at `/var/run/clawav/admin.sock` with Argon2-hashed key auth:
- `status` — Check watchdog state
- `scan` — Trigger manual security scan
- `pause` — Pause monitoring (max 30 min, auto-resume)

3 failed auth attempts = 1 hour lockout + CRITICAL Slack alert.

## Build from Source

```bash
# Build
cargo build --release

# Build LD_PRELOAD library
bash scripts/build-preload.sh

# Run (dev mode)
cargo run -- ./config.toml

# Run headless
cargo run -- --headless ./config.toml

# Tests
cargo test

# Verify audit chain
cargo run -- verify-audit /path/to/audit.chain
```

## CI/CD

Every push runs build + test + clippy. Tagged releases (`v*`) cross-compile for x86_64 and aarch64, publishing binaries to GitHub Releases automatically.

## License

MIT
