# TUI Improvements Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add 12 improvements to ClawTower's TUI: scrollable lists, alert detail view, DRY filtered tabs, status bar, tab counts, better color theming, relative timestamps, cached `which` calls, config validation, search/filter, zeroize sudo password, pause/mute.

**Architecture:** All changes are in `src/tui.rs` and `src/alerts.rs`. No new files. Add `zeroize` crate to Cargo.toml. The App struct gains new state fields (scroll positions, search buffer, pause flag, detail view). Rendering functions are refactored into a generic filtered renderer. No cargo available locally — edit code, push, CI builds.

**Tech Stack:** Rust, ratatui 0.29, crossterm 0.28, chrono, zeroize

**Important:** No `cargo` on this machine. You cannot run tests or compile locally. Edit code, commit, push — CI handles the rest. For "run test" steps, just verify code compiles logically and commit.

---

### Task 1: Add `zeroize` dependency to Cargo.toml

**Files:**
- Modify: `Cargo.toml`

**Step 1: Add zeroize to dependencies**

In `Cargo.toml`, add after the `xattr` line:

```toml
zeroize = "1"
```

**Step 2: Commit**

```bash
git add Cargo.toml
git commit -m "chore: add zeroize dependency for secure password handling"
```

---

### Task 2: Add scroll state, search, pause, detail view, and cached tool state to App

**Files:**
- Modify: `src/tui.rs`

**Step 1: Add imports**

At the top of `src/tui.rs`, add to the existing imports:

```rust
use ratatui::widgets::ListState;
use zeroize::Zeroize;
```

And add to the `use std::` block:

```rust
use std::collections::HashMap;
```

**Step 2: Add new state fields to App struct**

Add these fields to the `App` struct, after `sudo_popup`:

```rust
    // Scroll state per tab (tab index -> ListState)
    pub list_states: [ListState; 5], // tabs 0-4 (alerts, network, falco, fim, system)
    // Alert detail view
    pub detail_alert: Option<Alert>,
    // Search/filter
    pub search_active: bool,
    pub search_buffer: String,
    pub search_filter: String, // committed search (applied on Enter)
    // Pause alert feed
    pub paused: bool,
    // Cached tool installation status
    pub tool_status_cache: HashMap<String, bool>,
    // Muted sources (alerts from these sources are hidden)
    pub muted_sources: Vec<String>,
```

**Step 3: Update `App::new()` to initialize new fields**

After the `sudo_popup: None,` line, add:

```rust
            list_states: std::array::from_fn(|_| {
                let mut s = ListState::default();
                s.select(Some(0));
                s
            }),
            detail_alert: None,
            search_active: false,
            search_buffer: String::new(),
            search_filter: String::new(),
            paused: false,
            tool_status_cache: HashMap::new(),
            muted_sources: Vec::new(),
```

**Step 4: Add a method to cache tool status**

Add this method to the `impl App` block:

```rust
    /// Check and cache whether a tool is installed (runs `which` once per tool).
    pub fn is_tool_installed(&mut self, tool: &str) -> bool {
        if let Some(&cached) = self.tool_status_cache.get(tool) {
            return cached;
        }
        let installed = std::process::Command::new("which")
            .arg(tool)
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
        self.tool_status_cache.insert(tool.to_string(), installed);
        installed
    }

    /// Invalidate cached tool status (e.g., after installing).
    pub fn invalidate_tool_cache(&mut self) {
        self.tool_status_cache.clear();
    }
```

**Step 5: Commit**

```bash
git add src/tui.rs
git commit -m "feat(tui): add state for scroll, search, pause, detail, tool cache"
```

---

### Task 3: Zeroize sudo password and use cached tool checks

**Files:**
- Modify: `src/tui.rs`

**Step 1: Zeroize password in SudoPopup after use**

In `run_sudo_action`, right after `let password = popup.password.clone();` at the top of the `Enter` match arm in the sudo popup handler, add:

```rust
                            popup.password.zeroize();
```

Also, in the `SudoPopup` dismiss arm (the `SudoStatus::Failed(_)` handler), before `self.sudo_popup = None;`:

```rust
                    if let Some(ref mut p) = self.sudo_popup {
                        p.password.zeroize();
                    }
```

Wait — the structure is already being dropped. Better approach: implement `Drop` for `SudoPopup`:

```rust
impl Drop for SudoPopup {
    fn drop(&mut self) {
        self.password.zeroize();
    }
}
```

Add this right after the `SudoPopup` struct definition.

**Step 2: Replace `which` calls in `get_section_fields` with cached version**

The `get_section_fields` function is a free function that takes `&Config` — it can't access `App`. Change `get_section_fields` signature to also accept the tool cache:

```rust
fn get_section_fields(config: &Config, section: &str, tool_cache: &HashMap<String, bool>) -> Vec<ConfigField> {
```

In the `"falco"` arm, replace:
```rust
            let falco_installed = std::process::Command::new("which")
                .arg("falco")
                .output()
                .map(|o| o.status.success())
                .unwrap_or(false);
```
with:
```rust
            let falco_installed = tool_cache.get("falco").copied().unwrap_or(false);
```

Same for `"samhain"` arm — replace the `which` command with:
```rust
            let samhain_installed = tool_cache.get("samhain").copied().unwrap_or(false);
```

**Step 3: Update `refresh_fields` to pass cache and pre-populate it**

```rust
    pub fn refresh_fields(&mut self) {
        if let Some(ref config) = self.config {
            // Ensure tool status is cached
            let _ = self.is_tool_installed("falco");
            let _ = self.is_tool_installed("samhain");
            let section = &self.config_sections[self.config_selected_section];
            self.config_fields = get_section_fields(config, section, &self.tool_status_cache);
            if self.config_selected_field >= self.config_fields.len() && !self.config_fields.is_empty() {
                self.config_selected_field = 0;
            }
        }
    }
```

**Step 4: After successful install action, invalidate cache**

In `run_sudo_action`, in the success branch where it sets `"✅ Installed!"`, add:

```rust
                    self.invalidate_tool_cache();
```

**Step 5: Commit**

```bash
git add src/tui.rs
git commit -m "feat(tui): zeroize sudo password, cache tool install checks"
```

---

### Task 4: DRY up filtered alert tabs into a single generic renderer

**Files:**
- Modify: `src/tui.rs`

**Step 1: Create generic filtered alert renderer**

Replace the four separate functions (`render_alerts_tab`, `render_network_tab`, `render_falco_tab`, `render_fim_tab`) with one:

```rust
fn render_alert_list(
    f: &mut Frame,
    area: Rect,
    app: &mut App,
    tab_index: usize,
    source_filter: Option<&str>,
    title: &str,
) {
    let alerts = app.alert_store.alerts();
    let filtered: Vec<&Alert> = alerts
        .iter()
        .rev()
        .filter(|a| {
            // Source filter (for network/falco/fim tabs)
            if let Some(src) = source_filter {
                if a.source != src {
                    return false;
                }
            }
            // Muted sources
            if app.muted_sources.contains(&a.source) {
                return false;
            }
            // Search filter
            if !app.search_filter.is_empty() {
                let haystack = a.to_string().to_lowercase();
                if !haystack.contains(&app.search_filter.to_lowercase()) {
                    return false;
                }
            }
            true
        })
        .collect();

    let now = Local::now();
    let items: Vec<ListItem> = filtered
        .iter()
        .map(|alert| {
            let age = now.signed_duration_since(alert.timestamp);
            let age_str = if age.num_seconds() < 60 {
                format!("{}s ago", age.num_seconds())
            } else if age.num_minutes() < 60 {
                format!("{}m ago", age.num_minutes())
            } else if age.num_hours() < 24 {
                format!("{}h ago", age.num_hours())
            } else {
                format!("{}d ago", age.num_days())
            };

            let style = match alert.severity {
                Severity::Critical => Style::default().fg(Color::Red).bold(),
                Severity::Warning => Style::default().fg(Color::Yellow),
                Severity::Info => Style::default().fg(Color::Blue),
            };
            ListItem::new(format!(
                "{} {} [{}] {}",
                age_str, alert.severity, alert.source, alert.message
            ))
            .style(style)
        })
        .collect();

    let count = items.len();
    let display_title = format!(" {} ({}) ", title, count);

    let pause_indicator = if app.paused { " ⏸ PAUSED " } else { "" };
    let full_title = format!("{}{}", display_title, pause_indicator);

    let list = List::new(items)
        .block(Block::default().borders(Borders::ALL).title(full_title))
        .highlight_style(Style::default().bg(Color::DarkGray).fg(Color::White))
        .highlight_symbol("▶ ");

    f.render_stateful_widget(list, area, &mut app.list_states[tab_index]);
}
```

Note: this requires `use chrono::Local;` at the top (chrono is already imported for Alert).

**Step 2: Update `ui()` to call the generic renderer**

Replace the match arms in `ui()`:

```rust
    match app.selected_tab {
        0 => render_alert_list(f, chunks[1], app, 0, None, "Alert Feed"),
        1 => render_alert_list(f, chunks[1], app, 1, Some("network"), "Network Activity"),
        2 => render_alert_list(f, chunks[1], app, 2, Some("falco"), "Falco eBPF Alerts"),
        3 => render_alert_list(f, chunks[1], app, 3, Some("samhain"), "File Integrity"),
        4 => render_system_tab(f, chunks[1], app),
        5 => render_config_tab(f, chunks[1], app),
        _ => {}
    }
```

But wait — `ui()` takes `&App` (immutable). We need `&mut App` for `ListState`. Change the signature:

```rust
fn ui(f: &mut Frame, app: &mut App) {
```

And in `run_tui`, change the draw call:

```rust
        terminal.draw(|f| ui(f, &mut app))?;
```

**Step 3: Delete the old `render_alerts_tab`, `render_network_tab`, `render_falco_tab`, `render_fim_tab` functions**

They are fully replaced by `render_alert_list`.

**Step 4: Commit**

```bash
git add src/tui.rs
git commit -m "refactor(tui): DRY filtered tabs into generic render_alert_list with scroll, relative timestamps, counts"
```

---

### Task 5: Add alert counts to tab titles

**Files:**
- Modify: `src/tui.rs`

**Step 1: Make tab titles dynamic in `ui()`**

Instead of using `app.tab_titles` directly, compute titles with counts:

```rust
    // Compute tab titles with counts
    let alerts = app.alert_store.alerts();
    let total = alerts.len();
    let net_count = alerts.iter().filter(|a| a.source == "network").count();
    let falco_count = alerts.iter().filter(|a| a.source == "falco").count();
    let fim_count = alerts.iter().filter(|a| a.source == "samhain").count();

    let tab_titles: Vec<Line> = vec![
        Line::from(format!("Alerts ({})", total)),
        Line::from(format!("Network ({})", net_count)),
        Line::from(format!("Falco ({})", falco_count)),
        Line::from(format!("FIM ({})", fim_count)),
        Line::from("System".to_string()),
        Line::from("Config".to_string()),
    ];

    let tabs = Tabs::new(tab_titles)
        .block(Block::default().borders(Borders::ALL).title(" 🛡️ ClawTower "))
        .select(app.selected_tab)
        .style(Style::default().fg(Color::White))
        .highlight_style(Style::default().fg(Color::Cyan).bold());
    f.render_widget(tabs, chunks[0]);
```

**Step 2: Commit**

```bash
git add src/tui.rs
git commit -m "feat(tui): show alert counts in tab titles"
```

---

### Task 6: Add context-sensitive footer/status bar

**Files:**
- Modify: `src/tui.rs`

**Step 1: Update layout in `ui()` to add footer**

Change the layout from 2 chunks to 3:

```rust
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),  // tab bar
            Constraint::Min(0),    // content
            Constraint::Length(1), // footer
        ])
        .split(f.area());
```

**Step 2: Add footer rendering at the end of `ui()`**

After the content match and before the sudo popup overlay:

```rust
    // Footer / status bar
    let footer_text = if app.search_active {
        format!(" 🔍 Search: {}▌  (Enter to apply, Esc to cancel)", app.search_buffer)
    } else if app.detail_alert.is_some() {
        " Esc: back │ m: mute source".to_string()
    } else {
        match app.selected_tab {
            0..=3 => {
                let pause = if app.paused { "Space: resume" } else { "Space: pause" };
                let filter = if !app.search_filter.is_empty() {
                    format!(" │ Filter: \"{}\" (Esc clears)", app.search_filter)
                } else {
                    String::new()
                };
                format!(" Tab: switch │ ↑↓: scroll │ Enter: detail │ /: search │ {}{} │ q: quit", pause, filter)
            }
            4 => " Tab: switch │ q: quit".to_string(),
            5 => {
                if app.config_editing {
                    " Enter: confirm │ Esc: cancel".to_string()
                } else if app.config_focus == ConfigFocus::Fields {
                    " ↑↓: navigate │ Enter: edit │ Backspace: sidebar │ Ctrl+S: save │ Tab: switch".to_string()
                } else {
                    " ↑↓: sections │ Enter: fields │ ←→: tabs │ Tab: switch │ q: quit".to_string()
                }
            }
            _ => String::new(),
        }
    };

    let footer = Paragraph::new(Line::from(footer_text))
        .style(Style::default().fg(Color::DarkGray).bg(Color::Black));
    f.render_widget(footer, chunks[2]);
```

**Step 3: Commit**

```bash
git add src/tui.rs
git commit -m "feat(tui): add context-sensitive footer with keybind hints"
```

---

### Task 7: Add alert detail view

**Files:**
- Modify: `src/tui.rs`

**Step 1: Add detail view renderer**

```rust
fn render_detail_view(f: &mut Frame, area: Rect, alert: &Alert) {
    let now = Local::now();
    let age = now.signed_duration_since(alert.timestamp);
    let age_str = if age.num_seconds() < 60 {
        format!("{} seconds ago", age.num_seconds())
    } else if age.num_minutes() < 60 {
        format!("{} minutes ago", age.num_minutes())
    } else if age.num_hours() < 24 {
        format!("{} hours ago", age.num_hours())
    } else {
        format!("{} days ago", age.num_days())
    };

    let severity_style = match alert.severity {
        Severity::Critical => Style::default().fg(Color::Red).bold(),
        Severity::Warning => Style::default().fg(Color::Yellow).bold(),
        Severity::Info => Style::default().fg(Color::Blue).bold(),
    };

    let text = vec![
        Line::from(vec![
            Span::styled(format!(" {} ", alert.severity), severity_style),
            Span::raw("  "),
            Span::styled(&alert.source, Style::default().fg(Color::Cyan).bold()),
        ]),
        Line::from(""),
        Line::from(vec![
            Span::styled("Timestamp: ", Style::default().fg(Color::DarkGray)),
            Span::raw(alert.timestamp.format("%Y-%m-%d %H:%M:%S%.3f").to_string()),
            Span::styled(format!("  ({})", age_str), Style::default().fg(Color::DarkGray)),
        ]),
        Line::from(""),
        Line::from(vec![
            Span::styled("Source: ", Style::default().fg(Color::DarkGray)),
            Span::raw(&alert.source),
        ]),
        Line::from(""),
        Line::from(vec![
            Span::styled("Severity: ", Style::default().fg(Color::DarkGray)),
            Span::styled(
                format!("{} {}", alert.severity.emoji(), alert.severity),
                severity_style,
            ),
        ]),
        Line::from(""),
        Line::from(Span::styled("Message:", Style::default().fg(Color::DarkGray))),
        Line::from(""),
    ];

    // Word-wrap the message to fit the area
    let msg_lines: Vec<Line> = alert
        .message
        .chars()
        .collect::<Vec<_>>()
        .chunks(area.width.saturating_sub(4) as usize)
        .map(|chunk| Line::from(format!("  {}", chunk.iter().collect::<String>())))
        .collect();

    let mut all_lines = text;
    all_lines.extend(msg_lines);

    let paragraph = Paragraph::new(all_lines)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .title(" Alert Detail ")
                .border_style(Style::default().fg(Color::Cyan)),
        );
    f.render_widget(paragraph, area);
}
```

**Step 2: Add detail view rendering in `ui()`**

In the content area section of `ui()`, before the tab match, add:

```rust
    // Detail view overrides tab content
    if let Some(ref alert) = app.detail_alert {
        render_detail_view(f, chunks[1], alert);
    } else {
        match app.selected_tab {
            // ... existing match arms
        }
    }
```

**Step 3: Commit**

```bash
git add src/tui.rs
git commit -m "feat(tui): add alert detail view panel"
```

---

### Task 8: Add keyboard handlers for scroll, Enter/detail, search, pause, mute

**Files:**
- Modify: `src/tui.rs`

**Step 1: Update `on_key` to handle new features**

This is the big one. The `on_key` method needs major updates. Replace the current match block after the sudo popup and saved message handling with:

```rust
        // Search mode input
        if self.search_active {
            match key {
                KeyCode::Enter => {
                    self.search_filter = self.search_buffer.clone();
                    self.search_active = false;
                }
                KeyCode::Esc => {
                    self.search_active = false;
                    self.search_buffer.clear();
                }
                KeyCode::Backspace => { self.search_buffer.pop(); }
                KeyCode::Char(c) => { self.search_buffer.push(c); }
                _ => {}
            }
            return;
        }

        // Detail view mode
        if self.detail_alert.is_some() {
            match key {
                KeyCode::Esc | KeyCode::Backspace | KeyCode::Char('q') => {
                    self.detail_alert = None;
                }
                KeyCode::Char('m') => {
                    // Mute/unmute the source of the viewed alert
                    if let Some(ref alert) = self.detail_alert {
                        let src = alert.source.clone();
                        if let Some(pos) = self.muted_sources.iter().position(|s| s == &src) {
                            self.muted_sources.remove(pos);
                        } else {
                            self.muted_sources.push(src);
                        }
                    }
                }
                _ => {}
            }
            return;
        }

        match key {
            KeyCode::Char('q') | KeyCode::Esc if !self.config_editing => {
                // If search filter is active, Esc clears it first
                if !self.search_filter.is_empty() && key == KeyCode::Esc {
                    self.search_filter.clear();
                    self.search_buffer.clear();
                } else {
                    self.should_quit = true;
                }
            }
            KeyCode::Tab if !self.config_editing => {
                self.selected_tab = (self.selected_tab + 1) % self.tab_titles.len();
            }
            KeyCode::BackTab if !self.config_editing => {
                if self.selected_tab > 0 {
                    self.selected_tab -= 1;
                } else {
                    self.selected_tab = self.tab_titles.len() - 1;
                }
            }
            KeyCode::Right if !self.config_editing && !(self.selected_tab == 5 && self.config_focus == ConfigFocus::Fields) => {
                self.selected_tab = (self.selected_tab + 1) % self.tab_titles.len();
                if self.selected_tab == 5 { self.config_focus = ConfigFocus::Sidebar; }
            }
            KeyCode::Left if !self.config_editing && !(self.selected_tab == 5 && self.config_focus == ConfigFocus::Fields) => {
                if self.selected_tab > 0 {
                    self.selected_tab -= 1;
                } else {
                    self.selected_tab = self.tab_titles.len() - 1;
                }
                if self.selected_tab == 5 { self.config_focus = ConfigFocus::Sidebar; }
            }
            // Alert list tabs (0-3): scroll, select, search, pause
            KeyCode::Up if self.selected_tab <= 3 => {
                let state = &mut self.list_states[self.selected_tab];
                let i = state.selected().unwrap_or(0);
                state.select(Some(i.saturating_sub(1)));
            }
            KeyCode::Down if self.selected_tab <= 3 => {
                let state = &mut self.list_states[self.selected_tab];
                let i = state.selected().unwrap_or(0);
                state.select(Some(i + 1)); // ListState clamps to list len during render
            }
            KeyCode::Enter if self.selected_tab <= 3 => {
                // Open detail view for selected alert
                let tab = self.selected_tab;
                let selected_idx = self.list_states[tab].selected().unwrap_or(0);
                let source_filter: Option<&str> = match tab {
                    1 => Some("network"),
                    2 => Some("falco"),
                    3 => Some("samhain"),
                    _ => None,
                };
                let filtered: Vec<&Alert> = self.alert_store.alerts()
                    .iter()
                    .rev()
                    .filter(|a| {
                        if let Some(src) = source_filter {
                            if a.source != src { return false; }
                        }
                        if self.muted_sources.contains(&a.source) { return false; }
                        if !self.search_filter.is_empty() {
                            let h = a.to_string().to_lowercase();
                            if !h.contains(&self.search_filter.to_lowercase()) { return false; }
                        }
                        true
                    })
                    .collect();
                if let Some(alert) = filtered.get(selected_idx) {
                    self.detail_alert = Some((*alert).clone());
                }
            }
            KeyCode::Char('/') if self.selected_tab <= 3 => {
                self.search_active = true;
                self.search_buffer = self.search_filter.clone();
            }
            KeyCode::Char(' ') if self.selected_tab <= 3 => {
                self.paused = !self.paused;
            }
            // Config tab
            _ if self.selected_tab == 5 => self.handle_config_key(key, modifiers),
            _ => {}
        }
```

**Step 2: Update `run_tui` to respect pause flag**

In the alert drain loop in `run_tui`, change:

```rust
        // Drain alert channel
        if !app.paused {
            while let Ok(alert) = alert_rx.try_recv() {
                app.alert_store.push(alert);
            }
        }
```

When paused, alerts still accumulate in the channel buffer (capacity 1000) and will be drained when unpaused.

**Step 3: Commit**

```bash
git add src/tui.rs
git commit -m "feat(tui): keyboard handlers for scroll, detail, search, pause, mute"
```

---

### Task 9: Config field validation

**Files:**
- Modify: `src/tui.rs`

**Step 1: Add validation to the config edit confirm handler**

In `handle_config_key`, in the `KeyCode::Enter` arm when `self.config_editing` is true, replace the direct apply with validation:

```rust
                KeyCode::Enter => {
                    let field = &self.config_fields[self.config_selected_field];
                    let value = &self.config_edit_buffer;

                    // Validate based on field type
                    let valid = match &field.field_type {
                        FieldType::Number => value.parse::<u64>().is_ok(),
                        FieldType::Bool => value == "true" || value == "false",
                        FieldType::Text => true,
                        FieldType::Action(_) => true,
                    };

                    if valid {
                        if let Some(ref mut config) = self.config {
                            let section = &self.config_sections[self.config_selected_section];
                            let field = &self.config_fields[self.config_selected_field];
                            apply_field_to_config(config, section, &field.name, &self.config_edit_buffer);
                            self.refresh_fields();
                        }
                        self.config_editing = false;
                        self.config_edit_buffer.clear();
                    } else {
                        self.config_saved_message = Some(format!(
                            "❌ Invalid {}: \"{}\"",
                            match &field.field_type {
                                FieldType::Number => "number",
                                FieldType::Bool => "boolean (true/false)",
                                _ => "value",
                            },
                            value
                        ));
                    }
                }
```

**Step 2: Commit**

```bash
git add src/tui.rs
git commit -m "feat(tui): validate config field input before applying"
```

---

### Task 10: Add count_by_source helper to AlertStore

**Files:**
- Modify: `src/alerts.rs`

**Step 1: Add helper method**

```rust
    /// Count alerts matching a given source string.
    pub fn count_by_source(&self, source: &str) -> usize {
        self.alerts.iter().filter(|a| a.source == source).count()
    }
```

**Step 2: Commit**

```bash
git add src/alerts.rs
git commit -m "feat(alerts): add count_by_source helper"
```

---

### Task 11: Final cleanup and color theme adjustments

**Files:**
- Modify: `src/tui.rs`

**Step 1: Update system tab to use better colors**

In `render_system_tab`, change the info line from `Color::Gray` to `Color::Blue`:

```rust
        Line::from(vec![
            Span::styled(format!("  ℹ️  Info:     {}", info_count), Style::default().fg(Color::Blue)),
        ]),
```

Also add pause status and muted sources to the system tab:

After the key hint line, add:

```rust
        Line::from(""),
        Line::from(vec![
            Span::raw("Feed: "),
            if app.paused {
                Span::styled("⏸ PAUSED", Style::default().fg(Color::Yellow).bold())
            } else {
                Span::styled("▶ LIVE", Style::default().fg(Color::Green))
            },
        ]),
```

And if muted sources exist:

```rust
        if !app.muted_sources.is_empty() {
            text.push(Line::from(vec![
                Span::styled("Muted: ", Style::default().fg(Color::DarkGray)),
                Span::raw(app.muted_sources.join(", ")),
            ]));
        }
```

Note: `render_system_tab` needs `&App` changed to `&App` (it already is). But to show muted sources we need access — it already takes `&App`, so this works.

**Step 2: Commit**

```bash
git add src/tui.rs
git commit -m "feat(tui): color theme improvements and system tab enhancements"
```

---

### Task 12: Push and verify CI

**Step 1: Push the branch**

```bash
git push origin HEAD
```

**Step 2: Check CI status**

```bash
gh run list --limit 3
```

Wait for CI to pass. If there are compile errors, fix them iteratively.

---

## Summary of Changes

| Feature | Where | Lines (est.) |
|---|---|---|
| Scrollable lists (ListState) | tui.rs | ~30 |
| Alert detail view | tui.rs | ~60 |
| DRY filtered tabs | tui.rs | -120, +40 |
| Footer/status bar | tui.rs | ~30 |
| Tab counts | tui.rs | ~15 |
| Better colors | tui.rs | ~5 |
| Relative timestamps | tui.rs (in render_alert_list) | ~15 |
| Cached `which` | tui.rs | ~20 |
| Config validation | tui.rs | ~20 |
| Search/filter | tui.rs | ~30 |
| Zeroize password | tui.rs + Cargo.toml | ~10 |
| Pause/mute | tui.rs | ~15 |

Net: ~-100 lines (DRY saves offset additions). All 12 improvements in one cohesive pass.
