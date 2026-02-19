// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2025-2026 JR Morton

//! Unified approval system core types.
//!
//! Defines the data model for approval requests that flow between clawsudo,
//! the response engine, notification channels (Slack, TUI, API), and the
//! approval orchestrator.

use std::fmt;
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub mod store;

use crate::core::alerts::Severity;

/// Where an approval request originated from.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ApprovalSource {
    /// Request came from clawsudo policy evaluation.
    ClawSudo {
        /// The policy rule name that triggered the approval, if known.
        policy_rule: Option<String>,
    },
    /// Request came from the automated response engine.
    ResponseEngine {
        /// The threat ID that triggered the response action.
        threat_id: String,
        /// The playbook being executed, if any.
        playbook: Option<String>,
    },
}

impl fmt::Display for ApprovalSource {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ApprovalSource::ClawSudo { policy_rule: Some(rule) } => write!(f, "clawsudo (rule: {})", rule),
            ApprovalSource::ClawSudo { policy_rule: None } => write!(f, "clawsudo"),
            ApprovalSource::ResponseEngine { threat_id, playbook: Some(pb) } => write!(f, "response-engine (threat: {}, playbook: {})", threat_id, pb),
            ApprovalSource::ResponseEngine { threat_id, playbook: None } => write!(f, "response-engine (threat: {})", threat_id),
        }
    }
}

/// The outcome of an approval decision.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ApprovalResolution {
    /// The request was approved.
    Approved {
        /// Who approved (e.g., "admin", "jr", Slack user ID).
        by: String,
        /// Channel used to approve (e.g., "slack", "tui", "api").
        via: String,
        /// Optional message from the approver.
        message: Option<String>,
        /// When the approval was granted.
        at: DateTime<Utc>,
    },
    /// The request was denied.
    Denied {
        /// Who denied (e.g., "admin", Slack user ID).
        by: String,
        /// Channel used to deny (e.g., "slack", "tui", "api").
        via: String,
        /// Optional reason for denial.
        message: Option<String>,
        /// When the denial was issued.
        at: DateTime<Utc>,
    },
    /// The request expired before anyone responded.
    TimedOut {
        /// When the timeout occurred.
        at: DateTime<Utc>,
    },
}

impl fmt::Display for ApprovalResolution {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ApprovalResolution::Approved { by, via, .. } => {
                write!(f, "Approved by {} via {}", by, via)
            }
            ApprovalResolution::Denied { by, via, .. } => {
                write!(f, "Denied by {} via {}", by, via)
            }
            ApprovalResolution::TimedOut { .. } => write!(f, "Timed out"),
        }
    }
}

impl fmt::Display for ApprovalStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ApprovalStatus::Pending => write!(f, "Pending"),
            ApprovalStatus::Resolved(r) => write!(f, "{}", r),
        }
    }
}

/// Current status of an approval request.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ApprovalStatus {
    /// Awaiting a decision.
    Pending,
    /// A decision has been made.
    Resolved(ApprovalResolution),
}

/// A request for human approval before executing a privileged action.
///
/// Created by clawsudo or the response engine, routed through the approval
/// orchestrator to one or more notification channels, and resolved when a
/// human responds or the timeout expires.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApprovalRequest {
    /// Unique identifier (UUID v4).
    pub id: String,
    /// Where this request originated.
    pub source: ApprovalSource,
    /// The command or action requiring approval.
    pub command: String,
    /// The agent requesting the action.
    pub agent: String,
    /// How serious this action is.
    pub severity: Severity,
    /// Additional context about why this action is being requested.
    pub context: String,
    /// When the request was created.
    pub created_at: DateTime<Utc>,
    /// How long to wait for a response before timing out.
    #[serde(with = "duration_serde")]
    pub timeout: Duration,
}

impl ApprovalRequest {
    /// Create a new approval request with a generated UUID and current timestamp.
    pub fn new(
        source: ApprovalSource,
        command: String,
        agent: String,
        severity: Severity,
        context: String,
        timeout: Duration,
    ) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            source,
            command,
            agent,
            severity,
            context,
            created_at: Utc::now(),
            timeout,
        }
    }

    /// Returns `true` if this request has exceeded its timeout duration.
    pub fn is_expired(&self) -> bool {
        let deadline = self.created_at + chrono::Duration::from_std(self.timeout)
            .unwrap_or_else(|_| chrono::Duration::zero());
        Utc::now() > deadline
    }
}

/// Serde helper for `std::time::Duration` serialized as whole seconds (u64).
mod duration_serde {
    use serde::{Deserialize, Deserializer, Serialize, Serializer};
    use std::time::Duration;

    pub fn serialize<S: Serializer>(duration: &Duration, serializer: S) -> Result<S::Ok, S::Error> {
        duration.as_secs().serialize(serializer)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Duration, D::Error> {
        let secs = u64::deserialize(deserializer)?;
        Ok(Duration::from_secs(secs))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_approval_request_creation() {
        let req = ApprovalRequest::new(
            ApprovalSource::ClawSudo { policy_rule: Some("allow-apt".to_string()) },
            "apt install curl".to_string(),
            "openclaw".to_string(),
            Severity::Warning,
            "Package installation request".to_string(),
            Duration::from_secs(300),
        );

        assert!(!req.id.is_empty());
        // UUID v4 format: 8-4-4-4-12 hex chars
        assert_eq!(req.id.len(), 36);
        assert!(matches!(req.source, ApprovalSource::ClawSudo { .. }));
        assert_eq!(req.command, "apt install curl");
        assert_eq!(req.agent, "openclaw");
        assert_eq!(req.severity, Severity::Warning);
        // Timestamp should be very recent (within last 5 seconds)
        let age = Utc::now() - req.created_at;
        assert!(age.num_seconds() < 5);
    }

    #[test]
    fn test_approval_resolution_display() {
        let approved = ApprovalResolution::Approved {
            by: "admin".to_string(),
            via: "slack".to_string(),
            message: None,
            at: Utc::now(),
        };
        assert_eq!(format!("{}", approved), "Approved by admin via slack");

        let denied = ApprovalResolution::Denied {
            by: "jr".to_string(),
            via: "tui".to_string(),
            message: Some("too risky".to_string()),
            at: Utc::now(),
        };
        assert_eq!(format!("{}", denied), "Denied by jr via tui");

        let timed_out = ApprovalResolution::TimedOut { at: Utc::now() };
        assert_eq!(format!("{}", timed_out), "Timed out");
    }

    #[test]
    fn test_approval_source_serialization() {
        let source = ApprovalSource::ClawSudo {
            policy_rule: Some("allow-apt".to_string()),
        };
        let json = serde_json::to_string(&source).expect("serialize");
        let deserialized: ApprovalSource = serde_json::from_str(&json).expect("deserialize");

        match deserialized {
            ApprovalSource::ClawSudo { policy_rule } => {
                assert_eq!(policy_rule, Some("allow-apt".to_string()));
            }
            _ => panic!("expected ClawSudo variant"),
        }
    }

    #[test]
    fn test_is_expired() {
        let req = ApprovalRequest::new(
            ApprovalSource::ResponseEngine {
                threat_id: "THR-001".to_string(),
                playbook: None,
            },
            "kill -9 1234".to_string(),
            "openclaw".to_string(),
            Severity::Critical,
            "Suspicious process detected".to_string(),
            Duration::from_millis(0),
        );

        assert!(req.is_expired());
    }
}
