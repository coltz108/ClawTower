# Move Admin Key Generation to Harden Step

## Problem

The admin "swallowed key" is currently generated on first ClawTower run via `init_admin_key()` in `admin.rs`. This is unstable:

- If the first run is a headless systemd service, the key is printed to journal logs where nobody sees it
- If the first run is a TUI session, the key flashes by before the dashboard renders
- The operator has no control over *when* the key appears
- The key could be generated during a test run, an accidental start, or a CI pipeline

## Solution

Move key generation to the `clawtower harden` step (which delegates to `install.sh`). The key is generated exactly once, during an explicit hardening operation where the operator is watching the terminal.

## Design

### 1. Split `init_admin_key()` in `admin.rs`

**Current:** `init_admin_key(hash_path)` generates the key on first run, displays it, writes the hash, and sets `chattr +i`.

**After:**

- `init_admin_key(hash_path)` becomes a check-only function. If no hash file exists, it logs "Admin key not yet generated -- run 'clawtower harden'" and returns Ok. If the hash file exists, it returns Ok. No generation ever happens here.

- `generate_and_show_admin_key(hash_path)` (new) contains the actual key generation + display + write + `chattr +i` logic. If the hash file already exists, it prints "Admin key already exists" and returns Ok (idempotent).

### 2. New `clawtower generate-key` subcommand

Add a `generate-key` arm in `main.rs` that calls `admin::generate_and_show_admin_key()`. Exits 0 on success or if key already exists, 1 on failure.

### 3. `install.sh` calls the binary

After step 4 (immutable attributes) and before step 10 (start service), add:

```bash
log "Generating admin key..."
/usr/local/bin/clawtower generate-key
```

This is the single place the key is ever created. The operator sees it in the terminal output of `clawtower harden`.

### 4. Cleanup

- Update `init_admin_key()` doc comment and module doc in `admin.rs`
- Update install.sh completion banner: "Admin key will be displayed on first service run" -> "Your admin key was displayed above -- save it now!"
- Update `run_install()` next-steps in `main.rs` to note that harden generates the admin key
- Update CLAUDE.md swallowed key description to note key is generated at harden time

### What stays the same

- `verify_key()`, `hash_key()`, `generate_admin_key()` -- unchanged
- Admin socket: rejects all commands with "Admin key not initialized" when no hash file (correct pre-harden behavior)
- Uninstall key verification -- unchanged
- `verify-key` subcommand -- unchanged

## Files Modified

| File | Change |
|------|--------|
| `src/admin.rs` | Split `init_admin_key()` into check-only + `generate_and_show_admin_key()` |
| `src/main.rs` | Add `generate-key` subcommand, update help text, update install next-steps |
| `scripts/install.sh` | Add `clawtower generate-key` call, update completion banner |

## Verification

1. `cargo test` -- all admin module tests still pass
2. Fresh install flow: `clawtower install` -> `clawtower run` -> no key shown, admin socket rejects commands
3. Harden flow: `clawtower harden` -> key displayed in terminal, hash written, `chattr +i` applied
4. Re-harden: `clawtower harden` again -> "Admin key already exists", no new key
5. Uninstall: `clawtower uninstall --key <key>` -> still works with key from harden step
