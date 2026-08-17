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

## 2. Repo layout **(decided — every chapter is fully independent)**

The README frames later chapters as reusing earlier work (e.g. "Chapter 4 reuses Chapter 3's modules verbatim"), but the operating principle for this project is stronger than that: **each chapter is its own self-contained learning project.** No chapter's Terraform config ever references another chapter's directory, state, or resources — not via module `source`, not via remote state data sources, nothing. If a later chapter needs something an earlier chapter already built (like a VPC, or a set of modules), it gets its **own independent copy**, even if that means writing or copying the same thing twice.

This is a deliberate trade-off against the DRY instinct real teams would apply — and that's fine, because the goal here isn't the leanest possible repo, it's that any single chapter can be opened, understood, and worked on in total isolation, with nothing elsewhere in the repo required to make sense of it.

**Consequences of this, concretely:**
- Chapters 1–2: already independent — Chapter 2 redeclares its own S3 bucket and content rather than reaching into Chapter 1's, exactly per this principle (see Chapter 2's guide for the reasoning).
- Chapter 3: its three modules live **nested inside its own directory** — `chapter-3-trail-search/modules/{network,app-tier,db-tier}` — never at a shared top-level `modules/`.
- Chapter 4: gets its **own** independent copy of equivalent modules, inside its own directory tree — not sourced from Chapter 3 in any way. Its single root config (`chapter-4-envs/workspace-lab/`) reaches those modules via `../modules/...`, which stays inside the chapter and so respects this principle. See Chapter 4's entry below.

---

## 3. Per-chapter roadmap

### Chapter 1 — The Launch Page
- **Entry criteria:** prerequisites in §1 done; region and repo layout confirmed.
- **Exit criteria:** site reachable on its S3 static-website endpoint; `providers` / `resources` / `variables` / `outputs` / full `init → plan → apply → destroy` cycle all exercised and understood.
- **Cost checkpoint:** negligible (S3 storage + requests). Destroy when done — per §2, Chapter 2 doesn't depend on this stack still being up.
- **Open decisions:** none beyond region/layout (§1–2).

### Chapter 2 — Real Traffic, Real Speed (CDN + HTTPS)
- **Entry criteria:** prerequisites in §1 done. Per §2's independence principle, this chapter declares its **own** S3 bucket and content rather than reusing Chapter 1's — Chapter 1 does not need to still be up (or to have ever been applied) to start this chapter.
- **State backend bootstrap wrinkle (decided, flagged early on purpose):** the S3 bucket used for remote state has to be created *somehow* — via a small local-state config — before the "real" Chapter 2 config can point its backend at it. Treat this as a mini-step at the very start of the chapter, not a surprise partway through.
- **Exit criteria:** site served over HTTPS via CloudFront, S3 no longer publicly reachable directly (verify by trying the raw bucket URL and confirming it's blocked), state now lives in S3 with native S3 locking (`use_lockfile = true`) confirmed (e.g. by observing lock behavior during a deliberate concurrent `plan`).
- **Cost checkpoint:** CloudFront + S3 are both low-cost but not free if left running indefinitely — fine to leave up longer than Chapter 1 given the setup cost of remote state, but don't forget about it.
- **Open decisions:**
  - ACM cert domain: placeholder/self-managed domain vs. CloudFront's default domain **(decided by README — Route 53 is out of scope, so default to CloudFront's own domain unless you specifically want to practice a placeholder cert)**.
  - State locking mechanism: DynamoDB table vs. native S3 locking **(decided — using native S3 locking via `use_lockfile = true`, no DynamoDB table. This is the newer approach, available since Terraform 1.10; the README's original wording assumed the older DynamoDB pattern, which is still the more common one in existing real-world codebases but is no longer the recommended default for new configs)**.

### Chapter 3 — The Trail Search Feature (3-Tier Architecture)
- **Entry criteria:** budget alarm from §1 confirmed active (this is where cost risk starts for real); repo layout decision from §2 confirmed.
- **Exit criteria:** ALB reachable on 80 from the internet (see Chapter 3's guide §3 for why 443 wasn't viable without Route 53/ACM); app tier reachable only from the ALB's security group; RDS reachable only from the app tier's security group on 5432; DB credentials confirmed to live in Secrets Manager, not in `.tf` files or state-visible variables; each module (`network`, `app-tier`, `db-tier`) exercised with its own inputs/outputs.
- **Cost checkpoint — the big one:** NAT Gateway (hourly + per-GB charge) and RDS are the most expensive resources in the whole project. Plan to `terraform destroy` promptly once verification is done, rather than leaving this stack up between sessions.
- **Open decisions:**
  - DB isolation rule: none — fixed by the engineering-lead constraint in the README, not a tradeoff to explore.
  - Module location **(decided — nested inside `chapter-3-trail-search/modules/`, not a shared top-level `modules/`. See §2.)**
  - NAT Gateway count **(decided — one per AZ, matching real HA practice, at roughly double the cost of a single shared gateway for however long the stack is up)**.

### Chapter 4 — "We Broke Prod Again" (Environments)
- **Entry criteria:** Chapter 3 complete and understood (its modules are a *reference*, not a dependency — this chapter does not source anything from `chapter-3-trail-search/`).
- **Module independence (decided, per §2):** this chapter builds its **own** copy of the network/app-tier/db-tier modules, inside its own directory tree, entirely independent of Chapter 3's. Whether you copy Chapter 3's module files over as a starting point or write them fresh is your call when you get there — either way, `chapter-4-.../` must stand on its own with nothing sourced from `chapter-3-trail-search/`.
- **Environment separation (decided — Terraform workspaces, no `environments/` directory):** the chapter has one root config, `chapter-4-envs/workspace-lab/`, with `dev` and `prod` as Terraform workspaces. Folder-per-environment was rejected: `environments/dev/main.tf` and `environments/prod/main.tf` would have been byte-identical except for module `source` paths, with all real difference living in `.tfvars` — duplication carrying no Terraform concept the workspace version doesn't already exercise. The comparison the README asks for is satisfied in writing (Chapter 4 guide §6) rather than by building both.
- **What that choice costs:** with no directory to anchor identity, the config has *two* independent selectors — `terraform workspace select` (state + `Environment` tag) and `-var-file` (resource names + sizing) — which can silently disagree. This is not theoretical: `workspace-lab/errored.tfstate` holds `chapter-4-dev-*` resources while `.terraform/environment` reads `prod`. See Chapter 4 guide §3.
- **Exit criteria:** dev and prod both stood up from this chapter's own modules at different sizes, with separate state; `single_nat_gateway` differing between environments as the worked example of environment-driven conditional sizing; the folder-per-environment trade-off argued in writing.
- **Status — substantially complete.** Both environments applied and verified against real AWS: each ALB returned `HTTP 200` on `/health`; dev's two app subnets shared a single NAT Gateway through the module's fallback lookup; prod's each routed to a gateway in its own AZ, confirmed HA-correct by comparing subnet and gateway availability zones. State migrated to key `chapter-4-envs/terraform.tfstate`, separated per workspace under the `env:/` prefix, with the pre-migration objects removed. Remaining: the guide §6 write-up.
- **What varies between environments** (all in `.tfvars`; no environment-conditional logic inside `modules/`): `instance_type`; `asg_min_size` / `asg_max_size` / `asg_desired_capacity`; `single_nat_gateway` (dev shares one gateway, prod runs one per AZ); `recovery_window_in_days` (dev `0` for fast iteration, prod `30` for recoverability); and `db_instance_class` (parameterized but deliberately identical in both — a real prod would size up, but RDS is one of the project's two most expensive resources).
- **Cost checkpoint:** effectively double Chapter 3's cost if both workspaces are up simultaneously — favor applying one, verifying, destroying, then the other. Measured at roughly $0.25/hr with both up. `single_nat_gateway` keeps dev to a single NAT Gateway — the chapter's largest line item — while prod runs one per AZ.
- **Open decisions:** none remaining. Sizing stays in `dev.tfvars` / `prod.tfvars` passed via `-var-file`, rather than moving to a `local` map keyed by `terraform.workspace`. That leaves the two-selector hazard in place **by choice**: the failure mode was hit directly during the chapter, and documenting a sharp edge that's understood was judged more useful here than sanding it off before anyone saw it. Chapter 5 inherits the consequence — see its entry.

### Chapter 5 — "Just Review It Before It Goes Live" (CI/CD)
- **Entry criteria:** a GitHub repo exists for this project (this chapter's whole point is PR-triggered `plan` and merge-triggered `apply`, so there needs to be somewhere for that to happen); Chapter 4's config is in a state worth automating. Note that Chapter 4's workspace-based structure makes this chapter's job harder in a specific way: a workflow can't infer the target environment from a changed directory path, so the workspace has to be selected explicitly per job — and getting that wrong in CI applies to the wrong environment with no human in the loop. Plan for the workflow to assert `terraform workspace show` matches its intended target before any `apply`.
- **Exit criteria:** a PR against this repo produces a posted `terraform plan` automatically; a merge to `main` triggers `terraform apply` automatically; confirm no long-lived AWS access keys are stored anywhere (GitHub secrets, local files) — auth is via OIDC role assumption only.
- **Cost checkpoint:** no new AWS infra cost beyond the IAM OIDC provider/role (free) — but this is the point where accidental applies become easier to trigger automatically, so be deliberate about what's in `main` before wiring this up.
- **Open decisions:** none — OIDC-based auth is the fixed approach per the README (no long-lived credentials).

---

## 4. Session discipline (repeat every working session)

`terraform plan` → review the diff → `terraform apply` → manually verify the chapter's stated outcome (load the URL, check a security group, confirm a secret isn't in state in plaintext, etc.) → note anything learned or surprising → `terraform destroy` before ending the session.

**Two operational lessons learned the hard way in Chapter 4, applicable to every chapter that uses Secrets Manager or a remote backend:**

- **`destroy` does not free a Secrets Manager name.** It schedules the secret for deletion and reserves the name for the recovery window (default 30 days). The next `apply` then fails *partway through* — after the VPC, NAT Gateway, and RDS instance are already billing. Set `recovery_window_in_days = 0` anywhere you expect to apply/destroy repeatedly, and clear an existing tombstone with `aws secretsmanager delete-secret --force-delete-without-recovery`.
- **A failed `apply` is not a no-op.** Terraform applies incrementally, so a mid-run failure leaves real resources running and billing. Always check what actually exists after an error rather than assuming a failed run cost nothing — and check in the right region: a wrong `aws configure` default silently reports an empty account. Per §2's independence principle, no chapter depends on another chapter's live infrastructure, so there's no "leave it up for the next chapter" exception here — every chapter can be destroyed the moment you're done verifying it, with nothing else in the repo affected.

---

## 5. Summary of open decisions to carry forward

| Decision | Where it's made | Current recommendation |
|---|---|---|
| Default AWS region | Before Chapter 1 | `us-east-1` |
| Repo layout | Before Chapter 1 (decided) | Every chapter fully independent — no chapter directory ever references another's (§2) |
| ACM cert domain | Chapter 2 | CloudFront default domain (Route 53 out of scope) |
| State locking mechanism | Chapter 2 | Native S3 locking (`use_lockfile = true`), no DynamoDB table |
| Module location | Chapter 3 | Nested in `chapter-3-trail-search/modules/`, own copy, not shared |
| NAT Gateway count | Chapter 3 | One per AZ (HA-correct, ~2x cost of a single shared gateway) |
| Environment separation strategy | Chapter 4 (decided) | Terraform workspaces in one root config. No `environments/` directory — folder-per-environment rejected as near-duplicate code; the comparison is argued in writing instead (guide §6) |
| Environment selector | Chapter 4 (decided) | Two selectors kept — `terraform workspace select` for state, `-var-file` for sizing. The hazard is accepted and documented rather than fixed (guide §3, §6) |
| Environment-varying inputs | Chapter 4 (decided) | `instance_type`, ASG min/max/desired, `single_nat_gateway`, `recovery_window_in_days`, `db_instance_class` — all in `.tfvars`, none conditional inside `modules/` |
| Module sourcing for dev/prod | Chapter 4 | Chapter 4's own independent copy of the modules — nothing sourced from Chapter 3 |
