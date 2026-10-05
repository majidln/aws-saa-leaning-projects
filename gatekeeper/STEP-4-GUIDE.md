# Step 4 Guide — The Backend Knows *That*, Not *Who*

A coaching guide, not a code drop. It names what to build and why, and what to provoke on purpose; you write the Go, the HCL, and the Action.

**Goal (from [PLANNING.md](PLANNING.md)):** the authorizer already knows a token is genuine. The backend Lambda knows nothing about who is calling. Put the caller's tenant into the token, have the authorizer pass it on, and have the backend read it — without the backend ever seeing a JWT.

```
Auth0 app metadata ──► Action copies it ──► token claim ──► authorizer reads it ──► context ──► backend
 (tenant_id=tenant-a)   (M2M trigger)     (namespaced)      (already verified)    (strings)   (no JWT code)
```

---

## 1. Where the tenant comes from

Not from the request. A client can send any header or body it likes, so `tenant_id` has to be something only Auth0 can put in a signed token. Two moving parts:

- **Application metadata** on each M2M app: a key/value pair, `tenant_id = tenant-a`. This is the source of truth, and it's editable in Auth0, not in code.
- **An Action** that copies that metadata into the access token as a claim when the token is issued.

The Action doesn't *decide* the tenant — it only copies. That keeps one Action serving every tenant.

Add a second M2M app, `tenant-b`, with `tenant_id = tenant-b`. **Grants are per application** (the Step 3 lesson): authorize `tenant-b` for `Gatekeeper API` on its own **APIs** tab, or its token request is refused with "create a client-grant".

Where to set metadata: the application's **Settings** tab (look for *Application Metadata*; dashboard layouts move around). The Management API can also do it — `PATCH clients/<id>` with `client_metadata` — and your Auth0 CLI can call that with `auth0 api patch`.

---

## 2. The Action

Trigger: **Machine to Machine** (internally `credentials-exchange`). `post-login` never runs for `client_credentials`, so an Action attached there would silently do nothing.

Shape: an exported handler `onExecuteCredentialsExchange(event, api)`. The app's metadata is on `event.client.metadata`; a claim is added with `api.accessToken.setCustomClaim(name, value)`. Actions run on Node, so this file is JavaScript, and lives under `auth0/actions/` per the layout in PLANNING.md.

Three things that fail without an error:

- **Namespace the claim.** Auth0 drops custom claims that aren't namespaced, silently. Use `https://gatekeeper/tenant_id`. The namespace is an identifier, not a URL that gets fetched — and it can't be an Auth0-owned domain.
- **Deploy *and* attach.** Saving an Action does nothing. It has to be **Deployed**, then dragged into the flow under **Actions → Triggers → Machine to Machine** and **Applied**. Deployed-but-not-attached is the classic "my Action never ran".
- **Only new tokens change.** A token you already hold keeps its old claims until it expires. After the Action is live, mint fresh ones.

**Scope the Action to your API, first thing.** This trigger fires for **every** machine-to-machine token in the Auth0 tenant — not just tokens for your API. That includes the Management API token any tooling needs, such as Terraform's own app. An Action that refuses tokens without checking the audience first will refuse those too. Start the handler with a check on `event.resource_server.identifier` and `return` unless it's `https://gatekeeper/api`.

Skipping this is what happened here: the Action denied `terraform-gatekeeper` (no `tenant_id`, and it shouldn't have one), `terraform plan` failed with `invalid_request ... has no tenant_id metadata`, and Terraform could no longer reach the Action it had created. It had to be repaired through the Auth0 CLI, which authenticates as you rather than as that app.

**What if an app *for your API* has no `tenant_id`?** Decide and write it down. Either don't add the claim (and let the authorizer reject the token), or refuse to issue the token. Prefer to do both: fail at the source *and* at the authorizer, because the authorizer must never trust that an Action ran. Only refuse inside the audience check above.

### Managing it with Terraform instead of the dashboard

The `auth0` provider covers all three states: `auth0_action` is the draft, `deploy = true` is the Deploy button, and `auth0_trigger_action` is the drag-into-the-flow step. Read the code with `file(...)` so the JavaScript stays in its own `.js` file.

- **Look up the trigger version, don't guess it.** `auth0 api get actions/triggers` lists `credentials-exchange` as `v2` (current) and `v1` (deprecated).
- **Terraform needs its own app.** A machine-to-machine app for the *Management API* (`https://<domain>/api/v2/`), granted only `read`, `create`, `update` and `delete` `:actions`. Not `tenant-a`: that one mints tokens for your API and can't manage Auth0.
- **Secrets stay out of git.** Put the app's client ID and secret in `infra/terraform.tfvars` (the `*.tfvars` rule ignores it) and mark the secret variable `sensitive`. It still lands in Terraform state, so state never goes in git either.
- **The shell-variable trap.** The provider also reads `AUTH0_CLIENT_ID` and `AUTH0_CLIENT_SECRET` from your environment, the same names you used to mint tokens. Set `client_id` and `client_secret` explicitly in the provider block so a stray `tenant-a` secret in your shell can't be used by mistake.

**Read the token by hand first** — like Step 1. Mint one per app, decode the payload, and find `https://gatekeeper/tenant_id`. Two apps, two different values. Don't touch the authorizer until you can see that.

---

## 3. The authorizer passes it on

An authorizer can return a **context**: key/value pairs API Gateway hands to the backend. That's the only channel from authorizer to backend besides the policy.

What to change, in this order (tests first, they run offline):

- **Read the claim** from the verified token's claims. It's a custom claim, so it arrives as a generic value — check it's present and is a **non-empty string**. A number, an array, or nothing at all is wrong.
- **A valid token with no tenant is not usable.** Return Deny (403) with a clear log reason, not Allow-with-empty-tenant. A multi-tenant backend must never see "tenant unknown" and carry on.
- **Return a context** carrying `tenant_id`, `sub`, and `scope`. Context values must be **strings, numbers, or booleans** — no arrays or objects. Auth0's `scope` is one space-separated string, so leave it as a string; splitting is Step 6's job. An M2M token with no permissions may have no `scope` at all — try it and see what API Gateway does with an empty value; if it objects, omit the key.
- **Never put the raw token in the context.** The backend logs its own event; the token would land in another log group.

Extend the unit tests before touching Terraform: claim present → context has it; claim missing, empty, or the wrong type → Deny; context contains exactly the three keys and nothing token-shaped.

**The cache carries the context.** The decision and its context are cached together, per token, for the TTL. Change a tenant's metadata and the *new* token gets the new value, but a cached old token keeps its old context until the entry expires. Note it, you'll measure this kind of thing in Step 7.

---

## 4. The backend reads it — and never parses a JWT

New function `cmd/items`: `GET /items` for now, no database (Step 5). It reads the context from the request — with the API Gateway proxy event that's `RequestContext.Authorizer`, a generic map — and returns `tenant_id` and `sub` as JSON, and logs the tenant.

The rule that makes the whole design work: **`cmd/items` has no JWT library.** No import, no `go.mod` entry. It trusts the context because only API Gateway can set it — a client can't forge `requestContext` — which is only true while API Gateway is the only thing allowed to invoke the function. Your `aws_lambda_permission` scopes that; check it still does for this function.

Ignore anything the client sends about tenancy. A header like `X-Tenant-Id` is just data.

Same pattern as `hello`: logs-only IAM role, log group with retention. That's now three copies of about forty lines (`hello`, `authorizer`, `items`) — decide whether it's time for a module or whether duplication is still cheaper, and write down why. You don't have to build it.

---

## 5. Terraform

- The `items` function, role, and log group.
- `/items` resource and `GET` method with `authorization = "CUSTOM"` and the same authorizer — one authorizer serves both routes, which is why the policy resource was wildcarded.
- Integration and a Lambda permission scoped to `GET /items`.
- Add the new resources to the deployment `triggers`, or the stage keeps serving the old snapshot. Add `items` to the Makefile's `FUNCTIONS`.

---

## 6. Suggested order

1. Add `tenant-b`, its grant, and `tenant_id` metadata on both apps
2. Write the Action (audience check first), **deploy and attach it** — dashboard, or the Terraform provider — then mint a token per app and decode both by hand
3. Extend the authorizer's unit tests (§3), then the authorizer code until they pass
4. `cmd/items` (§4) with its own tests; confirm no JWT import: `grep -r jwt cmd/items` should print nothing
5. Terraform (§5), `make build`, `terraform apply`
6. Call `/items` with each app's token and compare — `terraform output -raw items_url` gives the URL, and the Bruno collection in [`bruno/`](bruno/) does it in a click
7. Checkpoints, one line each in RESULTS.md
8. `git tag gatekeeper-step-4-complete`

---

## 7. Checkpoints

- Add the claim **without** the namespace once, deliberately. Decode a new token. Where did it go?
- Remove the Action from the flow. What does the authorizer log for a fresh token, and what status does the client get?
- Call `/items` with each app's token. Do the two responses differ? Then add `X-Tenant-Id: tenant-b` to a `tenant-a` request. Does anything change?
- Change `tenant-a`'s metadata while holding an old token. Does the old token's claim change? What about a token minted after?
- Is `hello` still protected by the same authorizer, and does it still work with a token that carries the new claim?
- Which *other* apps get tokens through this trigger? Mint a Management API token as Terraform's app. What would have happened to it if the Action denied unconditionally?

---

## 8. Definition of done

- Tokens from `tenant-a` and `tenant-b` carry different `https://gatekeeper/tenant_id` values, seen by decoding them.
- The authorizer denies a valid token with a missing or malformed tenant claim, with unit tests proving it.
- The authorizer's context carries `tenant_id`, `sub`, `scope` — and never the token.
- `GET /items` returns each caller's own tenant, and `cmd/items` has no JWT import.
- A client-supplied tenant header changes nothing.
- The Action lives under `auth0/actions/`, is Deployed and attached, and only acts on tokens for `https://gatekeeper/api` — a Management API token passes through untouched.
- Tagged `gatekeeper-step-4-complete`. Still free tier.
