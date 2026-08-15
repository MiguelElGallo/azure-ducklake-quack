//! Pure role-selection policy shared by the gateway and tests.

use std::{collections::HashSet, fmt, str::FromStr};

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// The primary role selected when a Quack connection is created.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Reader,
    Writer,
}

impl fmt::Display for Role {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Reader => "reader",
            Self::Writer => "writer",
        })
    }
}

impl FromStr for Role {
    type Err = PolicyError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value.trim().to_ascii_lowercase().as_str() {
            "reader" => Ok(Self::Reader),
            "writer" => Ok(Self::Writer),
            other => Err(PolicyError::UnknownRole(other.to_owned())),
        }
    }
}

/// Maps immutable Entra group object IDs to the roles this deployment exposes.
#[derive(Clone, Debug)]
pub struct RolePolicy {
    reader_group_id: String,
    writer_group_id: String,
}

impl RolePolicy {
    #[must_use]
    pub fn new(reader_group_id: impl Into<String>, writer_group_id: impl Into<String>) -> Self {
        Self {
            reader_group_id: reader_group_id.into(),
            writer_group_id: writer_group_id.into(),
        }
    }

    /// Resolve the requested primary role. An omitted role is deliberately reader.
    ///
    /// # Errors
    ///
    /// Returns [`PolicyError::RoleNotGranted`] when the required group is absent.
    pub fn resolve(
        &self,
        group_ids: &HashSet<String>,
        requested: Option<Role>,
    ) -> Result<Role, PolicyError> {
        let role = requested.unwrap_or(Role::Reader);
        let required_group = match role {
            Role::Reader => &self.reader_group_id,
            Role::Writer => &self.writer_group_id,
        };

        group_ids
            .contains(required_group)
            .then_some(role)
            .ok_or(PolicyError::RoleNotGranted(role))
    }
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum PolicyError {
    #[error("unknown role: {0}")]
    UnknownRole(String),
    #[error("the selected role is not granted: {0}")]
    RoleNotGranted(Role),
}

#[cfg(test)]
mod tests {
    use super::*;

    fn groups(values: &[&str]) -> HashSet<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    #[test]
    fn defaults_to_reader_when_reader_is_granted() {
        let policy = RolePolicy::new("reader-id", "writer-id");
        assert_eq!(
            policy.resolve(&groups(&["reader-id"]), None),
            Ok(Role::Reader)
        );
    }

    #[test]
    fn writer_requires_writer_group_even_when_reader_is_granted() {
        let policy = RolePolicy::new("reader-id", "writer-id");
        assert_eq!(
            policy.resolve(&groups(&["reader-id"]), Some(Role::Writer)),
            Err(PolicyError::RoleNotGranted(Role::Writer))
        );
    }

    #[test]
    fn explicit_writer_is_selected_when_granted() {
        let policy = RolePolicy::new("reader-id", "writer-id");
        assert_eq!(
            policy.resolve(&groups(&["writer-id"]), Some(Role::Writer)),
            Ok(Role::Writer)
        );
    }
}
