# Gatekeeper

A multi-tenant API on AWS where Auth0 issues the tokens and a hand-written Lambda authorizer decides who gets in — a learning project for auth, JWT validation, and Auth0.

In progress. The full roadmap is in [PLANNING.md](PLANNING.md); `STEP-N-GUIDE.md` files come as each step begins, and findings go in [RESULTS.md](RESULTS.md).

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

## Tests

Unit tests need no AWS account, no Auth0 tenant, and no network: tokens are signed with an RSA key generated inside the test. Each function under `cmd/` is its own Go module, so run tests from that function's directory.

```bash
cd cmd/authorizer && go test ./...
```

```bash
cd cmd/items && go test ./...
```

`cmd/authorizer` covers token verification and the tenant claim; `cmd/items` covers reading the tenant from the authorizer context and ignoring anything the client says about tenancy.

Useful variants, shown for `cmd/authorizer` (they work the same in `cmd/items`):

```bash
go test -v ./...                        # every case, by name
go test -race -count=1 ./...            # race detector, bypass the test cache
go test -cover ./...                    # coverage
go test -run TestVerifyToken -v ./...   # one test
go test -run 'TestVerifyToken/expired' -v ./...   # one case inside a test
```

Not covered by unit tests: `main()` (reads `AUTH0_DOMAIN`/`AUTH0_AUDIENCE` and fetches the JWKS), which is exercised against the deployed API.

---

## Calling the API

Two steps: get a token from Auth0 for one of the tenant apps, then send it in an `Authorization: Bearer <token>` header. Which app the token came from decides which tenant the API sees. A token lasts 24 hours, and every one counts against Auth0's monthly quota, so reuse it.

- `GET /hello` returns a greeting for any valid token.
- `GET /items` returns the caller's `tenant_id` and `sub`.
- No `Authorization` header or a non-Bearer scheme gives 401. A token that's present but invalid (tampered, expired, wrong audience, no tenant) gives 403.

The requests live in [`bruno/`](bruno/) as a [Bruno](https://www.usebruno.com) collection: plain text files, committed with the code, with no account needed.

```
bruno/
├── api/           both token requests, then /hello and /items for each tenant
├── negative/      no header, garbage token, wrong scheme, tampered signature, spoofed X-Tenant-Id
└── environments/  dev.bru: API URL, Auth0 domain, client IDs
```

**Setup**

```bash
brew install --cask bruno
```

The two client secrets go in `bruno/.env`, which is gitignored. Each of these reads a secret straight out of Auth0 into the file, so it never appears on screen. Without this file the token requests fail with 401, because Bruno sends an empty secret.

```bash
cd bruno && : > .env
```

```bash
echo "TENANT_A_CLIENT_SECRET=$(auth0 apps show FmRUmDphBsUAzRE3VScUyxtzArFCDEyb --reveal-secrets --json --no-input | jq -r .client_secret)" >> .env
```

```bash
echo "TENANT_B_CLIENT_SECRET=$(auth0 apps show lAh3UGttUGzmyrnWjblBh1iCCGRp5a79 --reveal-secrets --json --no-input | jq -r .client_secret)" >> .env
```

Check both lines are set, without printing the values:

```bash
awk -F= '{print $1": "(length($0)>length($1)+1 ? "set" : "EMPTY")}' .env
```

Then in Bruno: **Open Collection**, choose the `bruno/` folder, select the `dev` environment, and send `Get tenant-a token` and `Get tenant-b token` first. The other requests reuse those tokens. The folders run in order, `api` then `negative`.

**From the command line**

```bash
cd bruno && npx @usebruno/cli run --env dev -r
```

It reads the same `.env`. Expect 10 requests passing.

`environments/dev.bru` has the API URL hardcoded, and its ID changes if the stack is destroyed and re-applied. Get the current one with `terraform output -raw invoke_url` from `infra/`.

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
