# Gatekeeper — Results

No tokens or secrets in this file.

---

## Step 1 — See a token before validating one

Tenant `<fill in: domain>`, API `Gatekeeper API` (`https://gatekeeper/api`, RS256), M2M app `tenant-a`, no permissions.

| Claim | Value | Source |
|---|---|---|
| `alg` / `kid` | `RS256` / `<fill in>` | API setting / tenant's current signing key |
| `iss` | `https://<domain>/` | Tenant — **trailing slash** |
| `aud` | `https://gatekeeper/api` | `audience` in the request |
| `sub` / `azp` | `<client_id>@clients` / `<client_id>` | The M2M client |
| `gty` | `client-credentials` | Grant type |
| `exp − iat` | `<fill in>`s | API's Token Expiration (default 24h) |
| `scope` | absent | No permissions granted yet |

JWKS: `<fill in>` RSA key(s); the token's `kid` matched one. Extra keys are published ahead of rotation.

### Checkpoints

- **Tampered payload** still decodes — only the signature check catches it.
- **Wrong audience** — Auth0 refuses to issue one. A wrong-`aud` test token has to come from a second API that `tenant-a` is authorized for.
- **`alg` is attacker-controlled** — trusting it allows `none` or `HS256`-with-public-key forgeries. Fix the algorithm to `RS256`.
- **Leaked token** — can't be revoked; valid until `exp`. Only revoking the signing key stops it.
- **Second token** — same `kid` and identity claims, new `iat`/`exp`/signature.
- **New tenant, same identifier** — old tokens fail: different `iss` and different keys.

---

## Step 3 — The door is open

`cmd/authorizer` (REQUEST type) on `GET /hello`: header → signature (JWKS, RS256 pinned) → `iss`, `aud`, `exp` → Allow. Cache TTL 300s.

| Request | Status | Authorizer log |
|---|---|---|
| Valid `tenant-a` token | 200 | `allow`, `sub` = `<tenant-a client id>@clients` |
| No `Authorization` header | 401 | not invoked — `identity_source` is required |
| Wrong scheme or no token | 401 | `missing or malformed Authorization header` |
| Tampered signature | 403 | `token signature is invalid: crypto/rsa: verification error` |
| `HS256` token | 403 | `signing method HS256 is invalid` |
| Token for `https://other/api` | 403 | `token has invalid claims: token has invalid audience` |
| Expired token | — | unit test only; a self-signed token fails the signature check first |

**401 vs 403:** no or malformed header → error `Unauthorized` (401, "you didn't authenticate"). A token was presented but is wrong → Deny policy (403). Everything not the caller's fault → plain error (500).

**Cache (300s):** 6 requests, 3 authorizer invocations. The same token repeated is served from cache; a **deny is cached too**; a new token is a new cache entry.

### Findings

- **Empty `AUTH0_DOMAIN`** (from an unset `TF_VAR`) → authorizer exits at init → API Gateway 500 `AuthorizerConfigurationException`. Fails closed.
- **Grants are per app.** The shell used the auto-created Test Application's credentials, not `tenant-a`'s, so `tenant-a`'s grant for `Other API` never applied.
- **The RS256 pin is a second layer here:** `golang-jwt` refuses HS256 with an RSA key anyway. Only `TestAlgorithmPinBlocksKeyConfusion` guards it, using a naive key lookup.
- **Unit tests:** 71 cases, 71.4% coverage. Removing the pin, `aud`, `iss`, required `exp`, the wildcard resource, or adding the token to a log line each fails at least one test.

---

## Step 4 — The backend knows *that*, not *who*

App metadata → Action (`credentials-exchange`) → namespaced claim → authorizer context → `cmd/items`. Auth0 config as code via the `auth0` Terraform provider.

| Request to `GET /items` | Status | Body |
|---|---|---|
| `tenant-a` token | 200 | `tenant_id: tenant-a` |
| `tenant-b` token | 200 | `tenant_id: tenant-b` |
| `tenant-a` token + `X-Tenant-Id: tenant-b` | 200 | still `tenant-a` |
| `tenant-a` token + `?tenant=tenant-b` | 200 | still `tenant-a` |
| No token / garbage token | 401 / 403 | authorizer, unchanged from Step 3 |

`/hello` still works on the same authorizer — the Step 3 wildcard policy resource covers both routes.

### Findings

- **An Action's `deny` is tenant-wide, and it locked Terraform out.** The `credentials-exchange` trigger fires for *every* M2M token in the Auth0 tenant, including the Management API token the Terraform provider needs. Denying tokens with no `tenant_id` therefore denied `terraform-gatekeeper` itself: `terraform plan` failed with `invalid_request "application terraform-gatekeeper has no tenant_id metadata"`, and Terraform could no longer reach the Action it had created. Fixed by scoping the Action on `event.resource_server.identifier` and returning early for any other audience; repaired via the Auth0 CLI, which authenticates as the logged-in user rather than that app. **An Action that refuses tokens must scope itself to the audience it knows about.**
- **Terraform did all three Action states in one apply** — resource (draft), `deploy = true` (deployed), `auth0_trigger_action` (attached). Settles the §5 open decision: the provider was used, no dashboard fallback needed. Cost: a second M2M app (`terraform-gatekeeper`, four `*:actions` scopes only) and its secret in `terraform.tfvars` (gitignored) and in state.
- **Trust rests on the Lambda permission.** `cmd/items` has no JWT library and believes `requestContext.authorizer` because API Gateway is the only principal allowed to invoke it. Widen that permission and the assumption breaks.
- **Missing tenant = 500, not 403.** In the backend an absent context means the route lost its authorizer or something invoked the function directly — our misconfiguration, not a bad caller. Never default the tenant.
- **Changing the valid-token baseline was the right call.** Adding the tenant claim to the authorizer's `validClaims()` fixed three Step 3 tests that broke once a tenantless token became a denial; a real token from the tenant always carries the claim now.
- **Unit tests:** authorizer 82 cases, `items` 16 cases (86.7% coverage). Mutations caught: dropping the tenant guard (9 cases), dropping the trim (1), dropping the context, returning 200 instead of 500, trusting `X-Tenant-Id`, logging the whole header map.
- **Blind spot:** the claim name is a shared constant between `main.go` and the tests, so renaming it breaks nothing. Only decoding a real token proves the name is right.
