# GitHub Repository Setup Guide

Run these commands after the repo is created on GitHub.

## 1. Description and Topics

```bash
gh repo edit ClawTower/ClawTower \
  --description "OS-level runtime security for AI agents — tamper-proof monitoring, behavioral detection, and audit trails. Any agent, any framework." \
  --add-topic ai-security \
  --add-topic ai-agent \
  --add-topic rust \
  --add-topic linux \
  --add-topic runtime-security \
  --add-topic intrusion-detection \
  --add-topic agent-monitoring \
  --add-topic auditd
```

## 2. Enable Discussions

```bash
gh repo edit ClawTower/ClawTower --enable-discussions
```

## 3. Create Project Labels

These labels supplement the GitHub defaults (bug, enhancement, documentation, etc.).

```bash
# Project-specific labels
gh label create "detection-rule" --description "New or improved detection pattern" --color "D93F0B"
gh label create "scanner" --description "New or improved security scanner" --color "FBCA04"
gh label create "integration" --description "Agent framework or tool integration" --color "0E8A16"
gh label create "clawsudo" --description "Sudo gatekeeper (clawsudo) related" --color "5319E7"
gh label create "sentinel" --description "File integrity / sentinel related" --color "006B75"
gh label create "tui" --description "Terminal dashboard UI" --color "1D76DB"
gh label create "policy" --description "YAML policy engine" --color "BFD4F2"
gh label create "network" --description "Network monitoring / netpolicy" --color "C2E0C6"
gh label create "config" --description "Configuration system" --color "D4C5F9"
gh label create "performance" --description "Performance improvement" --color "BFDADC"
gh label create "breaking-change" --description "Introduces a breaking change" --color "B60205"
gh label create "needs-triage" --description "Awaiting maintainer review" --color "EDEDED"
gh label create "security" --description "Security hardening or vulnerability" --color "B60205"
gh label create "installer" --description "Setup scripts and installation" --color "C5DEF5"
```

## 4. Create Discussion Categories

GitHub creates General, Ideas, Polls, Q&A, and Show and Tell by default.
Add a security-specific category:

```bash
# Get the discussions category repository ID first
REPO_ID=$(gh api graphql -f query='{ repository(owner:"ClawTower", name:"ClawTower") { id } }' -q '.data.repository.id')

# Create Security Research category
gh api graphql -f query="
mutation {
  createDiscussionCategory(input: {
    repositoryId: \"$REPO_ID\",
    name: \"Security Research\",
    description: \"Detection techniques, threat research, and adversarial testing\",
    emoji: \":shield:\",
    isAnswerable: false
  }) {
    discussionCategory { id }
  }
}"
```

## 5. Create Welcome Discussion

```bash
# Get the General category ID
CATEGORY_ID=$(gh api graphql -f query='
{
  repository(owner:"ClawTower", name:"ClawTower") {
    discussionCategories(first:10) {
      nodes { id name }
    }
  }
}' -q '.data.repository.discussionCategories.nodes[] | select(.name=="General") | .id')

# Create the welcome post
gh api graphql -f query="
mutation {
  createDiscussion(input: {
    repositoryId: \"$REPO_ID\",
    categoryId: \"$CATEGORY_ID\",
    title: \"Welcome to ClawTower\",
    body: \"$(cat <<'BODY'
## Welcome

ClawTower is the first OS-level security watchdog purpose-built for AI agents. If you're here, you probably care about what happens when autonomous agents get shell access on real infrastructure. Good — so do we.

## What is this project?

ClawTower monitors at the kernel level (auditd, inotify, eBPF) and is designed so the AI agent being watched **cannot turn it off**. It detects threats (data exfiltration, privilege escalation, persistence, recon), maintains a tamper-evident audit trail, and alerts humans in real-time.

It works with any agent — OpenClaw, Claude Code, LangChain, custom agents — anything running under a Linux user account.

## How to get involved

- **Try it out** — install, point it at a test agent, see what it catches. File bugs.
- **Add detection rules** — if you know an attack technique ClawTower should catch, open a Detection Rule issue.
- **Write integration guides** — got ClawTower working with your agent framework? Share the setup.
- **Review the architecture** — read the docs, poke at the design, question our assumptions.

Issues labeled [`good first issue`](https://github.com/ClawTower/ClawTower/labels/good%20first%20issue) are real, scoped, and completable in a few hours.

## Links

- [README](https://github.com/ClawTower/ClawTower#readme)
- [Contributing Guide](https://github.com/ClawTower/ClawTower/blob/main/CONTRIBUTING.md)
- [Architecture Docs](https://github.com/ClawTower/ClawTower/blob/main/.docs/ARCHITECTURE.md)
- [Security Policy](https://github.com/ClawTower/ClawTower/blob/main/SECURITY.md)
BODY
)\"
  }) {
    discussion { url }
  }
}"
```

## 6. Pin the Welcome Discussion

After creating, pin it from the GitHub UI (Discussions → Welcome → Pin discussion).

## 7. Repository Settings (manual)

These must be done in the GitHub UI:

- **Social preview image**: Upload in Settings → General → Social preview
- **Default branch protection**: Settings → Branches → Add rule for `main`:
  - Require PR reviews (1 reviewer)
  - Require status checks (CI)
  - Do not allow force pushes
- **Discussions**: Pin the welcome post
- **Security advisories**: Enable private vulnerability reporting in Settings → Security
