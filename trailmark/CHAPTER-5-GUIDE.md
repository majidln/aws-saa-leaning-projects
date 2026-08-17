# Chapter 5 Guide — "Just Review It Before It Goes Live" (CI/CD)

Same format as before: concepts and resource names, no ready-to-paste code, you write the actual thing. The Terraform in this chapter is the easiest of the project. The *hard* part is IAM trust policy semantics and knowing what a CI job is allowed to print — and unlike previous chapters, a mistake here isn't a broken stack, it's a security hole or a leaked credential.

**Goal (from README.md):** infrastructure changes proposed, reviewed, and applied with nobody holding long-lived AWS credentials on their laptop. `terraform plan` posted automatically on every PR; `terraform apply` on merge to `main`.

**Decisions already made for this chapter:**

- **OIDC federation only (decided by README).** No `AWS_ACCESS_KEY_ID` in GitHub secrets, no IAM user, no static keys anywhere. GitHub's OIDC provider issues a short-lived token; AWS trades it for temporary credentials via `sts:AssumeRoleWithWebIdentity`.
- **This chapter deploys its own small, cheap stack** — see §5. It does **not** automate Chapter 4's three-tier stack. That is a deliberate scoping decision with real reasoning behind it, not laziness.
- **`.github/workflows/` lives at the repo root**, not inside `chapter-5-*/`. GitHub only reads workflows from that one path, so this chapter is the first that genuinely cannot be self-contained the way `PLANNING.md` §2 requires. Name the exception rather than pretending it isn't one: the *Terraform* stays chapter-local, the workflow files can't.
- **Repo facts this guide assumes:** remote `majidln/aws-saa-leaning-projects`, default branch `main`, `trailmark/` as a subdirectory of the repo root. All of that affects paths and trust policies below.

---

## 0. Layout

```
.github/workflows/                    <- repo root, unavoidable
  chapter-5-plan.yml
  chapter-5-apply.yml

trailmark/chapter-5-pipeline/
  bootstrap/                          <- local state; creates the OIDC provider + roles
  stack/                              <- what the pipeline actually deploys
```

---

## 1. The bootstrap chicken-and-egg

The workflow authenticates by assuming an IAM role. That role, and the OIDC provider it trusts, must exist *before* any workflow can run. The pipeline cannot create its own credentials.

So `bootstrap/` is a small local-state config you apply by hand, exactly like Chapter 2's `state-backend/`. Same pattern, same reason: something has to exist before the automated thing can work. Resources you need:

- `aws_iam_openid_connect_provider` — URL `https://token.actions.githubusercontent.com`, client ID list containing `sts.amazonaws.com`. The `thumbprint_list` argument still exists but AWS has trusted this provider's certificate chain natively since 2023; you no longer need to chase the thumbprint value that older blog posts obsess over.
- Two `aws_iam_role`s — see §2 for why two, and §3 for what each is allowed to do.

Your account currently has **no** OIDC provider (`aws iam list-open-id-connect-providers` returns empty), so you're starting clean. Note that the provider is account-global: one per account, shared by every repo you ever wire up. Don't let a later chapter create a second one.

---

## 2. The trust policy is the entire security story

This is the part worth slowing down on. Everything else in the chapter is plumbing.

The role's assume-role policy grants `sts:AssumeRoleWithWebIdentity` to the OIDC provider, gated by conditions on the token's claims. Two conditions matter:

- **`aud`** must equal `sts.amazonaws.com`.
- **`sub`** identifies *which repo, on which ref, in which context* is asking. This is the one that decides whether your AWS account is yours or everyone's.

The `sub` claim takes forms like:

```
repo:majidln/aws-saa-leaning-projects:ref:refs/heads/main
repo:majidln/aws-saa-leaning-projects:pull_request
```

**The trap:** a `sub` condition of `repo:*`, or using `StringLike` with a careless wildcard, or omitting `sub` entirely and only checking `aud`. Any of those means **any GitHub Actions workflow in any repository on GitHub** can assume your role. The `aud` claim is identical for every GitHub repo on earth — it proves the token came from GitHub, nothing more. Scoping is entirely `sub`'s job.

Prefer `StringEquals` on an exact `sub` where you can. If you need `StringLike`, anchor the repo portion exactly and wildcard only the trailing ref.

**Why two roles:** the PR job runs against code from a branch that hasn't been reviewed yet. Give it a role that can only `plan` — broad read, no write. The apply job gets a separate role trusted only from `refs/heads/main`. One role doing both means an unreviewed PR runs with permission to destroy your infrastructure.

---

## 3. The two workflows

**Plan, on `pull_request`.** Checkout, `hashicorp/setup-terraform`, `aws-actions/configure-aws-credentials` with `role-to-assume`, then `init` / `fmt -check` / `validate` / `plan`, and post the result to the PR.

**Apply, on `push` to `main`.** Same setup, assuming the apply role, running `apply` on the merged commit.

Things that are easy to get wrong:

- **`permissions:` must include `id-token: write`.** Without it there's no OIDC token and the credential step fails with an error that doesn't obviously say so. You also need `contents: read`, and `pull-requests: write` for the job that comments.
- **Use `pull_request`, never `pull_request_target`.** `pull_request_target` runs the *base* branch's workflow with full write permissions and secrets, in a context where a fork's code can influence it. It exists for a narrow use case and is a well-known way to hand your credentials to a stranger. If you find yourself reaching for it to make forks work, the correct answer is that forks shouldn't get credentials.
- **Path filters.** Scope both workflows to `trailmark/chapter-5-pipeline/**` and the workflow files themselves, so editing a README doesn't trigger a plan.
- **A `concurrency` group.** Two workflows racing for the same state hit the S3 lock and one fails noisily. Serialize them per branch instead.
- **Pin actions.** Third-party actions run with your OIDC token. Pin to a full commit SHA, not a moving tag.

---

## 4. Posting the plan — and the credentials you can leak doing it

`terraform plan` output is not automatically safe to publish. Terraform redacts values it knows are sensitive, but the redaction is not total, and a saved plan **file** contains everything in the clear — the same way Chapter 4's state file held a 32-character database password three times over in plaintext.

Before you wire up plan-comment posting, answer two questions:

1. **Is this repository public or private?** Check, don't assume. A plan comment on a public PR is world-readable and permanently indexed. If it's public, that alone should shape what the pipeline is allowed to deploy.
2. **Does the stack contain anything sensitive?** If it has a `random_password`, a Secrets Manager version, or an RDS master password, a posted plan is a potential disclosure and a saved plan artifact definitely is.

Practical rules: never `upload-artifact` a `.tfplan`. Pipe plan output through `terraform show -no-color` rather than dumping raw. Truncate long plans instead of posting them whole. And prefer a stack with no secrets in it at all — which leads directly to the next section.

---

## 5. What the pipeline deploys, and why it isn't Chapter 4's stack

Automating the Chapter 4 three-tier stack sounds like the obvious move. Don't.

- **Iteration cost.** Getting a CI pipeline working takes many pushes — trust policy typos, missing permissions, wrong paths. Each one against Chapter 4's stack is a ~10 minute apply and real money. Against an S3 bucket it's twenty seconds and free.
- **Merge cost.** "Apply on merge to main" against a stack containing a NAT Gateway and RDS means every merge starts billing the project's two most expensive resources.
- **Leak surface.** Chapter 4's stack generates database passwords. Per §4, that's exactly what you don't want a pipeline printing into PR comments.

Give `stack/` something small and boring — a versioned S3 bucket, or the Chapter 1 static site rebuilt from scratch per the independence principle. The pipeline mechanics are *identical* regardless of what's underneath, and the pipeline is the entire point of the chapter.

If you later want the real thing automated, the workflow you build here transfers unchanged. That's the argument for keeping it cheap now, not a reason to skip it.

---

## 6. Environments, approval, and the workspace hazard

Chapter 4 left you with two selectors that can silently disagree. In CI nobody is watching, so add the guard the chapter declined to add locally: **assert `terraform workspace show` matches the intended target before any apply**, and fail the job if it doesn't. One line of shell, and it closes the failure mode that produced `errored.tfstate`.

For a manual gate on prod, use a **GitHub Environment** with required reviewers rather than trying to express approval in Terraform. The apply job references the environment; GitHub pauses the run until a human approves. That's the "review it before it goes live" the chapter title is named after, and it's a GitHub feature, not an AWS one.

---

## 7. Suggested build order

1. Write `bootstrap/` — OIDC provider and the two roles. Apply locally. Keep its state local; it's meta-infrastructure like `state-backend/`.
2. Write `stack/` — something small, with a backend key of its own in `trailmark-state-backend`.
3. Write the plan workflow. Open a throwaway PR and iterate until it authenticates and posts a plan. Expect several attempts; that's normal and is why §5 matters.
4. Verify the negative case: confirm the plan role genuinely cannot write. Try an apply with it and watch it fail.
5. Write the apply workflow. Merge the throwaway PR and watch it apply.
6. Add the prod approval gate and the workspace assertion.
7. Destroy `stack/`. Leave `bootstrap/` — the OIDC provider and roles cost nothing and Chapter 6 would only recreate them.

---

## 8. Checkpoints

- Write out your `sub` condition and ask: if I pasted this trust policy into a public gist, what could a stranger do with it? If the answer isn't "nothing," it's wrong.
- Why is `aud` alone insufficient, given that it does prove the token came from GitHub?
- Your plan role and apply role differ. Describe the specific attack the split prevents — concretely, what would an attacker put in a PR?
- After the first successful apply: confirm no long-lived AWS key exists anywhere. Check GitHub repo secrets, `~/.aws/credentials`, and any `.env`. What's the actual credential lifetime of what CI used?
- The pipeline can now change infrastructure without a human running anything. What stops a bad merge from destroying prod, and is that mechanism in AWS, in GitHub, or only in your habits?

---

## 9. Definition of done

- A PR against this repo automatically posts a `terraform plan`.
- A merge to `main` automatically runs `terraform apply`.
- Authentication is OIDC end to end — no static AWS keys in GitHub secrets, and none needed locally except for `bootstrap/`.
- Plan and apply use **separate roles**, with the plan role verified unable to write.
- The `sub` condition is scoped to this exact repository — verified by reading it, not by assuming.
- No plan file is ever uploaded as an artifact, and no secret appears in any PR comment.
- Prod applies pause for human approval via a GitHub Environment.
- The apply job asserts the selected workspace before touching anything.
- `stack/` destroyed; `bootstrap/` left in place.
