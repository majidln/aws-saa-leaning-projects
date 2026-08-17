# Chapter 5 — CI/CD Pipeline (OIDC, no stored credentials)

Terraform runs in GitHub Actions instead of on a laptop. A pull request posts a `terraform plan`; a merge to `main` runs `terraform apply`. AWS authentication uses GitHub's OIDC provider — there are **no AWS access keys** stored in GitHub, and none needed except for the one-time bootstrap.

See [CHAPTER-5-GUIDE.md](../CHAPTER-5-GUIDE.md) for the reasoning behind each decision.

---

## Layout

```
.github/workflows/                    <- repo root; GitHub reads workflows only from here
  chapter-5-plan.yml                  runs on pull_request
  chapter-5-apply.yml                 runs on push to main

trailmark/chapter-5-pipeline/
  bootstrap/    OIDC provider + the two IAM roles   — you apply this by hand
  stack/        one versioned S3 bucket             — the pipeline applies this
```

The workflow files cannot live inside this directory: GitHub only reads `.github/workflows/` at the repo root. That makes this the one chapter that isn't fully self-contained.

---

## How it works

```
════ ONCE — you, from your laptop, with your own credentials ════

  bootstrap/  ──terraform apply──►  OIDC provider
                                    chapter-5-pipeline-plan   (read only)
                                    chapter-5-pipeline-apply  (write)
                    │
   terraform output │
                    ▼
        GitHub → Settings → Secrets and variables → Actions → Variables
            PLAN_ROLE_ARN, APPLY_ROLE_ARN


════ EVERY TIME AFTER — GitHub, with nothing stored ════

  open a PR      ──►  plan workflow   ──►  wears plan role   ──►  terraform plan
                                                                  posts a PR comment

  merge to main  ──►  apply workflow  ──►  wears apply role  ──►  terraform apply
```

CI cannot create the credentials it needs to authenticate, so `bootstrap/` has to be applied by a human first. Same pattern as Chapter 2's `state-backend/`.

**CI never touches `bootstrap/`.** The apply role's state permission is scoped to `chapter-5-pipeline/stack/*` only, so the pipeline cannot rewrite the IAM roles that granted it access. That's a deliberate boundary, not an oversight — if you change `bootstrap/`, you run it by hand again.

---

## One-time setup

Requires AWS credentials with IAM permissions, and region `us-east-1`.

```bash
cd bootstrap
terraform init
terraform apply
terraform output
```

Then create two **repository variables** (Variables tab, *not* Secrets):

| Name | Value |
|---|---|
| `PLAN_ROLE_ARN` | `plan_role_arn` from the output |
| `APPLY_ROLE_ARN` | `apply_role_arn` from the output |

Variables rather than secrets on purpose: a role ARN is an address, not a credential, and secrets are masked as `***` in logs — which makes debugging much harder for no security gain.

**Check `var.github_repo` before applying.** It must match the `sub` claim in the OIDC token, which on this repo uses immutable IDs (see Gotchas).

---

## The everyday loop

Nothing to run locally. Change something under `trailmark/chapter-5-pipeline/**` and:

1. Open a pull request → the plan workflow authenticates as the **plan role**, runs `terraform plan`, and posts the output as a PR comment
2. Read the plan
3. Merge to `main` → the apply workflow authenticates as the **apply role** and applies

Both workflows have path filters, so changes elsewhere in the repo don't trigger them.

## Running `stack/` locally

Possible with your own credentials, but it defeats the point of the chapter:

```bash
cd stack
terraform init
terraform plan
```

---

## The two roles

| | plan role | apply role |
|---|---|---|
| Assumable from | any pull request | `main` only |
| Trust `sub` ends with | `:pull_request` | `:ref:refs/heads/main` |
| Demo bucket | `Get*`, `List*` | `s3:*` |
| Own state | read `terraform.tfstate` | read/write `stack/*` |
| State lock | write `terraform.tfstate.tflock` only | via `stack/*` |
| Other chapters' state | none | none |
| `bootstrap/` state | none | none |

Pull requests carry code nobody has reviewed yet, which is why the plan role is read-only. Every grant names its exact resource rather than `"*"` — the one object the plan role may write is the lock file, named explicitly.

Fork pull requests get no OIDC token at all: GitHub refuses `id-token: write` to workflows from forks, so a stranger's PR cannot reach either role.

---

## Gotchas

**The `sub` claim uses immutable IDs.** This repo's token carries numeric GitHub IDs:

```
repo:majidln@8521168/aws-saa-leaning-projects@1326414898:pull_request
```

The plain `owner/repo` form never matches. `var.github_repo` must include the IDs.

**A trust-policy mismatch gives a bare `AccessDenied`.** AWS deliberately explains nothing, so a stranger probing your account learns nothing. The claim that actually arrived is only visible in CloudTrail:

```bash
aws cloudtrail lookup-events --region us-east-1 --max-results 1 \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --query "Events[0].CloudTrailEvent" --output text \
  | python3 -c "import json,sys; e=json.load(sys.stdin); print(e['userIdentity']['userName'])"
```

Compare that against the trust policy. It finds the problem every time. Note CloudTrail lags up to ~15 minutes.

**Declaring a GitHub `environment:` rewrites `sub`.** A job with `environment: foo` sends `...:environment:foo` *instead of* the ref. This chapter has no environment, so the ref form applies — but adding one later means updating the trust policy at the same time.

**Everything is `us-east-1`.** If your AWS CLI defaults elsewhere, verification commands will silently inspect an empty region and tell you nothing exists.

**Two things must agree, and nothing checks them:** the role ARN in the GitHub variable, and the trust policy in Terraform. Pointing `PLAN_ROLE_ARN` at the apply role produces a valid-looking run that fails on the trust check.

---

## Cost and teardown

Effectively zero. An empty versioned S3 bucket costs nothing, and the OIDC provider and IAM roles are free.

```bash
cd stack && terraform destroy    # optional
```

Leave `bootstrap/` in place — it costs nothing, and the OIDC provider is account-global, shared by any repo you wire up later.

### Known leftover

`s3://trailmark-state-backend/chapter-5-pipeline/terraform.tfstate` is a stale object from before the backend key was moved under `bootstrap/`. Safe to delete.
