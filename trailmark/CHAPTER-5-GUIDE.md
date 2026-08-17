# Chapter 5 Guide — "Just Review It Before It Goes Live" (CI/CD)

Same format as before: concepts and resource names, no ready-to-paste code, you write the actual thing. The Terraform here is the easiest of the project. The hard part is IAM trust-policy semantics and knowing what a CI job is allowed to print — and unlike previous chapters, a mistake is not a broken stack, it is a security hole or a leaked credential.

**Goal (from README.md):** infrastructure changes proposed, reviewed, and applied with nobody holding long-lived AWS credentials on their laptop. `terraform plan` posted automatically on every PR; `terraform apply` on merge to `main`.

**Decisions already made for this chapter:**

- **OIDC federation only (decided by README).** No `AWS_ACCESS_KEY_ID` in GitHub secrets, no IAM user, no static keys anywhere. GitHub's OIDC provider issues a short-lived token; AWS trades it for temporary credentials via `sts:AssumeRoleWithWebIdentity`.
- **This chapter deploys its own small, cheap stack** — see §5. It does **not** automate Chapter 4's three-tier stack. That is a deliberate scoping decision with real reasoning, not laziness.
- **Two roles, not one.** A read-only role for pull requests, a write role reachable only from `main`.
- **`.github/workflows/` lives at the repo root**, not inside `chapter-5-*/`. GitHub reads workflows from that one path only, so this is the first chapter that genuinely cannot be self-contained the way `PLANNING.md` §2 requires. Name the exception rather than pretending: the *Terraform* stays chapter-local, the workflow files cannot.
- **Repo facts this guide assumes:** remote `majidln/aws-saa-leaning-projects`, default branch `main`, `trailmark/` as a subdirectory of the repo root. All of that affects paths and trust policies.

---

## 0. Layout

```
.github/workflows/                    <- repo root, unavoidable
  chapter-5-plan.yml                  on: pull_request
  chapter-5-apply.yml                 on: push to main

trailmark/chapter-5-pipeline/
  bootstrap/                          OIDC provider + the two roles — you apply this by hand
  stack/                              what the pipeline deploys
```

---

## 1. The bootstrap split

The workflow authenticates by assuming an IAM role. That role, and the OIDC provider it trusts, must exist *before* any workflow can run. **The pipeline cannot create the credentials it needs to authenticate.** So `bootstrap/` is applied by hand, once, with your own credentials.

**Its state still belongs in S3.** The chicken-and-egg here is about *credentials*, not *state storage* — the state bucket already exists from Chapter 2's bootstrap. (Chapter 2's own bootstrap needed local state because the bucket itself did not exist yet; that reasoning does not carry over.) Give `bootstrap/` its own key, `chapter-5-pipeline/bootstrap/terraform.tfstate`, and give `stack/` `chapter-5-pipeline/stack/terraform.tfstate`. No workspaces — this is account-global infrastructure.

Resources in `bootstrap/`:

- `aws_iam_openid_connect_provider` — URL `https://token.actions.githubusercontent.com`, client ID list containing `sts.amazonaws.com`. `thumbprint_list` still exists as an argument but AWS has trusted this provider's certificate chain natively since 2023; try omitting it before chasing the hex value older blog posts obsess over.
- Two `aws_iam_role`s — see §2 and §5.

The provider is **account-global**: one per AWS account, shared by every repo you ever wire up. Do not let a later chapter create a second one. If one already exists, `terraform import` it rather than deleting — the import ID is the full ARN.

**CI never touches `bootstrap/`.** The apply role's state permission is scoped to `chapter-5-pipeline/stack/*` only, so the pipeline cannot rewrite the IAM roles that granted it access. That is the security boundary, not an inconvenience: if you change `bootstrap/`, you run it by hand again.

---

## 2. The trust policy is the entire security story

Slow down here. Everything else in the chapter is plumbing.

The role's assume-role policy grants `sts:AssumeRoleWithWebIdentity` to the OIDC provider, gated by conditions on the token's claims. Two matter:

- **`aud`** must equal `sts.amazonaws.com`.
- **`sub`** identifies which repo, on which ref, in which context is asking.

**The trap:** a `sub` condition of `repo:*`, a careless `StringLike` wildcard, or omitting `sub` and checking only `aud`. Any of those lets **any GitHub Actions workflow in any repository on GitHub** assume your role. `aud` is identical for every GitHub repo on earth — it proves the token came from GitHub, nothing more. Scoping is entirely `sub`'s job.

### The `sub` format will probably surprise you

This repo issues **immutable subject claims** — the owner and repo carry their numeric GitHub IDs so the claim survives a rename:

```
repo:majidln@8521168/aws-saa-leaning-projects@1326414898:pull_request
repo:majidln@8521168/aws-saa-leaning-projects@1326414898:ref:refs/heads/main
```

The plain `owner/repo` form that every tutorial shows **will not match**, and the failure is a bare `AccessDenied` with no hint. Do not assume the format — read it from a real token (§6).

Note the two suffixes differ in shape. `pull_request` is a literal string, not a ref: GitHub sets that exact value for any workflow triggered by a `pull_request` event, regardless of which branch the PR came from. **That is precisely why the plan role must be read-only** — you cannot distinguish a trusted contributor's PR from anyone else's at the trust-policy level.

Prefer `StringEquals` on an exact `sub`. If you need `StringLike`, anchor the repo portion exactly and wildcard only the trailing part.

Use `aws_iam_policy_document` rather than `jsonencode()` for these. Terraform validates the structure, the `principals` and `condition` blocks are self-documenting, and the provider ARN becomes a reference instead of a hardcoded account number.

---

## 3. The two workflows

**Plan, on `pull_request`.** Checkout, `setup-terraform`, `configure-aws-credentials` with the plan role, then `init` / `validate` / `plan`, then post the result to the PR.

**Apply, on `push` to `main`.** Same setup with the apply role, `plan -out=tfplan`, then `apply tfplan`.

Things that are easy to get wrong:

- **`permissions:` must include `id-token: write`.** Without it there is no OIDC token and the credential step fails with an error that does not say so. Also `contents: read`, plus `pull-requests: write` on the job that comments.
- **Use `pull_request`, never `pull_request_target`.** The latter runs the base branch's workflow with full write permissions and secrets in a context a fork can influence. If you reach for it to make forks work, the correct answer is that forks should not get credentials. (They don't: GitHub refuses `id-token: write` to fork workflows, so a stranger's PR cannot reach either role.)
- **`working-directory`.** The repo root has no `.tf` files. Set `defaults.run.working-directory` on the job.
- **Path filters**, so a README edit does not trigger Terraform.
- **`concurrency`.** Two runs racing for the same state hit the S3 lock and one fails. Use `cancel-in-progress: true` for plan and **`false` for apply** — killing Terraform mid-apply can leave a stale lock and resources that exist but are not in state.
- **`plan -out` then `apply` that file.** Guarantees the apply does what the plan showed, rather than silently re-planning. Keep the file inside the runner (§4).
- **Role ARNs belong in repository *variables*, not secrets.** An ARN is an address, not a credential — the trust policy protects the role. Secrets are masked as `***`, which costs you readable logs for no security gain. Variables are also available to fork PRs, where secrets are not.
- **Action pinning.** Pinning to a full commit SHA rather than a moving tag is the stricter choice, because actions run with your OIDC token. This repo pins to major tags (`@v4`, `@v3`) against first-party publishers — GitHub, HashiCorp, AWS — which is a defensible risk position for a solo project and what most real repos do. Decide deliberately; just know that tags are mutable.

---

## 4. Posting the plan, without leaking

`terraform plan` output is not automatically safe to publish. Terraform redacts values it knows are sensitive, and the redaction is not total — and a saved plan **file** contains everything in the clear, the same way Chapter 4's state held a 32-character database password three times over.

Rules that follow from that:

- **Never `upload-artifact` a `.tfplan`.** Artifacts outlive the run. Post text into a comment instead.
- **Truncate.** GitHub caps a comment at 65,536 characters; cut at ~60,000 and link to the run.
- **Post failures too.** `continue-on-error` on the plan step, then fail the job explicitly at the end. A broken plan is the most useful thing a reviewer can see; hiding it in a red cross is worse.
- **Edit rather than append.** `gh pr comment --edit-last` (with a plain `gh pr comment` fallback) keeps repeated pushes from burying the plan under duplicates.
- **Know whether the repo is public**, and know what is in the stack. This chapter's stack has no secrets in it, which is what makes posting safe at all. Do not copy the step onto a stack that generates passwords.

---

## 5. What the pipeline deploys, and why it isn't Chapter 4's stack

`stack/` is one versioned, private, encrypted S3 bucket. Deliberately boring.

- **Cost.** "Apply on merge to `main`" against Chapter 4's stack starts billing a NAT Gateway and RDS on every merge — measured at roughly $0.25/hr with both environments up. An empty bucket is free.
- **Iteration.** Getting OIDC working takes many pushes. Each attempt against Chapter 4's stack is a ~10 minute apply; against a bucket it is seconds.
- **Leak surface.** Chapter 4's stack generates a database password. Per §4, that is exactly what you do not want a pipeline printing into PR comments.

The pipeline mechanics are identical regardless of what sits underneath, and the pipeline is the entire point. The workflow transfers unchanged if you later want the real thing automated.

**Permissions follow the stack, not the reverse.** Write the roles' *trust* policies first and leave the apply role with **no** permissions until `stack/` exists. A role that can be assumed and can do nothing is the correct state for it. Once you know what the stack contains, you can scope precisely — and guessing earlier is how roles end up with `AdministratorAccess`.

### Wide action or narrow resource — pick one

An IAM statement is scoped two ways, and you rarely get both:

```
narrow action, wide resource  →  "may only PutObject, on any bucket"
wide action, narrow resource  →  "may do anything, but only to THIS bucket"
```

For S3 the second is usually more practical *and* safer. Terraform reads far more bucket settings than it manages — versioning, encryption, tagging, ACL, lifecycle, policy, replication — so an action allowlist grows long and still breaks. `s3:*` on one named bucket has a blast radius of one bucket.

**Where that reasoning does not apply: the plan role.** It runs unreviewed code, so every grant names its exact resource. It needs `Get`/`List` on the demo bucket, `GetObject` on its own state, `ListBucket` to find it, and write access to **one** object — the lock file. Naming that single key is what stops "plan can write" meaning "plan can overwrite any state file."

Two details that are easy to miss:

- **`terraform plan` is not purely read-only.** With `use_lockfile = true` it creates a `.tflock` object and deletes it afterwards.
- **It must also *read* the lock.** When a lock is held, the conditional `PutObject` returns 412 and Terraform then `GET`s the `.tflock` to report who holds it. Without `s3:GetObject` on that key, contention surfaces as an opaque `AccessDenied` instead of the useful `Lock Info: ... Who: ...` message. This only bites under concurrency, so green runs will not catch it.

A useful sanity check: **is your untrusted role weaker than your trusted one?** It is easy to carefully deny the apply role access to `bootstrap/` state and then leave that door open on the role that runs PR code.

---

## 6. Debugging OIDC

A trust-policy mismatch produces `Not authorized to perform sts:AssumeRoleWithWebIdentity` and nothing else. That vagueness is deliberate — a stranger probing your account learns nothing from it. It also means guessing is useless. Two ways to see the truth:

**Read the claim GitHub issued**, before AWS is involved. A step that fetches the token and prints selected claims tells you the exact `sub`:

```
ACTIONS_ID_TOKEN_REQUEST_TOKEN / ACTIONS_ID_TOKEN_REQUEST_URL
  → the JWT's middle segment, base64url-decoded
  → print sub, aud, repository, ref, event_name
```

Print **claims only, never the raw token** — the token is a credential, and anyone who lifts it from a log can assume your role for its lifetime.

**Or read what AWS received**, from CloudTrail. `userIdentity.userName` is the `sub` as AWS parsed it, and `resources` names the role that was targeted:

```bash
aws cloudtrail lookup-events --region us-east-1 --max-results 1 \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --query "Events[0].CloudTrailEvent" --output text \
  | python3 -c "import json,sys; e=json.load(sys.stdin); print(e['userIdentity']['userName']); print([r['ARN'] for r in e['resources']])"
```

Compare against the trust policy character by character. CloudTrail lags up to ~15 minutes.

---

## 7. Two things that must agree, and nothing checks them

Chapter 4 ended with a hazard: `terraform workspace select` and `-var-file` both decide "which environment," and nothing ties them together. This chapter reproduces that shape three times:

| A | B | Symptom when they disagree |
|---|---|---|
| role ARN in the GitHub variable | trust policy in Terraform | a PR assumes the *apply* role and is refused |
| `sub` in the trust policy | `sub` GitHub actually issues | bare `AccessDenied` |
| `environment:` in the workflow | `sub` the trust policy expects | bare `AccessDenied` |

Each is two sources of truth for one fact, with no mechanism forcing them to match. That is the transferable lesson of Chapters 4 and 5 together — more than any specific Terraform or IAM detail. When you find such a pair, either collapse it to one source or add an explicit assertion; noticing it is the skill.

---

## 8. Optional extensions — not completion criteria

None of these are required to finish the chapter. They are the natural next steps, and each is listed with why it does *not* apply to what you built.

- **A GitHub Environment approval gate.** `environment:` on the apply job makes GitHub pause for a required reviewer. Skipped here: with one deploy target and one person merging, the PR already provides the review and the gate is ceremony. **If you add it, the trust policy must change at the same time** — declaring an environment replaces the ref portion of `sub` with `environment:<name>`. Pinning `sub` to the environment is actually the stronger design, because AWS then refuses any apply that skipped the gate, rather than trusting a GitHub setting to still be switched on. You would also want a separate condition on the `ref` claim, since the branch is no longer in `sub`.
- **Workspaces for the pipeline stack.** `stack/` has a single default workspace, so there is nothing to select wrongly and no assertion worth writing. If you give it dev/prod like Chapter 4, then a `terraform workspace show` assertion before every apply becomes necessary — in Chapter 4 a human read each plan, and here nobody is watching.
- **Drift detection.** A scheduled workflow running `plan -detailed-exitcode` (exit 2 means drift) that opens an issue when someone changes something in the console. Reuses the read-only plan role and costs nothing.
- **Pinning actions to commit SHAs**, per §3.

---

## 9. Status

**Complete.** Both workflows proven against the real repo: a plan comment posted by `github-actions` on PR #7, and three successful merge-triggered applies. `bootstrap/` matches its code with no drift. The plan role's policy contains no wildcard resources and can reach neither the other chapters' state nor `bootstrap/`'s.

Failures along the way, all recorded in the Actions run history: two applies failed on the environment-claim mismatch, and several plans failed on the immutable-`sub` format before the trust policy was corrected.

---

## 10. Checkpoints

- Write out your `sub` condition and ask: if I pasted this trust policy into a public gist, what could a stranger do with it? If the answer is not "nothing," it is wrong.
- Why is `aud` insufficient on its own, given that it does prove the token came from GitHub?
- Your plan and apply roles differ. Describe the specific attack the split prevents — concretely, what would an attacker put in a PR?
- Compare the two roles line by line. Can the *untrusted* one do anything the trusted one cannot? If so, why did that happen?
- Confirm no long-lived AWS key exists anywhere: GitHub secrets, `~/.aws/credentials`, any `.env`. What is the actual credential lifetime of what CI used?
- The pipeline can now change infrastructure without a human running anything. What stops a bad merge from destroying the stack — and is that mechanism in AWS, in GitHub, or only in your habits?

---

## 11. Definition of done

- A PR against this repo automatically posts a `terraform plan`. ✅
- A merge to `main` automatically runs `terraform apply`. ✅
- Authentication is OIDC end to end — no static AWS keys in GitHub, and none needed locally except for `bootstrap/`. ✅
- Plan and apply use **separate roles**, and the plan role cannot write anything beyond its own lock file. ✅
- The `sub` condition is scoped to this exact repository — verified by reading a real token, not by assuming. ✅
- No plan file is ever uploaded as an artifact, and no secret appears in any PR comment. ✅
- `bootstrap/` applied by hand, its state separate from `stack/`, and unreachable by the pipeline. ✅
- `stack/` destroyed when you are finished; `bootstrap/` left in place — the OIDC provider and roles are free, and the provider is account-global.
