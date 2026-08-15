//! Parsing and validation for the trusted Easy Auth principal header.

use std::collections::HashSet;

use base64::{Engine as _, engine::general_purpose::STANDARD};
use http::HeaderMap;
use serde::Deserialize;
use thiserror::Error;

const PRINCIPAL_HEADER: &str = "x-ms-client-principal";
const PRINCIPAL_ID_HEADER: &str = "x-ms-client-principal-id";

#[derive(Debug, Deserialize)]
struct ClientPrincipal {
    #[serde(default)]
    claims: Vec<Claim>,
}

#[derive(Debug, Deserialize)]
struct Claim {
    typ: String,
    val: String,
}

/// Extract security-group object IDs from a header inserted by Container Apps Easy Auth.
///
/// The public ingress is configured to reject unauthenticated traffic before this code.
/// We still fail closed when the trusted header is absent, malformed, or signals group
/// overage; otherwise a token with omitted group claims could gain a default role.
pub fn security_groups(headers: &HeaderMap) -> Result<HashSet<String>, PrincipalError> {
    let principal_id = unique_header(headers, PRINCIPAL_ID_HEADER)?
        .to_str()
        .map_err(|_| PrincipalError::Malformed)?;
    if principal_id.trim().is_empty() {
        return Err(PrincipalError::MissingSubject);
    }
    let encoded = unique_header(headers, PRINCIPAL_HEADER)?
        .to_str()
        .map_err(|_| PrincipalError::Malformed)?;
    let decoded = STANDARD
        .decode(encoded)
        .map_err(|_| PrincipalError::Malformed)?;
    let principal: ClientPrincipal =
        serde_json::from_slice(&decoded).map_err(|_| PrincipalError::Malformed)?;

    if principal.claims.iter().any(is_group_overage_claim) {
        return Err(PrincipalError::GroupOverage);
    }

    let groups = principal
        .claims
        .into_iter()
        .filter(|claim| is_group_claim(&claim.typ))
        .map(|claim| claim.val)
        .collect::<HashSet<_>>();

    if groups.is_empty() {
        return Err(PrincipalError::NoGroups);
    }
    Ok(groups)
}

fn unique_header<'a>(
    headers: &'a HeaderMap,
    name: &str,
) -> Result<&'a http::HeaderValue, PrincipalError> {
    let mut values = headers.get_all(name).iter();
    let value = values.next().ok_or(PrincipalError::Missing)?;
    if values.next().is_some() {
        return Err(PrincipalError::Duplicate);
    }
    Ok(value)
}

fn is_group_claim(claim_type: &str) -> bool {
    claim_type.eq_ignore_ascii_case("groups") || claim_type.ends_with("/identity/claims/groups")
}

fn is_group_overage_claim(claim: &Claim) -> bool {
    (claim.typ.eq_ignore_ascii_case("hasgroups") && claim.val.eq_ignore_ascii_case("true"))
        || claim.typ == "_claim_names"
        || claim.typ == "_claim_sources"
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum PrincipalError {
    #[error("authenticated principal header is missing")]
    Missing,
    #[error("authenticated principal header is malformed")]
    Malformed,
    #[error("authenticated principal header is duplicated")]
    Duplicate,
    #[error("authenticated principal subject is missing")]
    MissingSubject,
    #[error("group overage is not supported; access is denied")]
    GroupOverage,
    #[error("the principal has no usable security-group claims")]
    NoGroups,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn headers(json: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(PRINCIPAL_HEADER, STANDARD.encode(json).parse().unwrap());
        headers.insert(PRINCIPAL_ID_HEADER, "subject-id".parse().unwrap());
        headers
    }

    #[test]
    fn reads_short_and_uri_group_claims() {
        let groups = security_groups(&headers(
            r#"{"claims":[{"typ":"groups","val":"one"},{"typ":"http://schemas.microsoft.com/ws/2008/06/identity/claims/groups","val":"two"}]}"#,
        ))
        .unwrap();
        assert_eq!(groups, HashSet::from(["one".to_owned(), "two".to_owned()]));
    }

    #[test]
    fn group_overage_fails_closed() {
        let error = security_groups(&headers(r#"{"claims":[{"typ":"hasgroups","val":"true"}]}"#))
            .unwrap_err();
        assert_eq!(error, PrincipalError::GroupOverage);
    }

    #[test]
    fn missing_principal_id_fails_closed() {
        let mut headers = headers(r#"{"claims":[{"typ":"groups","val":"one"}]}"#);
        headers.remove(PRINCIPAL_ID_HEADER);
        assert_eq!(security_groups(&headers), Err(PrincipalError::Missing));
    }
}
