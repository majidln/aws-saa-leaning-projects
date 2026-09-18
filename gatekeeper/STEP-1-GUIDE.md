# Step 1 Guide — See a Token Before Validating One

A coaching guide, not a code drop. It names what to set up and what to look at; you click, run, and explain it back.

**Goal (from [PLANNING.md](PLANNING.md)):** a real Auth0-issued access token in the terminal, every claim in it explained, and its `kid` matched to a key in the tenant's JWKS by hand. No AWS, no Go, no Terraform this step.

---

## 0. Working directory

Everything lives in `gatekeeper/`. This step produces no code — only `RESULTS.md` and a clear picture of what Step 3's authorizer will be checking.

---

## 1. The tenant

Sign up at Auth0 and create a tenant on the free plan. Two choices here are permanent:

- **Region** (US, EU, AU, JP) — it's baked into the domain, e.g. `dev-abc123.eu.auth0.com`. Pick the one nearest you; it can't be moved later.
- **Tenant name** — also part of the domain, and therefore part of every token's issuer.

Once you have it, note the domain exactly. Everything else hangs off it.

---

## 2. The API

Applications → APIs → Create API.

- **Name:** `Gatekeeper API` — just a label.
- **Identifier:** `https://gatekeeper/api`. This becomes the token's `aud` claim. It looks like a URL but is never requested — it doesn't need to resolve. **It can't be changed after creation.**
- **Signing algorithm:** `RS256`. Asymmetric: Auth0 signs with a private key, anyone verifies with the public one. `HS256` would mean sharing one secret with every verifier — Step 3 explains why that choice matters even when you never pick it.

Look around the API's Settings tab: find **Token Expiration** and note the default. Leave RBAC off for now — Step 6 turns it on.

Creating an API makes Auth0 quietly create a "Test Application" authorized for it. That's a working credential you didn't ask for. Least privilege starts here: delete it once your own app works (§3).

---

## 3. The client

Applications → Applications → Create Application → **Machine to Machine**. Name it `tenant-a` — in Step 4 it becomes the first simulated tenant.

Authorize it for `Gatekeeper API` (the creation dialog asks; later, it's on the API's Machine to Machine Applications tab). Grant no permissions yet.

From its Settings tab you need the **Client ID** and **Client Secret**. The secret is a password: it goes into an environment variable and nowhere else — not the repo, not a file you might commit, not your shell history.

```bash
export AUTH0_DOMAIN=dev-abc123.eu.auth0.com
```

```bash
export AUTH0_AUDIENCE=https://gatekeeper/api
```

```bash
export AUTH0_CLIENT_ID=<paste client id>
```

```bash
read -s AUTH0_CLIENT_SECRET && export AUTH0_CLIENT_SECRET
```

`read -s` takes the secret from the keyboard without echoing it, so it never appears in history. The domain has **no** `https://` and **no** trailing slash — you'll see in §6 why that detail matters.

---

## 4. Minting a token

The `client_credentials` grant: the client proves who it is with its ID and secret, and asks for a token for one specific audience.

```bash
curl -s --request POST \
  --url "https://$AUTH0_DOMAIN/oauth/token" \
  --header 'content-type: application/json' \
  --data "{\"client_id\":\"$AUTH0_CLIENT_ID\",\"client_secret\":\"$AUTH0_CLIENT_SECRET\",\"audience\":\"$AUTH0_AUDIENCE\",\"grant_type\":\"client_credentials\"}" | jq
```

Read the whole response before extracting anything: `access_token`, `expires_in`, `token_type`. Is there a `scope` field? Why or why not?

Then keep the token in a variable:

```bash
TOKEN=$(curl -s --request POST \
  --url "https://$AUTH0_DOMAIN/oauth/token" \
  --header 'content-type: application/json' \
  --data "{\"client_id\":\"$AUTH0_CLIENT_ID\",\"client_secret\":\"$AUTH0_CLIENT_SECRET\",\"audience\":\"$AUTH0_AUDIENCE\",\"grant_type\":\"client_credentials\"}" | jq -r .access_token)
```

**Every mint counts against the free plan's monthly M2M token quota.** Mint once and reuse `$TOKEN` until it expires. Never mint in a loop.

---

## 5. Decoding it

A JWT is three base64url segments joined by dots: header, payload, signature. The first two are just JSON — encoded, not encrypted.

Header:

```bash
jq -R 'split(".") | .[0] | gsub("-";"+") | gsub("_";"/") | @base64d | fromjson' <<< "$TOKEN"
```

Payload — same command with `.[1]`. The `gsub` calls turn base64url back into standard base64. If `jq` complains, the segment probably needs `=` padding added back to a multiple of 4 characters.

Don't paste real tokens into jwt.io or similar sites. This token is a bearer credential: whoever holds it can use it until it expires. Build the habit now, while it doesn't matter yet.

For each claim, write in RESULTS.md what it means and **where its value came from** — a dashboard setting, your curl request, or Auth0 itself:

| Claim | Look for |
|---|---|
| `alg`, `typ` (header) | Which algorithm — and who chose it? |
| `kid` (header) | Which signing key. Keep it for §6 |
| `iss` | Compare it character by character with `$AUTH0_DOMAIN` |
| `aud` | A string or an array? |
| `sub` | Why does it end in `@clients`? |
| `azp`, `gty` | Who asked, and by which grant |
| `iat`, `exp` | Subtract them. Does it match `expires_in` and the API's Token Expiration setting? |
| `scope` | Present or absent, and why |

---

## 6. The keys

The token names a key by `kid`; the tenant publishes its public keys at a well-known URL. Start one level higher — discovery tells you where the keys are:

```bash
curl -s "https://$AUTH0_DOMAIN/.well-known/openid-configuration" | jq '{issuer, jwks_uri}'
```

Look hard at `issuer`: it has a **trailing slash**, and so does the token's `iss`. Step 3's issuer check is an exact string match, and `https://dev-abc123.eu.auth0.com` without the slash rejects every valid token. That's why `AUTH0_DOMAIN` is kept bare and the issuer is built from it deliberately.

Then the keys:

```bash
curl -s "https://$AUTH0_DOMAIN/.well-known/jwks.json" | jq
```

How many keys are there? Find the one whose `kid` matches your token's. Note its `kty`, `alg`, `use`, and the `n`/`e` fields — the RSA public key itself. This lookup is what `keyfunc` will do for you in Step 3; do it by hand once so the library isn't magic.

---

## 7. Suggested order

1. Tenant (§1), noting the region and domain
2. API with identifier `https://gatekeeper/api` (§2)
3. `tenant-a` M2M app, authorized for the API (§3)
4. Export the four environment variables, secret via `read -s`
5. Mint once, read the full response, then save `$TOKEN` (§4)
6. Decode header and payload; fill in the claims table (§5)
7. Discovery document, then JWKS; match the `kid` (§6)
8. Delete the auto-created Test Application
9. Create `RESULTS.md` with the claims table and the checkpoint answers below
10. `git tag step-1-complete`

---

## 8. Checkpoints

- Change one character in the payload segment and decode it again. It still decodes — maybe to different JSON. **Decoding isn't verifying.** What's the only thing that would catch the edit?
- Request a token with `"audience":"https://gatekeeper/nope"`. What does Auth0 return? Then register a second API, but don't authorize `tenant-a` for it, and request a token for it. Different error? So where does a "wrong audience" token for Step 3's test come from?
- `alg` sits in the header, and the header is written by whoever made the token. Why is it dangerous for a verifier to trust `alg` from the token it's verifying?
- Auth0 doesn't store this token anywhere you can delete it. If `$TOKEN` leaked right now, what could you do about it, and how long would it stay usable?
- Mint a second token. Same `kid`? Same `exp`? What is identical, what differs, and why?

---

## 9. Definition of done

- Tenant, `Gatekeeper API`, and the `tenant-a` M2M app exist; Test Application deleted.
- A real token decoded; every claim in the table explained, with its source.
- `kid` matched to a JWKS key by hand.
- The trailing-slash issuer detail written down for Step 3.
- No secret or token in the repo — check `git status` and the diff before tagging.
- `RESULTS.md` created with the claims table and checkpoint answers.
- Tagged `step-1-complete`. Free, nothing to tear down.
