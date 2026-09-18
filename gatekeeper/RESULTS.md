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
