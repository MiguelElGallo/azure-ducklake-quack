# Security policy

## Supported versions

Only the latest tagged preview is supported. Quack itself is experimental until
DuckDB 2.0, so deployments should be treated as development environments.

## Reporting

Please report suspected vulnerabilities privately through GitHub Security
Advisories for this repository. Do not include access tokens, connection
strings, tenant identifiers, or live endpoint details in a public issue.

## Deployment assumptions

- Container Apps Easy Auth is enabled on the only external ingress.
- Internal reader and writer apps are not directly internet-accessible.
- Key Vault and Storage use managed identities and Azure RBAC.
- Reader and writer Quack tokens are independent, rotatable defense-in-depth
  credentials; Entra remains the per-request authentication boundary.
- A group-overage token is denied instead of falling back to a role.

