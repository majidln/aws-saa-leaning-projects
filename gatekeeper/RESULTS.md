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
