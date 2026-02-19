# Hardcoded Key Auto-Remediation — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** When the scanner detects hardcoded API keys in OpenClaw config files, auto-replace them with proxy virtual keys, persist the real key in an encrypted manifest + proxy overlay, and provide a `restore-keys` CLI command to reverse everything.

**Architecture:** New `src/scanner/remediate.rs` module handles all remediation logic. The existing `scan_openclaw_hardcoded_secrets()` calls into it when keys are found. Real keys go into a `config.d/` proxy overlay (merged automatically via existing config layering). A manifest at `/etc/clawtower/remediated-keys.json` tracks everything for reversibility, with AES-256-GCM encrypted key backup.

**Tech Stack:** Rust, serde_json, serde_yaml, toml, sha2, aes-gcm (new dep), rand, hex, zeroize.

**Design doc:** `docs/plans/2026-02-19-hardcoded-key-remediation-design.md`

---

### Task 1: Add `aes-gcm` dependency

**Files:**
- Modify: `Cargo.toml`

**Step 1: Add the crate**

In `Cargo.toml` under `[dependencies]`, add after the existing `argon2` line:

```toml
aes-gcm = "0.10"
```

**Step 2: Verify it compiles**

Run: `cargo check 2>&1 | tail -5`
Expected: compiles with no errors related to aes-gcm

**Step 3: Commit**

```bash
git add Cargo.toml Cargo.lock
git commit -m "chore: add aes-gcm dependency for key remediation encryption"
```

---

### Task 2: Core types and manifest (remediate.rs scaffold)

**Files:**
- Create: `src/scanner/remediate.rs`
- Modify: `src/scanner/mod.rs` (add `pub mod remediate;` at line 30)

**Step 1: Write the tests for manifest types and serialization**

At the bottom of the new `src/scanner/remediate.rs`, add:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_manifest_roundtrip() {
        let manifest = RemediationManifest {
            version: 1,
            remediations: vec![RemediationEntry {
                id: "abc123".to_string(),
                timestamp: "2026-02-19T14:30:00Z".to_string(),
                source_file: "/home/openclaw/.openclaw/openclaw.json".to_string(),
                json_path: "channels.slack.botToken".to_string(),
                original_key_prefix: "xoxb-".to_string(),
                original_key_hash: "sha256:deadbeef".to_string(),
                encrypted_real_key: "base64:data".to_string(),
                encryption_salt: "hex:aabb".to_string(),
                virtual_key: "vk-remediated-slack-abc123".to_string(),
                provider: "slack".to_string(),
                upstream: "https://slack.com/api".to_string(),
            }],
        };
        let json = serde_json::to_string_pretty(&manifest).unwrap();
        let parsed: RemediationManifest = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.version, 1);
        assert_eq!(parsed.remediations.len(), 1);
        assert_eq!(parsed.remediations[0].id, "abc123");
        assert_eq!(parsed.remediations[0].provider, "slack");
    }

    #[test]
    fn test_load_manifest_missing_file() {
        let m = load_manifest("/tmp/clawtower-test-nonexistent-manifest.json");
        assert_eq!(m.version, 1);
        assert!(m.remediations.is_empty());
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cargo test --lib test_manifest_roundtrip 2>&1 | tail -10`
Expected: FAIL — `RemediationManifest` not defined

**Step 3: Write the manifest types and load/save functions**

Write the top of `src/scanner/remediate.rs`:

```rust
//! Auto-remediation of hardcoded API keys in OpenClaw config files.
//!
//! When the scanner detects hardcoded keys, this module replaces them with
//! proxy virtual keys, persists the real key in an encrypted manifest and
//! a proxy config overlay, and provides restore logic for reversibility.

use serde::{Deserialize, Serialize};

/// Path to the remediation manifest file.
pub const MANIFEST_PATH: &str = "/etc/clawtower/remediated-keys.json";

/// Path to the proxy config overlay for remediated keys.
pub const OVERLAY_PATH: &str = "/etc/clawtower/config.d/90-remediated-keys.toml";

#[derive(Debug, Serialize, Deserialize)]
pub struct RemediationManifest {
    pub version: u32,
    pub remediations: Vec<RemediationEntry>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct RemediationEntry {
    pub id: String,
    pub timestamp: String,
    pub source_file: String,
    pub json_path: String,
    pub original_key_prefix: String,
    pub original_key_hash: String,
    pub encrypted_real_key: String,
    pub encryption_salt: String,
    pub virtual_key: String,
    pub provider: String,
    pub upstream: String,
}

/// Load the manifest from disk. Returns an empty manifest if the file doesn't exist.
pub fn load_manifest(path: &str) -> RemediationManifest {
    match std::fs::read_to_string(path) {
        Ok(content) => serde_json::from_str(&content).unwrap_or(RemediationManifest {
            version: 1,
            remediations: Vec::new(),
        }),
        Err(_) => RemediationManifest {
            version: 1,
            remediations: Vec::new(),
        },
    }
}

/// Save the manifest to disk. Creates parent directories if needed.
pub fn save_manifest(path: &str, manifest: &RemediationManifest) -> Result<(), String> {
    if let Some(parent) = std::path::Path::new(path).parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("mkdir: {}", e))?;
    }
    let json = serde_json::to_string_pretty(manifest).map_err(|e| format!("serialize: {}", e))?;
    std::fs::write(path, json).map_err(|e| format!("write: {}", e))
}
```

Also add `pub mod remediate;` in `src/scanner/mod.rs` after line 29 (after `pub mod user_accounts;`).

**Step 4: Run tests to verify they pass**

Run: `cargo test --lib test_manifest_roundtrip test_load_manifest_missing_file 2>&1 | tail -10`
Expected: both PASS

**Step 5: Commit**

```bash
git add src/scanner/remediate.rs src/scanner/mod.rs
git commit -m "feat(remediate): add manifest types and load/save"
```

---

### Task 3: AES-256-GCM encryption for manifest backup

**Files:**
- Modify: `src/scanner/remediate.rs`

**Step 1: Write the failing tests for encryption**

Add to the `tests` module in `remediate.rs`:

```rust
#[test]
fn test_encrypt_decrypt_roundtrip() {
    let key = "xoxb-test-secret-key-value-1234567890abcdef";
    let encrypted = encrypt_key(key).unwrap();
    assert!(!encrypted.ciphertext.is_empty());
    assert!(!encrypted.salt.is_empty());
    let decrypted = decrypt_key(&encrypted).unwrap();
    assert_eq!(decrypted, key);
}

#[test]
fn test_encrypt_different_salts() {
    let key = "sk-ant-test-key-abcdef1234567890";
    let e1 = encrypt_key(key).unwrap();
    let e2 = encrypt_key(key).unwrap();
    // Different salts mean different ciphertexts
    assert_ne!(e1.salt, e2.salt);
    // But both decrypt to the same value
    assert_eq!(decrypt_key(&e1).unwrap(), key);
    assert_eq!(decrypt_key(&e2).unwrap(), key);
}
```

**Step 2: Run tests to verify they fail**

Run: `cargo test --lib test_encrypt_decrypt_roundtrip 2>&1 | tail -10`
Expected: FAIL — `encrypt_key` not defined

**Step 3: Implement encryption functions**

Add to `remediate.rs` (above the tests module):

```rust
use aes_gcm::{Aes256Gcm, KeyInit, Nonce};
use aes_gcm::aead::Aead;
use sha2::{Sha256, Digest};
use rand::RngCore;

/// Encrypted key data with salt for machine-bound decryption.
pub struct EncryptedKey {
    pub ciphertext: String, // base64-encoded
    pub salt: String,       // hex-encoded
}

/// Derive a 256-bit encryption key from /etc/machine-id + salt.
fn derive_encryption_key(salt: &[u8]) -> [u8; 32] {
    let machine_id = std::fs::read_to_string("/etc/machine-id")
        .unwrap_or_else(|_| "fallback-machine-id-for-testing".to_string());
    let mut hasher = Sha256::new();
    hasher.update(machine_id.trim().as_bytes());
    hasher.update(salt);
    hasher.update(b"clawtower-remediation-v1");
    hasher.finalize().into()
}

/// Encrypt an API key using AES-256-GCM with a machine-bound key.
pub fn encrypt_key(plaintext: &str) -> Result<EncryptedKey, String> {
    let mut salt = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut salt);

    let key_bytes = derive_encryption_key(&salt);
    let cipher = Aes256Gcm::new_from_slice(&key_bytes)
        .map_err(|e| format!("cipher init: {}", e))?;

    // Use first 12 bytes of salt as nonce (AES-GCM requires 96-bit nonce)
    let nonce = Nonce::from_slice(&salt[..12]);
    let ciphertext = cipher.encrypt(nonce, plaintext.as_bytes())
        .map_err(|e| format!("encrypt: {}", e))?;

    use base64::Engine;
    Ok(EncryptedKey {
        ciphertext: base64::engine::general_purpose::STANDARD.encode(&ciphertext),
        salt: hex::encode(salt),
    })
}

/// Decrypt an API key from its encrypted manifest entry.
pub fn decrypt_key(encrypted: &EncryptedKey) -> Result<String, String> {
    let salt = hex::decode(&encrypted.salt).map_err(|e| format!("hex decode salt: {}", e))?;
    let key_bytes = derive_encryption_key(&salt);
    let cipher = Aes256Gcm::new_from_slice(&key_bytes)
        .map_err(|e| format!("cipher init: {}", e))?;

    let nonce = Nonce::from_slice(&salt[..12]);
    use base64::Engine;
    let ciphertext = base64::engine::general_purpose::STANDARD
        .decode(&encrypted.ciphertext)
        .map_err(|e| format!("base64 decode: {}", e))?;
    let plaintext = cipher.decrypt(nonce, ciphertext.as_ref())
        .map_err(|e| format!("decrypt: {}", e))?;

    String::from_utf8(plaintext).map_err(|e| format!("utf8: {}", e))
}
```

Note: Check if `base64` crate is already a dependency. If not, add it to `Cargo.toml`. The `hex` crate is already present.

**Step 4: Run tests to verify they pass**

Run: `cargo test --lib test_encrypt_decrypt_roundtrip test_encrypt_different_salts 2>&1 | tail -10`
Expected: both PASS

**Step 5: Commit**

```bash
git add src/scanner/remediate.rs Cargo.toml Cargo.lock
git commit -m "feat(remediate): add AES-256-GCM key encryption for manifest backup"
```

---

### Task 4: Provider detection (JSON context + prefix fallback)

**Files:**
- Modify: `src/scanner/remediate.rs`

**Step 1: Write the failing tests**

Add to the `tests` module:

```rust
#[test]
fn test_provider_from_json_path_slack() {
    let (provider, upstream) = detect_provider_from_context("channels.slack.botToken", "xoxb-abc");
    assert_eq!(provider, "slack");
    assert_eq!(upstream, "https://slack.com/api");
}

#[test]
fn test_provider_from_json_path_anthropic() {
    let (provider, upstream) = detect_provider_from_context("providers.anthropic.apiKey", "sk-ant-abc");
    assert_eq!(provider, "anthropic");
    assert_eq!(upstream, "https://api.anthropic.com");
}

#[test]
fn test_provider_prefix_fallback() {
    // Unknown JSON path, falls back to prefix
    let (provider, upstream) = detect_provider_from_context("some.unknown.path", "gsk_abc123");
    assert_eq!(provider, "groq");
    assert_eq!(upstream, "https://api.groq.com/openai");
}

#[test]
fn test_provider_unknown() {
    let (provider, upstream) = detect_provider_from_context("some.path", "key-unknown123");
    assert_eq!(provider, "unknown");
    assert_eq!(upstream, "");
}

#[test]
fn test_provider_prefix_openai_sk() {
    let (provider, upstream) = detect_provider_from_context("unknown.path", "sk-proj-abc123");
    assert_eq!(provider, "openai");
    assert_eq!(upstream, "https://api.openai.com");
}
```

**Step 2: Run tests to verify they fail**

Run: `cargo test --lib test_provider_from_json_path 2>&1 | tail -10`
Expected: FAIL — `detect_provider_from_context` not defined

**Step 3: Implement provider detection**

Add to `remediate.rs`:

```rust
/// Known provider info: (provider_name, upstream_url).
pub struct ProviderInfo {
    pub provider: &'static str,
    pub upstream: &'static str,
}

/// JSON path patterns to provider mappings (Stage 1).
const JSON_PATH_PROVIDERS: &[(&str, ProviderInfo)] = &[
    ("channels.slack", ProviderInfo { provider: "slack", upstream: "https://slack.com/api" }),
    ("providers.anthropic", ProviderInfo { provider: "anthropic", upstream: "https://api.anthropic.com" }),
    ("providers.openai", ProviderInfo { provider: "openai", upstream: "https://api.openai.com" }),
    ("providers.groq", ProviderInfo { provider: "groq", upstream: "https://api.groq.com/openai" }),
    ("providers.xai", ProviderInfo { provider: "xai", upstream: "https://api.x.ai" }),
];

/// Key prefix to provider mappings (Stage 2 fallback).
/// Order matters: more specific prefixes before less specific (sk-ant- before sk-).
const PREFIX_PROVIDERS: &[(&str, ProviderInfo)] = &[
    ("sk-ant-", ProviderInfo { provider: "anthropic", upstream: "https://api.anthropic.com" }),
    ("sk-proj-", ProviderInfo { provider: "openai", upstream: "https://api.openai.com" }),
    ("gsk_", ProviderInfo { provider: "groq", upstream: "https://api.groq.com/openai" }),
    ("xai-", ProviderInfo { provider: "xai", upstream: "https://api.x.ai" }),
    ("xoxb-", ProviderInfo { provider: "slack", upstream: "https://slack.com/api" }),
    ("xoxp-", ProviderInfo { provider: "slack", upstream: "https://slack.com/api" }),
    ("ghp_", ProviderInfo { provider: "github", upstream: "https://api.github.com" }),
    ("glpat-", ProviderInfo { provider: "gitlab", upstream: "https://gitlab.com/api" }),
    ("AKIA", ProviderInfo { provider: "aws", upstream: "https://sts.amazonaws.com" }),
    ("sk-", ProviderInfo { provider: "openai", upstream: "https://api.openai.com" }),
];

/// Detect provider from JSON path context first, then fall back to key prefix.
/// Returns (provider_name, upstream_url).
pub fn detect_provider_from_context(json_path: &str, key_value: &str) -> (String, String) {
    // Stage 1: JSON path context
    for (path_prefix, info) in JSON_PATH_PROVIDERS {
        if json_path.starts_with(path_prefix) {
            return (info.provider.to_string(), info.upstream.to_string());
        }
    }

    // Stage 2: Key prefix fallback
    for (prefix, info) in PREFIX_PROVIDERS {
        if key_value.starts_with(prefix) {
            return (info.provider.to_string(), info.upstream.to_string());
        }
    }

    ("unknown".to_string(), String::new())
}
```

**Step 4: Run tests to verify they pass**

Run: `cargo test --lib test_provider_from_json_path test_provider_prefix_fallback test_provider_unknown test_provider_prefix_openai 2>&1 | tail -10`
Expected: all PASS

**Step 5: Commit**

```bash
git add src/scanner/remediate.rs
git commit -m "feat(remediate): add two-stage provider detection (JSON context + prefix)"
```

---

### Task 5: Key extraction from JSON files

This is the core detection logic that finds keys AND their JSON paths (the existing scanner only finds prefix+filename).

**Files:**
- Modify: `src/scanner/remediate.rs`

**Step 1: Write the failing tests**

Add to `tests` module:

```rust
#[test]
fn test_extract_keys_from_json() {
    let json = r#"{
        "channels": {
            "slack": {
                "botToken": "xoxb-1234567890-abcdefghijklmnop"
            }
        },
        "providers": {
            "anthropic": {
                "apiKey": "sk-ant-1234567890abcdefghijklmnop"
            }
        },
        "name": "test-agent"
    }"#;
    let keys = extract_keys_from_json(json);
    assert_eq!(keys.len(), 2);

    let slack_key = keys.iter().find(|k| k.json_path == "channels.slack.botToken").unwrap();
    assert_eq!(slack_key.full_key, "xoxb-1234567890-abcdefghijklmnop");
    assert_eq!(slack_key.prefix, "xoxb-");

    let ant_key = keys.iter().find(|k| k.json_path == "providers.anthropic.apiKey").unwrap();
    assert_eq!(ant_key.full_key, "sk-ant-1234567890abcdefghijklmnop");
    assert_eq!(ant_key.prefix, "sk-ant-");
}

#[test]
fn test_extract_keys_no_keys() {
    let json = r#"{"name": "agent", "mode": "safe"}"#;
    let keys = extract_keys_from_json(json);
    assert!(keys.is_empty());
}

#[test]
fn test_extract_keys_short_key_ignored() {
    // Key prefix followed by fewer than 16 chars — not a real key
    let json = r#"{"token": "sk-short"}"#;
    let keys = extract_keys_from_json(json);
    assert!(keys.is_empty());
}
```

**Step 2: Run tests to verify they fail**

Run: `cargo test --lib test_extract_keys_from_json 2>&1 | tail -10`
Expected: FAIL — `extract_keys_from_json` not defined

**Step 3: Implement key extraction**

Add to `remediate.rs`:

```rust
/// A key found in a config file with its location metadata.
pub struct FoundKey {
    pub json_path: String,
    pub full_key: String,
    pub prefix: String,
}

/// The same key prefixes used by the scanner (keep in sync with network.rs).
const KEY_PREFIXES: &[&str] = &[
    "sk-ant-", "sk-proj-", "sk-", "key-", "gsk_", "xai-",
    "AKIA", "ghp_", "glpat-", "xoxb-", "xoxp-",
];

/// Extract all hardcoded API keys from a JSON string, returning their paths and values.
pub fn extract_keys_from_json(json_str: &str) -> Vec<FoundKey> {
    let value: serde_json::Value = match serde_json::from_str(json_str) {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };
    let mut found = Vec::new();
    walk_json_for_keys(&value, String::new(), &mut found);
    found
}

fn walk_json_for_keys(value: &serde_json::Value, path: String, found: &mut Vec<FoundKey>) {
    match value {
        serde_json::Value::Object(map) => {
            for (key, val) in map {
                let child_path = if path.is_empty() {
                    key.clone()
                } else {
                    format!("{}.{}", path, key)
                };
                walk_json_for_keys(val, child_path, found);
            }
        }
        serde_json::Value::String(s) => {
            for prefix in KEY_PREFIXES {
                if s.starts_with(prefix) {
                    let after = &s[prefix.len()..];
                    let key_chars = after.chars()
                        .take_while(|c| c.is_alphanumeric() || *c == '-' || *c == '_')
                        .count();
                    if key_chars >= 16 {
                        found.push(FoundKey {
                            json_path: path.clone(),
                            full_key: s.clone(),
                            prefix: prefix.to_string(),
                        });
                        break; // Don't match shorter prefixes for same value
                    }
                }
            }
        }
        serde_json::Value::Array(arr) => {
            for (i, val) in arr.iter().enumerate() {
                walk_json_for_keys(val, format!("{}[{}]", path, i), found);
            }
        }
        _ => {}
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `cargo test --lib test_extract_keys_from_json test_extract_keys_no_keys test_extract_keys_short_key_ignored 2>&1 | tail -10`
Expected: all PASS

**Step 5: Commit**

```bash
git add src/scanner/remediate.rs
git commit -m "feat(remediate): add JSON key extraction with path tracking"
```

---

### Task 6: Key extraction from YAML files

**Files:**
- Modify: `src/scanner/remediate.rs`

**Step 1: Write the failing tests**

```rust
#[test]
fn test_extract_keys_from_yaml() {
    let yaml = "gateway:\n  apiKey: sk-ant-abcdef1234567890abcdef\n  bind: 127.0.0.1\n";
    let keys = extract_keys_from_yaml(yaml);
    assert_eq!(keys.len(), 1);
    assert_eq!(keys[0].full_key, "sk-ant-abcdef1234567890abcdef");
    assert_eq!(keys[0].prefix, "sk-ant-");
}
```

**Step 2: Run to verify failure**

Run: `cargo test --lib test_extract_keys_from_yaml 2>&1 | tail -10`

**Step 3: Implement YAML extraction**

```rust
/// Extract hardcoded API keys from a YAML string.
/// Uses serde_yaml to parse, then walks the value tree similarly to JSON.
pub fn extract_keys_from_yaml(yaml_str: &str) -> Vec<FoundKey> {
    let value: serde_yaml::Value = match serde_yaml::from_str(yaml_str) {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };
    let mut found = Vec::new();
    walk_yaml_for_keys(&value, String::new(), &mut found);
    found
}

fn walk_yaml_for_keys(value: &serde_yaml::Value, path: String, found: &mut Vec<FoundKey>) {
    match value {
        serde_yaml::Value::Mapping(map) => {
            for (k, v) in map {
                let key_str = match k {
                    serde_yaml::Value::String(s) => s.clone(),
                    _ => format!("{:?}", k),
                };
                let child_path = if path.is_empty() { key_str } else { format!("{}.{}", path, key_str) };
                walk_yaml_for_keys(v, child_path, found);
            }
        }
        serde_yaml::Value::String(s) => {
            for prefix in KEY_PREFIXES {
                if s.starts_with(prefix) {
                    let after = &s[prefix.len()..];
                    let key_chars = after.chars()
                        .take_while(|c| c.is_alphanumeric() || *c == '-' || *c == '_')
                        .count();
                    if key_chars >= 16 {
                        found.push(FoundKey {
                            json_path: path.clone(), // reuse field name
                            full_key: s.clone(),
                            prefix: prefix.to_string(),
                        });
                        break;
                    }
                }
            }
        }
        serde_yaml::Value::Sequence(seq) => {
            for (i, v) in seq.iter().enumerate() {
                walk_yaml_for_keys(v, format!("{}[{}]", path, i), found);
            }
        }
        _ => {}
    }
}
```

**Step 4: Run tests**

Run: `cargo test --lib test_extract_keys_from_yaml 2>&1 | tail -10`
Expected: PASS

**Step 5: Commit**

```bash
git add src/scanner/remediate.rs
git commit -m "feat(remediate): add YAML key extraction"
```

---

### Task 7: Config file rewriting (JSON)

Replace a key value at a known JSON path with a virtual key, preserving structure.

**Files:**
- Modify: `src/scanner/remediate.rs`

**Step 1: Write the failing tests**

```rust
#[test]
fn test_rewrite_json_key() {
    let json = r#"{
    "channels": {
        "slack": {
            "botToken": "xoxb-real-secret-key-1234567890"
        }
    },
    "name": "agent"
}"#;
    let result = rewrite_json_key(json, "channels.slack.botToken", "vk-remediated-slack-abc123").unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
    assert_eq!(
        parsed["channels"]["slack"]["botToken"],
        "vk-remediated-slack-abc123"
    );
    // Other fields preserved
    assert_eq!(parsed["name"], "agent");
}

#[test]
fn test_rewrite_json_key_missing_path() {
    let json = r#"{"name": "agent"}"#;
    let result = rewrite_json_key(json, "nonexistent.path", "vk-test");
    assert!(result.is_err());
}
```

**Step 2: Run to verify failure**

Run: `cargo test --lib test_rewrite_json_key 2>&1 | tail -10`

**Step 3: Implement JSON rewriting**

```rust
/// Rewrite a JSON string, replacing the value at `json_path` with `new_value`.
/// Returns the modified JSON string (pretty-printed).
pub fn rewrite_json_key(json_str: &str, json_path: &str, new_value: &str) -> Result<String, String> {
    let mut value: serde_json::Value = serde_json::from_str(json_str)
        .map_err(|e| format!("parse: {}", e))?;

    let parts: Vec<&str> = json_path.split('.').collect();
    set_json_value(&mut value, &parts, new_value)?;

    serde_json::to_string_pretty(&value).map_err(|e| format!("serialize: {}", e))
}

fn set_json_value(value: &mut serde_json::Value, path: &[&str], new_value: &str) -> Result<(), String> {
    if path.is_empty() {
        return Err("empty path".to_string());
    }
    if path.len() == 1 {
        match value {
            serde_json::Value::Object(map) => {
                if map.contains_key(path[0]) {
                    map.insert(path[0].to_string(), serde_json::Value::String(new_value.to_string()));
                    Ok(())
                } else {
                    Err(format!("key '{}' not found", path[0]))
                }
            }
            _ => Err("expected object".to_string()),
        }
    } else {
        match value {
            serde_json::Value::Object(map) => {
                match map.get_mut(path[0]) {
                    Some(child) => set_json_value(child, &path[1..], new_value),
                    None => Err(format!("key '{}' not found", path[0])),
                }
            }
            _ => Err("expected object".to_string()),
        }
    }
}
```

**Step 4: Run tests**

Run: `cargo test --lib test_rewrite_json_key 2>&1 | tail -10`
Expected: PASS

**Step 5: Commit**

```bash
git add src/scanner/remediate.rs
git commit -m "feat(remediate): add JSON key rewriting with path traversal"
```

---

### Task 8: Config file rewriting (YAML — line-based)

**Files:**
- Modify: `src/scanner/remediate.rs`

**Step 1: Write the failing test**

```rust
#[test]
fn test_rewrite_yaml_key() {
    let yaml = "gateway:\n  apiKey: sk-ant-abcdef1234567890abcdef\n  bind: 127.0.0.1\n";
    let result = rewrite_yaml_key(yaml, "sk-ant-abcdef1234567890abcdef", "vk-remediated-anthropic-abc").unwrap();
    assert!(result.contains("vk-remediated-anthropic-abc"));
    assert!(!result.contains("sk-ant-abcdef1234567890abcdef"));
    assert!(result.contains("bind: 127.0.0.1")); // other lines preserved
}
```

**Step 2: Run to verify failure**

**Step 3: Implement YAML line-based rewriting**

```rust
/// Rewrite a YAML string, replacing an exact key value with a virtual key.
/// Uses line-based replacement to avoid reformatting the YAML structure.
pub fn rewrite_yaml_key(yaml_str: &str, old_value: &str, new_value: &str) -> Result<String, String> {
    if !yaml_str.contains(old_value) {
        return Err(format!("value '{}...' not found in YAML", &old_value[..old_value.len().min(10)]));
    }
    Ok(yaml_str.replace(old_value, new_value))
}
```

**Step 4: Run tests**

Run: `cargo test --lib test_rewrite_yaml_key 2>&1 | tail -10`
Expected: PASS

**Step 5: Commit**

```bash
git add src/scanner/remediate.rs
git commit -m "feat(remediate): add YAML line-based key rewriting"
```

---

### Task 9: Proxy overlay writer

Write `config.d/90-remediated-keys.toml` with new KeyMapping entries.

**Files:**
- Modify: `src/scanner/remediate.rs`

**Step 1: Write the failing tests**

```rust
#[test]
fn test_write_proxy_overlay() {
    let dir = tempfile::tempdir().unwrap();
    let overlay_path = dir.path().join("90-remediated-keys.toml");
    let entries = vec![
        RemediationEntry {
            id: "abc".to_string(),
            timestamp: String::new(),
            source_file: String::new(),
            json_path: String::new(),
            original_key_prefix: "xoxb-".to_string(),
            original_key_hash: String::new(),
            encrypted_real_key: String::new(),
            encryption_salt: String::new(),
            virtual_key: "vk-remediated-slack-abc".to_string(),
            provider: "slack".to_string(),
            upstream: "https://slack.com/api".to_string(),
        },
    ];
    write_proxy_overlay(overlay_path.to_str().unwrap(), &entries, &["xoxb-real-key-here-1234567890".to_string()]).unwrap();

    let content = std::fs::read_to_string(&overlay_path).unwrap();
    assert!(content.contains("vk-remediated-slack-abc"));
    assert!(content.contains("xoxb-real-key-here-1234567890"));
    assert!(content.contains("slack"));
    assert!(content.contains("https://slack.com/api"));

    // Verify it parses as valid TOML with proxy.key_mapping array
    let val: toml::Value = toml::from_str(&content).unwrap();
    let mappings = val["proxy"]["key_mapping"].as_array().unwrap();
    assert_eq!(mappings.len(), 1);
}

#[test]
fn test_write_proxy_overlay_appends() {
    let dir = tempfile::tempdir().unwrap();
    let overlay_path = dir.path().join("90-remediated-keys.toml");

    let entry1 = RemediationEntry {
        id: "a".to_string(), timestamp: String::new(), source_file: String::new(),
        json_path: String::new(), original_key_prefix: "xoxb-".to_string(),
        original_key_hash: String::new(), encrypted_real_key: String::new(),
        encryption_salt: String::new(), virtual_key: "vk-a".to_string(),
        provider: "slack".to_string(), upstream: "https://slack.com/api".to_string(),
    };
    write_proxy_overlay(overlay_path.to_str().unwrap(), &[entry1], &["real-key-a-1234567890abcdef".to_string()]).unwrap();

    let entry2 = RemediationEntry {
        id: "b".to_string(), timestamp: String::new(), source_file: String::new(),
        json_path: String::new(), original_key_prefix: "sk-ant-".to_string(),
        original_key_hash: String::new(), encrypted_real_key: String::new(),
        encryption_salt: String::new(), virtual_key: "vk-b".to_string(),
        provider: "anthropic".to_string(), upstream: "https://api.anthropic.com".to_string(),
    };
    write_proxy_overlay(overlay_path.to_str().unwrap(), &[entry2], &["real-key-b-1234567890abcdef".to_string()]).unwrap();

    let content = std::fs::read_to_string(&overlay_path).unwrap();
    let val: toml::Value = toml::from_str(&content).unwrap();
    let mappings = val["proxy"]["key_mapping"].as_array().unwrap();
    assert_eq!(mappings.len(), 2);
}
```

**Step 2: Run to verify failure**

**Step 3: Implement overlay writer**

```rust
use crate::proxy::KeyMapping;

/// Write (or append to) the proxy config overlay with new key mappings.
pub fn write_proxy_overlay(
    path: &str,
    entries: &[RemediationEntry],
    real_keys: &[String],
) -> Result<(), String> {
    // Load existing overlay if present
    let mut existing_mappings: Vec<KeyMapping> = if let Ok(content) = std::fs::read_to_string(path) {
        if let Ok(val) = toml::from_str::<toml::Value>(&content) {
            val.get("proxy")
                .and_then(|p| p.get("key_mapping"))
                .and_then(|km| serde_json::from_value(
                    serde_json::to_value(km).unwrap_or_default()
                ).ok())
                .unwrap_or_default()
        } else {
            Vec::new()
        }
    } else {
        Vec::new()
    };

    // Add new mappings
    for (entry, real_key) in entries.iter().zip(real_keys.iter()) {
        // Don't add duplicates
        if existing_mappings.iter().any(|m| m.virtual_key == entry.virtual_key) {
            continue;
        }
        existing_mappings.push(KeyMapping {
            virtual_key: entry.virtual_key.clone(),
            real: real_key.clone(),
            provider: entry.provider.clone(),
            upstream: entry.upstream.clone(),
            ttl_secs: None,
            allowed_paths: Vec::new(),
            revoke_at_risk: 0.0,
        });
    }

    // Serialize as TOML
    #[derive(Serialize)]
    struct Overlay {
        proxy: ProxySection,
    }
    #[derive(Serialize)]
    struct ProxySection {
        key_mapping: Vec<KeyMapping>,
    }

    let overlay = Overlay {
        proxy: ProxySection {
            key_mapping: existing_mappings,
        },
    };

    if let Some(parent) = std::path::Path::new(path).parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("mkdir: {}", e))?;
    }

    let toml_str = toml::to_string_pretty(&overlay).map_err(|e| format!("serialize: {}", e))?;
    std::fs::write(path, toml_str).map_err(|e| format!("write: {}", e))
}
```

**Step 4: Run tests**

Run: `cargo test --lib test_write_proxy_overlay 2>&1 | tail -10`
Expected: PASS

**Step 5: Commit**

```bash
git add src/scanner/remediate.rs
git commit -m "feat(remediate): add proxy overlay writer for remediated key mappings"
```

---

### Task 10: Main remediation orchestrator

The function that ties it all together: scan file → extract keys → generate virtual keys → encrypt → write manifest → rewrite config → write overlay.

**Files:**
- Modify: `src/scanner/remediate.rs`

**Step 1: Write the failing integration test**

```rust
#[test]
fn test_remediate_json_file_end_to_end() {
    let dir = tempfile::tempdir().unwrap();
    let config_path = dir.path().join("openclaw.json");
    let manifest_path = dir.path().join("manifest.json");
    let overlay_path = dir.path().join("overlay.toml");

    // Write a config with a hardcoded key
    std::fs::write(&config_path, r#"{
        "channels": {
            "slack": {
                "botToken": "xoxb-1234567890-abcdefghijklmnop"
            }
        },
        "name": "test"
    }"#).unwrap();

    let results = remediate_file(
        config_path.to_str().unwrap(),
        manifest_path.to_str().unwrap(),
        overlay_path.to_str().unwrap(),
    );

    assert_eq!(results.len(), 1);
    assert!(results[0].success);

    // Verify the config was rewritten
    let new_config = std::fs::read_to_string(&config_path).unwrap();
    assert!(!new_config.contains("xoxb-1234567890"));
    assert!(new_config.contains("vk-remediated-"));

    // Verify manifest was written
    let manifest = load_manifest(manifest_path.to_str().unwrap());
    assert_eq!(manifest.remediations.len(), 1);
    assert_eq!(manifest.remediations[0].provider, "slack");

    // Verify overlay was written
    let overlay = std::fs::read_to_string(&overlay_path).unwrap();
    assert!(overlay.contains("xoxb-1234567890-abcdefghijklmnop")); // real key in overlay
}

#[test]
fn test_remediate_idempotent() {
    let dir = tempfile::tempdir().unwrap();
    let config_path = dir.path().join("openclaw.json");
    let manifest_path = dir.path().join("manifest.json");
    let overlay_path = dir.path().join("overlay.toml");

    std::fs::write(&config_path, r#"{"token": "xoxb-1234567890-abcdefghijklmnop"}"#).unwrap();

    // First remediation
    let r1 = remediate_file(config_path.to_str().unwrap(), manifest_path.to_str().unwrap(), overlay_path.to_str().unwrap());
    assert_eq!(r1.len(), 1);

    // Second remediation — should find no keys (already replaced)
    let r2 = remediate_file(config_path.to_str().unwrap(), manifest_path.to_str().unwrap(), overlay_path.to_str().unwrap());
    assert_eq!(r2.len(), 0);

    // Manifest still has exactly 1 entry
    let manifest = load_manifest(manifest_path.to_str().unwrap());
    assert_eq!(manifest.remediations.len(), 1);
}
```

**Step 2: Run to verify failure**

**Step 3: Implement the orchestrator**

```rust
/// Result of remediating a single key.
pub struct RemediationResult {
    pub success: bool,
    pub virtual_key: String,
    pub provider: String,
    pub prefix: String,
    pub error: Option<String>,
}

/// Generate a short unique ID for a remediation entry.
fn generate_remediation_id() -> String {
    let mut bytes = [0u8; 4];
    rand::thread_rng().fill_bytes(&mut bytes);
    hex::encode(bytes)
}

/// Generate a SHA-256 hash of a key for integrity verification.
fn hash_key(key: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(key.as_bytes());
    format!("sha256:{}", hex::encode(hasher.finalize()))
}

/// Remediate all hardcoded keys found in a single config file.
/// Handles both JSON and YAML based on file extension.
/// Returns a list of remediation results (one per key found and processed).
pub fn remediate_file(
    file_path: &str,
    manifest_path: &str,
    overlay_path: &str,
) -> Vec<RemediationResult> {
    let content = match std::fs::read_to_string(file_path) {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };

    let is_yaml = file_path.ends_with(".yaml") || file_path.ends_with(".yml");
    let keys = if is_yaml {
        extract_keys_from_yaml(&content)
    } else {
        extract_keys_from_json(&content)
    };

    if keys.is_empty() {
        return Vec::new();
    }

    // Load existing manifest to check for already-remediated keys
    let mut manifest = load_manifest(manifest_path);

    // Preserve file metadata for restore
    let metadata = std::fs::metadata(file_path).ok();

    let mut results = Vec::new();
    let mut current_content = content;
    let mut new_entries = Vec::new();
    let mut real_keys = Vec::new();

    for key in &keys {
        // Skip if already remediated (idempotent)
        if manifest.remediations.iter().any(|r| r.source_file == file_path && r.json_path == key.json_path) {
            continue;
        }

        let id = generate_remediation_id();
        let (provider, upstream) = detect_provider_from_context(&key.json_path, &key.full_key);
        let virtual_key = format!("vk-remediated-{}-{}", provider, id);

        // Encrypt the real key for backup
        let encrypted = match encrypt_key(&key.full_key) {
            Ok(e) => e,
            Err(err) => {
                results.push(RemediationResult {
                    success: false, virtual_key: String::new(),
                    provider: provider.clone(), prefix: key.prefix.clone(),
                    error: Some(format!("encrypt failed: {}", err)),
                });
                continue;
            }
        };

        // Rewrite the config file content
        let rewrite_result = if is_yaml {
            rewrite_yaml_key(&current_content, &key.full_key, &virtual_key)
        } else {
            rewrite_json_key(&current_content, &key.json_path, &virtual_key)
        };

        match rewrite_result {
            Ok(new_content) => current_content = new_content,
            Err(err) => {
                results.push(RemediationResult {
                    success: false, virtual_key: String::new(),
                    provider: provider.clone(), prefix: key.prefix.clone(),
                    error: Some(format!("rewrite failed: {}", err)),
                });
                continue;
            }
        }

        let timestamp = chrono_timestamp();

        let entry = RemediationEntry {
            id,
            timestamp,
            source_file: file_path.to_string(),
            json_path: key.json_path.clone(),
            original_key_prefix: key.prefix.clone(),
            original_key_hash: hash_key(&key.full_key),
            encrypted_real_key: encrypted.ciphertext,
            encryption_salt: encrypted.salt,
            virtual_key: virtual_key.clone(),
            provider: provider.clone(),
            upstream: upstream.clone(),
        };

        real_keys.push(key.full_key.clone());
        new_entries.push(entry);

        results.push(RemediationResult {
            success: true,
            virtual_key,
            provider,
            prefix: key.prefix.clone(),
            error: None,
        });
    }

    if new_entries.is_empty() {
        return results;
    }

    // Write the modified config file
    if let Err(e) = std::fs::write(file_path, &current_content) {
        eprintln!("Failed to write remediated config: {}", e);
        return results;
    }

    // Restore file permissions if possible
    #[cfg(unix)]
    if let Some(meta) = metadata {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(file_path, meta.permissions());
    }

    // Write proxy overlay
    if let Err(e) = write_proxy_overlay(overlay_path, &new_entries, &real_keys) {
        eprintln!("Failed to write proxy overlay: {}", e);
    }

    // Update and save manifest
    manifest.remediations.extend(new_entries);
    if let Err(e) = save_manifest(manifest_path, &manifest) {
        eprintln!("Failed to save manifest: {}", e);
    }

    results
}

/// Generate an ISO 8601 timestamp string.
fn chrono_timestamp() -> String {
    // Use std::time since chrono is not a dependency
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    format!("{}Z", now) // Unix timestamp as fallback; upgrade to chrono if available
}
```

**Step 4: Run tests**

Run: `cargo test --lib test_remediate_json_file_end_to_end test_remediate_idempotent 2>&1 | tail -10`
Expected: PASS

**Step 5: Commit**

```bash
git add src/scanner/remediate.rs
git commit -m "feat(remediate): add main remediation orchestrator"
```

---

### Task 11: Wire scanner to remediation

Modify `scan_openclaw_hardcoded_secrets()` to call the remediation engine when keys are found.

**Files:**
- Modify: `src/scanner/network.rs`

**Step 1: Write the failing test**

Add to the existing `tests` module in `network.rs` (or in `remediate.rs`):

```rust
#[test]
fn test_scanner_triggers_remediation() {
    let dir = tempfile::tempdir().unwrap();
    let openclaw_dir = dir.path().join(".openclaw");
    std::fs::create_dir_all(&openclaw_dir).unwrap();

    let config_path = openclaw_dir.join("openclaw.json");
    std::fs::write(&config_path, r#"{"token": "xoxb-1234567890-abcdefghijklmnop"}"#).unwrap();

    let manifest_path = dir.path().join("manifest.json");
    let overlay_path = dir.path().join("overlay.toml");

    // Call remediation directly (the scanner calls this internally)
    let results = super::remediate::remediate_file(
        config_path.to_str().unwrap(),
        manifest_path.to_str().unwrap(),
        overlay_path.to_str().unwrap(),
    );
    assert!(!results.is_empty());
    assert!(results[0].success);

    // After remediation, the scanner should pass (no more hardcoded keys)
    let content = std::fs::read_to_string(&config_path).unwrap();
    assert!(!content.contains("xoxb-1234567890"));
}
```

**Step 2: Run to verify it fails (or passes — this tests the integration)**

**Step 3: Modify `scan_openclaw_hardcoded_secrets()`**

In `src/scanner/network.rs`, modify the function to call remediation when keys are found. The key change: after detecting keys (the `found` vec is non-empty), call `remediate_file()` for each config file.

At the top of `network.rs`, add:
```rust
use super::remediate;
```

Then modify `scan_openclaw_hardcoded_secrets()` — after the detection loop (line ~525), before returning the Fail result, add the remediation call:

```rust
// After: if found.is_empty() { return Pass }

// Attempt auto-remediation
let mut remediated = Vec::new();
for path in &config_paths {
    let results = remediate::remediate_file(
        path,
        remediate::MANIFEST_PATH,
        remediate::OVERLAY_PATH,
    );
    for r in results {
        if r.success {
            remediated.push(format!("{}→{} ({})", r.prefix, r.virtual_key, r.provider));
        }
    }
}

if !remediated.is_empty() {
    // Return a different category so the alert shows remediation happened
    return ScanResult::new("openclaw:remediated_secrets", ScanStatus::Fail,
        &format!("Auto-remediated {} hardcoded key(s): {}. Real keys secured in proxy config. Run `clawtower restore-keys` to reverse.",
            remediated.len(), remediated.join(", ")));
}

// If remediation failed, return original detection alert
ScanResult::new("openclaw:hardcoded_secrets", ScanStatus::Fail,
    &format!("Hardcoded API keys in config (use env vars instead): {}",
        found.join(", ")))
```

**Step 4: Run tests**

Run: `cargo test --lib test_scanner_triggers_remediation 2>&1 | tail -10`
Expected: PASS

Run: `cargo test 2>&1 | tail -20`
Expected: full suite passes

**Step 5: Commit**

```bash
git add src/scanner/network.rs
git commit -m "feat(remediate): wire scanner to auto-remediation on key detection"
```

---

### Task 12: Proxy hot-reload channel

Add a `tokio::sync::watch` channel so the proxy can reload key mappings at runtime.

**Files:**
- Modify: `src/proxy/mod.rs`
- Modify: `src/core/orchestrator.rs`

**Step 1: Modify ProxyServer to accept a reload receiver**

In `src/proxy/mod.rs`, change `ProxyServer` to optionally accept a reload signal:

Add a `reload_rx: Option<tokio::sync::watch::Receiver<()>>` field to `ProxyServer`.

Modify `ProxyServer::new()` to accept it, and add a `ProxyServer::new_with_reload()` constructor.

In `start()`, after binding the server, spawn a side task that watches the reload channel. When signaled, it re-reads the config overlay and updates the shared state.

For the shared mutable state, change `ProxyState`'s `key_mappings` and `credential_states` to `Arc<tokio::sync::RwLock<...>>` so the reload task can swap them.

This is the most structurally complex change. The key modifications:

1. `ProxyState.key_mappings` → `Arc<RwLock<Vec<KeyMapping>>>`
2. `ProxyState.credential_states` → `Arc<RwLock<HashMap<String, CredentialState>>>`
3. `handle_request()` — acquire read locks where it accesses these fields
4. New `reload_mappings()` function that re-reads the overlay and swaps in new data
5. `start()` spawns a reload watcher task alongside the server

**Step 2: Verify compilation**

Run: `cargo check 2>&1 | tail -10`
Expected: compiles

**Step 3: Modify orchestrator to create and pass reload channel**

In `src/core/orchestrator.rs` where the proxy is spawned (line ~127-136), create a `watch::channel` and pass the receiver to `ProxyServer`:

```rust
let (proxy_reload_tx, proxy_reload_rx) = tokio::sync::watch::channel(());
// Store proxy_reload_tx somewhere accessible (e.g., in AppState or a shared Arc)
let server = proxy::ProxyServer::new_with_reload(proxy_config, firewall_config, proxy_tx, proxy_reload_rx);
```

**Step 4: Run full test suite**

Run: `cargo test 2>&1 | tail -20`
Expected: all pass

**Step 5: Commit**

```bash
git add src/proxy/mod.rs src/core/orchestrator.rs
git commit -m "feat(proxy): add hot-reload channel for runtime key mapping updates"
```

---

### Task 13: `restore-keys` CLI subcommand

**Files:**
- Modify: `src/cli.rs`
- Modify: `src/scanner/remediate.rs` (add `restore_keys()` function)

**Step 1: Write the failing test for restore logic**

Add to `remediate.rs` tests:

```rust
#[test]
fn test_restore_keys_roundtrip() {
    let dir = tempfile::tempdir().unwrap();
    let config_path = dir.path().join("openclaw.json");
    let manifest_path = dir.path().join("manifest.json");
    let overlay_path = dir.path().join("overlay.toml");

    let original = r#"{"token": "xoxb-1234567890-abcdefghijklmnop"}"#;
    std::fs::write(&config_path, original).unwrap();

    // Remediate
    remediate_file(
        config_path.to_str().unwrap(),
        manifest_path.to_str().unwrap(),
        overlay_path.to_str().unwrap(),
    );

    // Config should now have virtual key
    let remediated = std::fs::read_to_string(&config_path).unwrap();
    assert!(!remediated.contains("xoxb-1234567890"));

    // Restore
    let restored = restore_keys(
        manifest_path.to_str().unwrap(),
        overlay_path.to_str().unwrap(),
        None, // restore all
        false, // not dry-run
    );
    assert_eq!(restored, 1);

    // Config should have real key back
    let final_content = std::fs::read_to_string(&config_path).unwrap();
    assert!(final_content.contains("xoxb-1234567890-abcdefghijklmnop"));

    // Manifest should be empty
    let manifest = load_manifest(manifest_path.to_str().unwrap());
    assert!(manifest.remediations.is_empty());
}
```

**Step 2: Run to verify failure**

**Step 3: Implement `restore_keys()`**

Add to `remediate.rs`:

```rust
/// Restore remediated keys back to their original config files.
/// Returns the number of keys successfully restored.
pub fn restore_keys(
    manifest_path: &str,
    overlay_path: &str,
    filter_id: Option<&str>,
    dry_run: bool,
) -> usize {
    let mut manifest = load_manifest(manifest_path);
    if manifest.remediations.is_empty() {
        eprintln!("No remediated keys to restore.");
        return 0;
    }

    // Load overlay to get real keys
    let overlay_content = std::fs::read_to_string(overlay_path).unwrap_or_default();
    let overlay_mappings: Vec<crate::proxy::KeyMapping> = if let Ok(val) = toml::from_str::<toml::Value>(&overlay_content) {
        val.get("proxy")
            .and_then(|p| p.get("key_mapping"))
            .and_then(|km| serde_json::from_value(serde_json::to_value(km).unwrap_or_default()).ok())
            .unwrap_or_default()
    } else {
        Vec::new()
    };

    let mut restored_count = 0;
    let mut remaining = Vec::new();
    let mut remaining_vks: std::collections::HashSet<String> = std::collections::HashSet::new();

    for entry in &manifest.remediations {
        // Filter by ID if specified
        if let Some(id) = filter_id {
            if !entry.id.starts_with(id) {
                remaining.push(entry.clone());
                remaining_vks.insert(entry.virtual_key.clone());
                continue;
            }
        }

        // Find real key: try overlay first, then encrypted backup
        let real_key = overlay_mappings.iter()
            .find(|m| m.virtual_key == entry.virtual_key)
            .map(|m| m.real.clone())
            .or_else(|| {
                decrypt_key(&EncryptedKey {
                    ciphertext: entry.encrypted_real_key.clone(),
                    salt: entry.encryption_salt.clone(),
                }).ok()
            });

        let real_key = match real_key {
            Some(k) => k,
            None => {
                eprintln!("Cannot recover real key for {} — skipping", entry.virtual_key);
                remaining.push(entry.clone());
                remaining_vks.insert(entry.virtual_key.clone());
                continue;
            }
        };

        // Verify hash
        let expected_hash = hash_key(&real_key);
        if expected_hash != entry.original_key_hash {
            eprintln!("Hash mismatch for {} — key may be corrupted", entry.virtual_key);
            remaining.push(entry.clone());
            remaining_vks.insert(entry.virtual_key.clone());
            continue;
        }

        if dry_run {
            println!("Would restore: {} → {}...{} in {}",
                entry.virtual_key, &real_key[..real_key.len().min(8)], "***",
                entry.source_file);
            remaining.push(entry.clone());
            remaining_vks.insert(entry.virtual_key.clone());
            restored_count += 1;
            continue;
        }

        // Read config file and replace virtual key with real key
        let config_content = match std::fs::read_to_string(&entry.source_file) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("Cannot read {}: {}", entry.source_file, e);
                remaining.push(entry.clone());
                remaining_vks.insert(entry.virtual_key.clone());
                continue;
            }
        };

        let new_content = config_content.replace(&entry.virtual_key, &real_key);
        if let Err(e) = std::fs::write(&entry.source_file, &new_content) {
            eprintln!("Cannot write {}: {}", entry.source_file, e);
            remaining.push(entry.clone());
            remaining_vks.insert(entry.virtual_key.clone());
            continue;
        }

        restored_count += 1;
    }

    if !dry_run {
        // Update manifest (remove restored entries)
        manifest.remediations = remaining;
        let _ = save_manifest(manifest_path, &manifest);

        // Update overlay (remove restored mappings)
        let kept_mappings: Vec<crate::proxy::KeyMapping> = overlay_mappings.into_iter()
            .filter(|m| remaining_vks.contains(&m.virtual_key))
            .collect();
        if kept_mappings.is_empty() {
            let _ = std::fs::remove_file(overlay_path);
        } else {
            let _ = write_proxy_overlay_raw(overlay_path, &kept_mappings);
        }
    }

    restored_count
}

/// Write a raw list of KeyMappings to the overlay (used by restore to rewrite without new entries).
fn write_proxy_overlay_raw(path: &str, mappings: &[crate::proxy::KeyMapping]) -> Result<(), String> {
    #[derive(Serialize)]
    struct Overlay { proxy: ProxySection }
    #[derive(Serialize)]
    struct ProxySection { key_mapping: Vec<crate::proxy::KeyMapping> }

    let overlay = Overlay {
        proxy: ProxySection { key_mapping: mappings.to_vec() },
    };
    let toml_str = toml::to_string_pretty(&overlay).map_err(|e| format!("serialize: {}", e))?;
    std::fs::write(path, toml_str).map_err(|e| format!("write: {}", e))
}
```

**Step 4: Run tests**

Run: `cargo test --lib test_restore_keys_roundtrip 2>&1 | tail -10`
Expected: PASS

**Step 5: Wire up the CLI**

In `src/cli.rs`, add a new match arm before `_ => Ok(false)` (around line 572):

```rust
"restore-keys" => {
    let dry_run = rest_args.iter().any(|a| a == "--dry-run");
    let filter_id = rest_args.iter()
        .find_map(|a| a.strip_prefix("--id="));

    let count = crate::scanner::remediate::restore_keys(
        crate::scanner::remediate::MANIFEST_PATH,
        crate::scanner::remediate::OVERLAY_PATH,
        filter_id,
        dry_run,
    );

    if dry_run {
        eprintln!("Dry run: {} key(s) would be restored.", count);
    } else {
        eprintln!("Restored {} key(s) to original config files.", count);
    }
    Ok(true)
}
```

Also add `restore-keys` to the help text in `print_help()` and to the `ensure_root()` allowlist if it should be runnable without root.

**Step 6: Run full test suite**

Run: `cargo test 2>&1 | tail -20`
Expected: all pass

**Step 7: Commit**

```bash
git add src/scanner/remediate.rs src/cli.rs
git commit -m "feat(remediate): add restore-keys CLI command for reversible key remediation"
```

---

### Task 14: Final integration test and cleanup

**Files:**
- Modify: `src/scanner/remediate.rs` (add comprehensive integration test)

**Step 1: Write full integration test**

```rust
#[test]
fn test_full_lifecycle_remediate_and_restore() {
    let dir = tempfile::tempdir().unwrap();
    let config_path = dir.path().join("openclaw.json");
    let manifest_path = dir.path().join("manifest.json");
    let overlay_path = dir.path().join("overlay.toml");

    // Multi-key config
    let original = r#"{
        "channels": { "slack": { "botToken": "xoxb-1234567890-abcdefghijklmnop" } },
        "providers": { "anthropic": { "apiKey": "sk-ant-abcdefghijklmnop1234567890" } },
        "name": "test-agent"
    }"#;
    std::fs::write(&config_path, original).unwrap();

    // Remediate
    let results = remediate_file(
        config_path.to_str().unwrap(),
        manifest_path.to_str().unwrap(),
        overlay_path.to_str().unwrap(),
    );
    assert_eq!(results.len(), 2);
    assert!(results.iter().all(|r| r.success));

    // Verify both keys replaced
    let content = std::fs::read_to_string(&config_path).unwrap();
    assert!(!content.contains("xoxb-"));
    assert!(!content.contains("sk-ant-"));
    assert!(content.contains("vk-remediated-slack-"));
    assert!(content.contains("vk-remediated-anthropic-"));

    // Verify manifest has 2 entries
    let manifest = load_manifest(manifest_path.to_str().unwrap());
    assert_eq!(manifest.remediations.len(), 2);

    // Verify overlay has 2 mappings
    let overlay = std::fs::read_to_string(&overlay_path).unwrap();
    let val: toml::Value = toml::from_str(&overlay).unwrap();
    let mappings = val["proxy"]["key_mapping"].as_array().unwrap();
    assert_eq!(mappings.len(), 2);

    // Restore all
    let restored = restore_keys(
        manifest_path.to_str().unwrap(),
        overlay_path.to_str().unwrap(),
        None,
        false,
    );
    assert_eq!(restored, 2);

    // Verify original keys restored
    let final_content = std::fs::read_to_string(&config_path).unwrap();
    assert!(final_content.contains("xoxb-1234567890-abcdefghijklmnop"));
    assert!(final_content.contains("sk-ant-abcdefghijklmnop1234567890"));
}
```

**Step 2: Run tests**

Run: `cargo test --lib test_full_lifecycle 2>&1 | tail -10`
Expected: PASS

**Step 3: Run full suite**

Run: `cargo test 2>&1 | tail -20`
Expected: all pass

**Step 4: Run clippy**

Run: `cargo clippy 2>&1 | tail -20`
Expected: no warnings in new code

**Step 5: Commit**

```bash
git add src/scanner/remediate.rs
git commit -m "test(remediate): add full lifecycle integration test"
```

---

## Summary of all tasks

| # | Task | Files | Estimated Size |
|---|---|---|---|
| 1 | Add aes-gcm dep | Cargo.toml | Tiny |
| 2 | Manifest types + load/save | scanner/remediate.rs, scanner/mod.rs | ~60 lines |
| 3 | AES-256-GCM encryption | scanner/remediate.rs | ~60 lines |
| 4 | Provider detection | scanner/remediate.rs | ~60 lines |
| 5 | JSON key extraction | scanner/remediate.rs | ~60 lines |
| 6 | YAML key extraction | scanner/remediate.rs | ~40 lines |
| 7 | JSON rewriting | scanner/remediate.rs | ~40 lines |
| 8 | YAML rewriting | scanner/remediate.rs | ~15 lines |
| 9 | Proxy overlay writer | scanner/remediate.rs | ~60 lines |
| 10 | Main orchestrator | scanner/remediate.rs | ~120 lines |
| 11 | Wire scanner → remediation | scanner/network.rs | ~25 lines |
| 12 | Proxy hot-reload | proxy/mod.rs, orchestrator.rs | ~80 lines |
| 13 | restore-keys CLI | cli.rs, scanner/remediate.rs | ~100 lines |
| 14 | Integration test + cleanup | scanner/remediate.rs | ~50 lines |
