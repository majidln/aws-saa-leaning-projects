# Trailmark — Execution Roadmap

This document turns the narrative in [README.md](README.md) into an ordered, actionable plan. It covers prerequisites, repo layout, per-chapter entry/exit criteria, cost checkpoints, and the decisions the project deliberately leaves open for the learner to make. It contains no Terraform code — that starts once each chapter's work actually begins.

Items marked **(decided)** come straight from the README. Items marked **(open)** are choices you make as you go — this doc records the recommendation and the reasoning, not a final answer.

---

## 1. Prerequisites (one-time, before Chapter 1)

- [ ] AWS account available, and an IAM identity to work as — **not** the root user. A single IAM user or role with broad-but-scoped permissions is fine for a learning project; note this is a shortcut you wouldn't take on a real team.
- [ ] AWS CLI installed and configured (`aws configure` or SSO profile) so Terraform's default credential chain picks it up.
- [ ] Terraform CLI installed — record the version once installed, so later "it worked on my machine" issues are debuggable.
- [ ] Default AWS region chosen **(open)**. Recommendation: `us-east-1`, because Chapter 2's ACM certificate must live in `us-east-1` to be usable by CloudFront regardless of which region everything else runs in — starting there avoids a region mismatch later. Not enforced here; confirm before Chapter 1.
- [ ] AWS Budget + billing alarm set up. Do this **before Chapter 3** at the latest — that's where NAT Gateway and RDS enter the picture, the two most expensive pieces in this project if left running (per README scope notes).
- [ ] Naming/tagging convention picked and written down, e.g. `Project = trailmark`, plus a `Chapter` or `Environment` tag on every resource. Makes cost and cleanup traceable in the AWS console as the project grows.

---

## 2. Repo layout **(open, recommendation below)**

Tension to resolve: the README wants each chapter independently apply/destroy-able, but also wants later chapters to reuse earlier work (Chapter 4 reuses Chapter 3's modules verbatim; Chapter 5 wraps everything in CI).

**Recommendation:**
- Chapters 1–2: one self-contained root config per chapter — `chapter-1-launch-page/`, `chapter-2-cdn-https/`. Nothing shared yet, so nothing to lose by keeping them separate.
- Starting Chapter 3: shared logic moves into a top-level `modules/` directory (`modules/network`, `modules/app-tier`, `modules/data-tier`, matching the README's own structure), and chapter/environment directories become thin root configs that call those modules.

This keeps "apply and destroy per chapter" honest in the early chapters, and avoids copy-pasted module code once modules exist. Confirm or adjust this before Chapter 3, once modules actually enter the picture.

---

## 3. Per-chapter roadmap

### Chapter 1 — The Launch Page
- **Entry criteria:** prerequisites in §1 done; region and repo layout confirmed.
- **Exit criteria:** site reachable on its S3 static-website endpoint; `providers` / `resources` / `variables` / `outputs` / full `init → plan → apply → destroy` cycle all exercised and understood.
- **Cost checkpoint:** negligible (S3 storage + requests). Still, destroy when done for the day unless moving straight into Chapter 2.
- **Open decisions:** none beyond region/layout (§1–2).

### Chapter 2 — Real Traffic, Real Speed (CDN + HTTPS)
- **Entry criteria:** Chapter 1's bucket exists (this chapter builds on it directly — don't destroy Chapter 1 before starting this one).
- **State backend bootstrap wrinkle (decided, flagged early on purpose):** the S3 bucket + DynamoDB table used for remote state have to be created *somehow* — via a small local-state config — before the "real" Chapter 2 config can point its backend at them. Treat this as a mini-step at the very start of the chapter, not a surprise partway through.
- **Exit criteria:** site served over HTTPS via CloudFront, S3 no longer publicly reachable directly (verify by trying the raw bucket URL and confirming it's blocked), state now lives in S3 with DynamoDB locking confirmed (e.g. by observing a lock during a deliberate concurrent `plan`).
- **Cost checkpoint:** CloudFront + S3 + DynamoDB (on-demand) are all low-cost but not free if left running indefinitely — fine to leave up longer than Chapter 1 given the setup cost of remote state, but don't forget about it.
- **Open decisions:**
  - ACM cert domain: placeholder/self-managed domain vs. CloudFront's default domain **(decided by README — Route 53 is out of scope, so default to CloudFront's own domain unless you specifically want to practice a placeholder cert)**.

### Chapter 3 — The Trail Search Feature (3-Tier Architecture)
- **Entry criteria:** budget alarm from §1 confirmed active (this is where cost risk starts for real); repo layout decision from §2 confirmed.
- **Exit criteria:** ALB reachable on 443 from the internet; app tier reachable only from the ALB's security group; RDS reachable only from the app tier's security group on 5432; DB credentials confirmed to live in Secrets Manager, not in `.tf` files or state-visible variables; each module (`network`, `app-tier`, `data-tier`) exercised with its own inputs/outputs.
- **Cost checkpoint — the big one:** NAT Gateway (hourly + per-GB charge) and RDS are the most expensive resources in the whole project. Plan to `terraform destroy` promptly once verification is done, rather than leaving this stack up between sessions.
- **Open decisions:** none — the DB isolation rule is fixed by the engineering-lead constraint in the README, not a tradeoff to explore.

### Chapter 4 — "We Broke Prod Again" (Environments)
- **Entry criteria:** Chapter 3's three modules exist and are stable (no in-flight changes to their inputs/outputs).
- **Exit criteria:** dev and prod environments both stood up from the same modules with different `.tfvars`; a change proven out in dev before touching prod at least once, to validate the whole point of the chapter.
- **Cost checkpoint:** effectively double Chapter 3's cost if both environments are up simultaneously — favor standing up dev, verifying, destroying, then repeating for prod, over running both at once, unless specifically comparing them side by side.
- **Open decisions (this is explicitly the point of the chapter per the README):**
  - Terraform workspaces vs. folder-per-environment (`environments/dev`, `environments/prod`). Recommendation: implement folder-per-environment first — clearer state isolation, closer to what most real orgs do, and it composes naturally with the `modules/` layout from §2. Once that's working, do a small separate workspaces experiment against the same modules purely to compare — the README calls this comparison out as part of the learning, so it's worth doing deliberately rather than skipping.

### Chapter 5 — "Just Review It Before It Goes Live" (CI/CD)
- **Entry criteria:** a GitHub repo exists for this project (this chapter's whole point is PR-triggered `plan` and merge-triggered `apply`, so there needs to be somewhere for that to happen); Chapters 3–4's modules and environment configs are in a state worth automating.
- **Exit criteria:** a PR against this repo produces a posted `terraform plan` automatically; a merge to `main` triggers `terraform apply` automatically; confirm no long-lived AWS access keys are stored anywhere (GitHub secrets, local files) — auth is via OIDC role assumption only.
- **Cost checkpoint:** no new AWS infra cost beyond the IAM OIDC provider/role (free) — but this is the point where accidental applies become easier to trigger automatically, so be deliberate about what's in `main` before wiring this up.
- **Open decisions:** none — OIDC-based auth is the fixed approach per the README (no long-lived credentials).

---

## 4. Session discipline (repeat every working session)

`terraform plan` → review the diff → `terraform apply` → manually verify the chapter's stated outcome (load the URL, check a security group, confirm a secret isn't in state in plaintext, etc.) → note anything learned or surprising → `terraform destroy` before ending the session — **unless** intentionally leaving something up because the next session's chapter builds directly on top of it (e.g. Chapter 1's bucket feeding into Chapter 2).

---

## 5. Summary of open decisions to carry forward

| Decision | Where it's made | Current recommendation |
|---|---|---|
| Default AWS region | Before Chapter 1 | `us-east-1` |
| Repo layout (per-chapter dirs vs. shared modules) | Before Chapter 3 | Per-chapter dirs for Ch.1–2, shared `modules/` from Ch.3 on |
| ACM cert domain | Chapter 2 | CloudFront default domain (Route 53 out of scope) |
| Environment separation strategy | Chapter 4 | Folder-per-environment first, workspaces as a follow-up comparison |
