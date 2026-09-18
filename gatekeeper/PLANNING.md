# Gatekeeper — Execution Roadmap

A multi-tenant API on API Gateway + Lambda, where Auth0 issues the tokens and a hand-written Lambda authorizer decides who gets in. Built in steps where each one responds to a problem the previous step left behind.

One codebase, one stack that evolves. `git tag step-N-complete` at the end of each step — the diff between tags is the record of what changed.

Findings recorded in [RESULTS.md](RESULTS.md) every step — here that means rejection cases provoked and time windows measured, not latency percentiles.

Out of scope: frontend and interactive user login, CI/CD, production Auth0 hardening (MFA, custom domains, attack protection), multi-region.

---

## 1. Prerequisites

- [ ] AWS account, non-root IAM identity, budget alarm.
- [ ] AWS CLI + **Terraform** installed (record the versions).
- [ ] **Go 1.22+**.
- [ ] **A free Auth0 tenant** (Developer plan). Takes a few minutes, but Step 1 can't start without it.
- [ ] Auth0 CLI — optional, useful from Step 4.
- [ ] `jq`, and a way to decode a JWT locally (`jq` alone does it: split on `.`, base64-decode). Avoid pasting real tokens into websites.

**Secrets rule from day one:** the M2M client secret never goes in the repo, a `.tfvars` file, or shell history you'd share. Environment variables only. Terraform itself needs nothing secret until Step 4, and only then if the Auth0 provider is used.

---

## 2. Decisions

| | |
|---|---|
| **Tooling** | Terraform for all AWS resources. Auth0 configuration by hand in Steps 1–3; Terraform's `auth0` provider tried from Step 4 (see §5) |
| **Runtime** | Go on `provided.al2023`, arm64, binary named `bootstrap` — same contract as url-shortener |
| **Build** | `Makefile` builds each function (`GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -tags lambda.norpc -o bootstrap`); Terraform's `archive_file` zips it. Terraform doesn't compile Go |
| **API** | **REST API + Lambda `REQUEST` authorizer.** HTTP API's built-in JWT authorizer would validate the token for you — that's the thing this project exists to write. REST costs $3.50/M vs $1/M; irrelevant at lab volume |
| **JWT libraries** | `github.com/golang-jwt/jwt/v5` for parsing and claim validation, `github.com/MicahParks/keyfunc/v3` for JWKS fetch/cache/refresh. Two libraries on purpose: the seam between them is where the JWKS mechanics are visible. `lestrrat-go/jwx` rejected — does both in one, hides the seam |
| **Callers** | Machine-to-Machine applications with the `client_credentials` grant. One M2M app per simulated tenant. Stand-in for real users; no browser, no login page |
| **Tenancy** | `tenant_id` stored in each M2M app's metadata, copied into the access token as a namespaced custom claim by an Auth0 Action. DynamoDB partition key `TENANT#<tenant_id>`. Auth0 Organizations rejected — paid plans only |
| **Authorization** | Auth0's native API **permissions**, arriving in the `scope` claim: `read:items`, `write:items`, `delete:items`, granted per M2M app. No hand-rolled roles claim — scopes are what Auth0 already gives you |
| **Store** | DynamoDB, on-demand. Nothing at rest |
| **Authorizer cache** | 300s to start. Step 7 measures what it costs in revocation lag and revisits it |
| **Layout** | Like url-shortener: each Lambda is its own Go module under `cmd/` (`cmd/authorizer`, `cmd/hello`, `cmd/items`). Terraform in one evolving root under `infra/`. Auth0 Action source (JavaScript — Actions only run Node) under `auth0/actions/` |

**One Terraform root, not a directory per step.** Trailmark gives each chapter its own directory because its chapters are different architectures. These steps are one system gaining capability, and copying the authorizer wiring into seven directories would multiply the one thing that must stay correct.

Rejected overall: AWS SAM (url-shortener already covers it; this one is for Terraform), Cognito (the goal is Auth0), HTTP API native JWT authorizer, Auth0 Organizations, Auth0 Rules (deprecated in favour of Actions).

---

## 3. Steps

### Step 1 — See a token before validating one
Writing a validator against something never looked at means debugging `iss`/`aud`/`kid` mismatches blind.

Auth0 tenant, one API (its **identifier** becomes the `aud` claim), one M2M application authorized for it. Mint a token with `curl` against `/oauth/token`, decode header and payload by hand, fetch `/.well-known/jwks.json` and find the key whose `kid` matches the token's. See [STEP-1-GUIDE.md](STEP-1-GUIDE.md).

**Exit:** a real token in the terminal, and for each of `alg`, `kid`, `iss`, `aud`, `exp`, `sub`, `scope` — what it's for and where in the Auth0 dashboard its value came from. `kid` matched to a JWKS key by hand. `sub` explained: why it ends in `@clients` for an M2M token.

*Free. No AWS yet.*

### Step 2 — Plumbing before a lock
There's a token and nowhere to send it. An authorizer rejects things, and rejections are hard to debug on infra not yet trusted.

Terraform: REST API, `GET /hello`, `cmd/hello` behind it, no auth at all. Makefile build, `archive_file`, a log group declared with retention (not left for Lambda to create with never-expire). See [STEP-2-GUIDE.md](STEP-2-GUIDE.md).

**Exit:** `curl` gets 200 with no `Authorization` header. `terraform destroy` and `apply` once, cleanly. A code change redeploys the function on the next `apply` — if it doesn't, `source_code_hash` isn't wired.

*Free tier. Leave it running.*

### Step 3 — The door is open
`/hello` answers anyone. This is the heart of the project: code that decides whether a token is a genuine, unexpired Auth0 token meant for this API — without yet caring who sent it.

`cmd/authorizer`: read `Authorization: Bearer …`, verify signature against the JWKS, check `iss`, `aud`, `exp`, and pin the algorithm to `RS256` (`jwt.WithValidMethods`). Allow or deny. No claims forwarded yet.

Three traps:
- **401 vs 403.** Returning the error `Unauthorized` makes API Gateway send 401; returning a `Deny` policy sends 403. Decide which failures mean which.
- **Cached policies are reused across routes.** With caching on, the policy returned for the first route is cached and applied to the next route that caller hits. A policy naming only `GET/hello` breaks `POST /items` in Step 5 with a baffling 403. Scope the resource to the API, not the method.
- **Algorithm confusion.** Without pinning, a token signed with `HS256` using the *public key* as the HMAC secret can pass a naive verifier. Pinning is one line; understand why it's there.

**Exit:** a valid token gets 200. Each of these is provoked on purpose and rejected: missing header, tampered signature, expired token, wrong `aud` (register a second API in Auth0 and mint against it), an `HS256` token. Each case and its status code in RESULTS.md. Unit tests for the authorizer use locally generated RSA keys — no Auth0 or network in tests.

*Free tier.*

### Step 4 — The backend knows *that*, not *who*
The authorizer knows a token is valid; the backend has no idea which tenant is calling.

Auth0 Action on the **Machine to Machine** trigger (`credentials-exchange` — `post-login` never fires for `client_credentials`) copies `tenant_id` from the app's metadata into a namespaced claim, `https://gatekeeper/tenant_id`. Auth0 silently drops custom claims that aren't namespaced. Second M2M app for a second tenant.

Authorizer returns `tenant_id`, `sub`, and `scope` in the authorizer **context**; the backend reads them from `requestContext.authorizer`. Context values must be strings, numbers, or booleans — no arrays or objects.

**Exit:** tokens from both apps carry different `tenant_id`s. `cmd/items` logs the tenant it got from the authorizer context and never parses the JWT itself — check the code: no JWT import in `cmd/items`.

*Free.*

### Step 5 — Nothing stops tenant A reading tenant B
`tenant_id` is *available* to the backend, not *enforced*.

DynamoDB table, `PK = TENANT#<tenant_id>`, `SK = ITEM#<id>`. `GET /items`, `GET /items/{id}`, `POST /items`. The partition key comes from the authorizer context, **never** from the path, query string, or body.

**Exit:** items created as both tenants. Tenant A tries tenant B's item IDs directly and gets 404, not B's data — attempted, not assumed. A deliberately added `?tenant=` parameter does nothing.

*DynamoDB on-demand — nothing billed at rest. Leave it running.*

### Step 6 — Every caller can do everything
Every token from a tenant has the same power. Real APIs don't let every client delete.

Define `read:items`, `write:items`, `delete:items` on the Auth0 API; grant them per M2M app. Add `DELETE /items/{id}` requiring `delete:items`.

**The fork to resolve in writing:** enforce scopes in the authorizer (central, but it must know every route's requirement) or in the backend (the authorizer stays generic, each handler checks). Pick one, say why, keep the other documented.

**Exit:** a client without `delete:items` gets 403 on `DELETE` and 200 on reads; a client with it succeeds. Removing a scope in Auth0 takes effect only on the next token — note when.

*No new cost.*

### Step 7 — How long does "revoked" take? *(optional)*
An access token is valid until it expires; Auth0 can't recall one. The only emergency brake is revoking the signing key — and between Auth0 and a rejection sit two caches: API Gateway's authorizer cache and the JWKS cached in a warm Lambda.

Rotate, then revoke, the tenant's signing key. Hit the API with an old token throughout and log each authorizer decision separately from backend invocations, so a cache hit shows up as a missing authorizer log line.

**Exit:** the measured window during which a revoked-key token still gets through, split into its two causes. Authorizer TTL and access-token lifetime re-decided from the numbers, not the guess in §2.

*No new resource types. If never built, the project is complete at Step 6.*

---

## 4. Session discipline

Deploy → verify the exit criteria by hand → record in [RESULTS.md](RESULTS.md) → `git tag step-N-complete` → leave it running.

| Stack | Rule |
|---|---|
| Everything in `infra/` | Leave running — no VPC, NAT, or provisioned capacity; nothing bills at idle |
| Auth0 tenant | Leave configured — free, and re-creating it changes the issuer and JWKS |

The Auth0 free plan caps M2M tokens per month. Reuse a token until it expires (24h by default) instead of minting one per request; minting inside a loop is the fastest way to hit the cap.

---

## 5. Still open

| Question | Recommendation |
|---|---|
| Auth0 config as code (Step 4) | Try the `auth0` Terraform provider for the API, apps, and Action. Needs its own M2M app with Management API access — another secret for env vars. Fall back to dashboard + CLI if it fights, and write down why |
| Terraform state | Reuse trailmark's `state-backend` bucket with a `gatekeeper/` key, rather than local state |
| Region | Any — nothing here needs `us-east-1` |
| Real users (post-Step 7) | Out of scope. If picked up: an interactive login with the `post-login` trigger, which is the tenant model most SaaS actually uses |

*Costs are approximate list prices, and Auth0 plan limits change. Confirm before relying on them.*
