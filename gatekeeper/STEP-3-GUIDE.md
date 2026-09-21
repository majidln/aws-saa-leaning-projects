# Step 3 Guide — The Door Is Open

A coaching guide, not a code drop. It names what to build and why, and what to provoke on purpose; you write the Go and the HCL.

**Goal (from [PLANNING.md](PLANNING.md)):** a Lambda `REQUEST` authorizer that decides whether a token is a genuine, unexpired Auth0 token meant for this API. Not who sent it — that's Step 4. Just: is this real.

---

## 1. What API Gateway hands the authorizer

A `REQUEST` authorizer receives the whole request, not just a token: headers, method ARN, query string. You only need `event.Headers["Authorization"]`, but knowing the rest is there matters for §5's caching trap.

It must return a policy document — `Allow` or `Deny` on a specific method ARN — or throw an error. Those are two different failure paths with two different HTTP results; see §3.

---

## 2. Verifying, in order

Four checks, and the order matters — a cheap check first saves a network call for something that was never going to pass:

1. **Header present and shaped `Bearer <token>`.** No token, no verification attempted.
2. **Signature**, via the JWKS. `keyfunc` fetches `https://<domain>/.well-known/jwks.json`, caches it, and hands `golang-jwt/jwt` a `Keyfunc` that resolves `kid` → public key. Build the `keyfunc` set once, outside the handler — Step 1 saw the discovery/JWKS calls; doing that per-invocation on a warm Lambda is wasted latency, and `keyfunc` refreshes its cache on a `kid` it doesn't recognize, which is what covers key rotation.
3. **`iss` and `aud`**, exact string match. `iss` **includes the trailing slash** — Step 1's RESULTS.md has your exact issuer string; copy it, don't retype it.
4. **`exp`.** `jwt.ParseWithClaims` checks this for you if you use its claims validation — don't hand-roll a time comparison that Step 1's library already does correctly.

**Pin the algorithm.** `jwt.WithValidMethods([]string{"RS256"})` on the parse call. Without it, a token's own header can name the algorithm, and Step 1's checkpoint answer is why that's dangerous: an attacker who knows your RSA public key can craft an `HS256` token, HMAC-signed with that public key as the "secret," and a verifier that trusts the header's `alg` accepts it as genuine. In this exact stack a second layer already helps: `golang-jwt` refuses HMAC verification when `keyfunc` hands it an RSA public key, so the forgery would fail with an invalid-key-type error even unpinned. Pin anyway — it makes the rule explicit, rejects the wrong algorithm before any key work, and stays safe if the key lookup ever changes to one that returns raw bytes. In that naive case the pin is the only defense, and the unit tests prove it.

---

## 3. Allow, Deny, and error — three outcomes, not two

| Authorizer does | API Gateway responds | Meaning |
|---|---|---|
| Returns an `Allow` policy | Integration runs, backend responds | Token good |
| Returns a `Deny` policy | **403** | Token present but rejected — bad signature, wrong `iss`/`aud`, expired |
| Returns an error (panics, or the Go error return) | **401** or **500** depending on the message | Malformed request — no header at all, or the authorizer itself broke |

Decide which of your four checks map to which row before writing the handler, and write it down — it's one of Step 3's checkpoints. A common, defensible split: missing/malformed header → error (401); everything that got as far as "there's a bearer token, but it's wrong" → `Deny` (403).

---

## 4. The policy document

```go
type policy struct {
    PrincipalID    string                 `json:"principalId"`
    PolicyDocument policyDocument         `json:"policyDocument"`
}
```

**Scope the resource to the whole API, not the specific method that was called.** The trap in PLANNING.md §3: with caching on (§5), the policy your authorizer returns for `GET /hello` gets cached and replayed for the *next* call this same caller makes to any route — if the `Resource` in that policy names only `.../GET/hello`, a later `POST /items` (Step 5) gets denied by the cache without your authorizer ever running again, and it looks like a bug in Step 5's code. Build the resource ARN as `<method-arn-prefix>/*/*` (stage-scoped, any method, any path) instead of copying the exact method ARN you were invoked with.

`PrincipalID` can be anything for now — a static string is fine. Step 4 makes it the token's `sub`.

---

## 5. The cache is a real design decision, not a knob

`authorizerResultTtlInSeconds` on the authorizer resource. PLANNING.md's Step 7 exists entirely because of this: a cached `Allow` keeps working even after the token it was computed from expires or gets revoked, for up to the TTL. **Start at 0 while you build the checks.** With caching on, the same token gets the same answer for the whole TTL — a **deny is cached too** — so a change you just deployed can look like it did nothing. Once every check works, set it to **300** (matches the decision in §2 of PLANNING.md), not the 3600 max. Running it at 0 forever defeats the point of Step 7 later.

API Gateway keys the cache by the **identity source** — by default the raw `Authorization` header value. Two different tokens never collide in the cache; the same token replayed within the TTL skips your authorizer entirely.

---

## 6. Tests before Auth0

Generate an RSA key pair in the test file (`rsa.GenerateKey`), sign test tokens with `golang-jwt` directly — no network, no Auth0, no `keyfunc`. Test each rejection path from §7 below as its own case. If a test needs a live Auth0 tenant or the internet to run, something's structured wrong: the JWKS fetch should be injectable (an interface `keyfunc` satisfies) so a test can hand the handler a fixed key set built from your test RSA key instead of fetching a real one.

---

## 7. Suggested order

1. `cmd/authorizer` — own Go module, `go mod init`, add `golang-jwt/jwt/v5` and `MicahParks/keyfunc/v3`
2. Handler skeleton: extract header, build the `keyfunc.Keyfunc` (pointed at env var `AUTH0_DOMAIN`), return `Deny` unconditionally — get the plumbing compiling and deployable first
3. Add the four checks from §2, in order, each with its own early return
4. Policy builder (§4) — wildcard resource, not the exact method ARN
5. Unit tests (§6) — one test per rejection case, all against local keys
6. Terraform: `cmd/authorizer`'s IAM role (no permissions beyond its own logs — it never touches DynamoDB), `aws_api_gateway_authorizer` (`type = "REQUEST"`, `identity_source = "method.request.header.Authorization"`, TTL 300), wire it onto `GET /hello`'s `authorization`/`authorizer_id`
7. `make build`, `terraform apply`
8. Get a fresh token from Step 1's tenant (or mint a new one — check it hasn't expired)
9. Provoke each failure in §8 against the *real* deployed authorizer, one at a time, recording the status code for each in RESULTS.md
10. `git tag gatekeeper-step-3-complete`

---

## 8. Checkpoints — provoke each, don't assume

- **Valid token** → 200.
- **No `Authorization` header** → what status? (Your §3 decision.)
- **Tampered signature** (flip a character in the signature segment) → `Deny`, 403.
- **Expired token** — against the deployed API you can only wait one out (or shorten the API's Token Expiration in Auth0 to something like 60 seconds, mint, and wait). A token you sign yourself with a made-up key fails the *signature* check first and never reaches `exp`, so forging an expired token only works in the unit tests, where the key lookup is yours → 403.
- **Wrong `aud`** — a token for a second API → 403. Grants are **per application**: authorize the same app whose credentials you're minting with, or Auth0 refuses with "create a client-grant".
- **`HS256` token signed with your API's public key as the HMAC secret** — construct this once, deliberately, as an attack you're checking is actually blocked, not skipped because "why would anyone do that." Here it's rejected even before the pin matters, but read the log: the reason says the signing method is invalid, which is the pin doing its job before any key is touched.
- **Cache behavior**: call `/hello` twice with the same valid token inside the 300s TTL. Does CloudWatch show your authorizer logging twice, or once? What does that tell you about when the second call's decision was actually made?

---

## 9. Definition of done

- A valid token gets 200; each case in §8 provoked against the real deployed endpoint and rejected, with its status code recorded in RESULTS.md.
- `WithValidMethods([]string{"RS256"})` present, and the `HS256`-with-public-key attack tested and blocked. A unit test with a naive key lookup fails if the pin is removed.
- Policy resource is wildcarded to the API/stage, not the specific method — verified by reading the code, not assumed.
- Unit tests pass with zero network calls and no Auth0 tenant reachable.
- Authorizer's IAM role has no DynamoDB permissions — Step 5 doesn't exist yet, but the habit starts now.
- 401 vs 403 split decided and written down, not incidental.
- Tagged `gatekeeper-step-3-complete`. Still free tier.
