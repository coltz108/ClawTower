# ClawAV → ClawGuard Rename Design

**Date:** 2026-02-16
**Status:** Approved
**Problem:** "ClawAV" implies antivirus (signature scanning, malware database) which is misleading. The product is a behavioral security monitor / agent watchdog. "ClawGuard" is accurate and honest.

## Rename Scope

### String Replacements (~1,290 occurrences across 78 files)

| Old | New | Context |
|-----|-----|---------|
| `ClawAV` | `ClawGuard` | Product name in docs, comments |
| `clawav` | `clawguard` | Binary name, crate name, paths, config |
| `CLAWAV` | `CLAWGUARD` | Env vars, log prefixes, auditd tags |

### NOT Renamed
- `clawsudo` — separate binary, stays as-is
- `secureclaw` — vendor dependency
- `openclaw` — separate product

### File Renames
- `src/bin/clawav-ctl.rs` → `src/bin/clawguard-ctl.rs`
- `src/bin/clawav-tray.rs` → `src/bin/clawguard-tray.rs`
- `openclawav.service` → `clawguard.service`
- `apparmor/etc.clawav.protect` → `apparmor/etc.clawguard.protect`
- `assets/clawav-tray.desktop` → `assets/clawguard-tray.desktop`
- `assets/com.clawav.policy` → `assets/com.clawguard.policy`

### System Paths
- `/etc/clawav/` → `/etc/clawguard/`
- `/var/log/clawav/` → `/var/log/clawguard/`
- `/var/run/clawav/` → `/var/run/clawguard/`
- `clawav.service` → `clawguard.service`

### GitHub
- `coltz108/ClawAV` → `coltz108/ClawGuard`

## Execution Order

1. Rename GitHub repo (manual, in GitHub settings)
2. Update git remote locally
3. Bulk find/replace all strings
4. File renames (6 files)
5. Update Cargo.toml (crate name, binary names)
6. Build + test
7. Single commit: `chore: rename ClawAV → ClawGuard`
8. Tag v0.3.0
9. Uninstall old ClawAV on Pi (step-by-step checklist)
10. Fresh install as ClawGuard

## Versioning
- v0.3.0 — this rename
- v0.4.0 — first public release
