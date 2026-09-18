# Gatekeeper

A multi-tenant API on AWS where Auth0 issues the tokens and a hand-written Lambda authorizer decides who gets in — a learning project for auth, JWT validation, and Auth0.

Not started yet. The full roadmap is in [PLANNING.md](PLANNING.md); `STEP-N-GUIDE.md` files come as each step begins.

---

## Why

- Learn Auth0 hands-on — tenants, APIs, applications, Actions, custom claims.
- Learn JWT validation by writing it, not by letting a managed authorizer do it: JWKS signature check, `iss`/`aud`/`exp`, authorizer caching and its revocation trade-off.
- Learn tenant isolation and role-based access enforced at the API boundary.

Out of scope: frontend, CI/CD, production Auth0 hardening (MFA, custom domains), multi-region.

---

## Decisions

| | |
|---|---|
| **IaC** | Terraform |
| **Lambda code** | Go on `provided.al2023`, arm64 |
| **API** | REST API + Lambda **REQUEST** authorizer. HTTP API's built-in JWT authorizer would validate tokens for you — defeats the point |
| **JWT libraries** | `golang-jwt/jwt/v5` + `MicahParks/keyfunc/v3` (JWKS) |
| **Multi-tenancy** | `tenant_id` custom claim + DynamoDB partition key `TENANT#<id>`. Auth0 Organizations rejected — paid plan only |
| **Custom claims** | Auth0 Action, namespaced (`https://gatekeeper/tenant_id`). Rules are deprecated |
| **Authorization** | Auth0 API permissions in the `scope` claim (`read:items`, `write:items`, `delete:items`) |
| **Authorizer cache TTL** | 300s to start, revisited once revocation lag is measured |
| **Store** | DynamoDB, on-demand |

Rejected: AWS SAM, Cognito (the goal is Auth0), HTTP API native JWT authorizer, Auth0 Organizations.

---

## Prerequisites

- [ ] AWS account, non-root IAM identity, budget alarm
- [ ] Terraform CLI, AWS CLI, Go 1.22+
- [ ] Free Auth0 tenant (Developer plan)
- [ ] Auth0 CLI (optional, useful from Step 4)

---

## Steps

1. **Auth0 tenant + a token by hand, no AWS.** Register an API and a Machine-to-Machine app, mint a token with `curl`, decode it, match its `kid` against the JWKS endpoint.
2. **API Gateway + one open Lambda.** `GET /hello`, no auth — prove the plumbing before adding something that rejects requests.
3. **Lambda authorizer, reject-only.** Verify signature, `iss`, `aud`, `exp`. Provoke each failure on purpose: tampered, expired, wrong audience.
4. **Custom claims.** Auth0 Action adds `tenant_id`; the authorizer passes it and the token's `scope` to the backend via authorizer context.
5. **Tenant isolation.** DynamoDB keyed by the authorizer's `tenant_id`, never client input. Prove tenant A can't read tenant B's data.
6. **Scopes.** e.g. `DELETE` requires `delete:items`. Decide in writing whether the authorizer or the backend enforces it.
7. **Caching & revocation *(optional)*.** Revoke the signing key and measure how long old tokens still get through.

Nothing here bills at idle — no VPC, NAT, or provisioned capacity. Set CloudWatch log retention explicitly; the default never expires.
