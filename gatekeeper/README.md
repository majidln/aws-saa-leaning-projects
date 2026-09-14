# Gatekeeper

A multi-tenant API on AWS where Auth0 issues the tokens and a hand-written Lambda authorizer decides who gets in — a learning project for auth, JWT validation, and Auth0.

Not started yet. This README holds the agreed shape so the project can be picked back up; a full `PLANNING.md` and `STEP-N-GUIDE.md` files come when work begins.

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
| **Lambda code** | Node.js 20.x, TypeScript |
| **API** | REST API + Lambda **REQUEST** authorizer. HTTP API's built-in JWT authorizer would validate tokens for you — defeats the point |
| **JWT library** | `jose` (`createRemoteJWKSet` + `jwtVerify`) |
| **Multi-tenancy** | `tenant_id` custom claim + DynamoDB partition key `TENANT#<id>`. Auth0 Organizations rejected — paid plan only |
| **Custom claims** | Auth0 Action, namespaced (`https://gatekeeper/tenant_id`, `https://gatekeeper/roles`). Rules are deprecated |
| **Authorizer cache TTL** | 300s to start, revisited once revocation lag is measured |
| **Store** | DynamoDB, on-demand |

Rejected: AWS SAM, Cognito (the goal is Auth0), HTTP API native JWT authorizer, Auth0 Organizations.

---

## Prerequisites

- [ ] AWS account, non-root IAM identity, budget alarm
- [ ] Terraform CLI, AWS CLI, Node.js 20.x
- [ ] Free Auth0 tenant (Developer plan)
- [ ] Auth0 CLI (optional, useful from Step 4)

---

## Steps

1. **Auth0 tenant + a token by hand, no AWS.** Register an API and a Machine-to-Machine app, mint a token with `curl`, decode it, match its `kid` against the JWKS endpoint.
2. **API Gateway + one open Lambda.** `GET /hello`, no auth — prove the plumbing before adding something that rejects requests.
3. **Lambda authorizer, reject-only.** Verify signature, `iss`, `aud`, `exp`. Provoke each failure on purpose: tampered, expired, wrong audience.
4. **Custom claims.** Auth0 Action adds `tenant_id`/`roles`; the authorizer passes them to the backend via authorizer context.
5. **Tenant isolation.** DynamoDB keyed by the authorizer's `tenant_id`, never client input. Prove tenant A can't read tenant B's data.
6. **RBAC.** e.g. `DELETE` requires `admin`. Decide in writing whether the authorizer or the backend enforces it.
7. **Caching & revocation *(optional)*.** Revoke or expire a token and measure how long the cached authorizer decision still lets it through.

Nothing here bills at idle — no VPC, NAT, or provisioned capacity. Set CloudWatch log retention explicitly; the default never expires.
