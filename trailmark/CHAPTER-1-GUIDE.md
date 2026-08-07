# Chapter 1 Guide — The Launch Page

This is a coaching guide, not a code drop. It won't hand you finished `.tf` files — it names the concepts and resources you need and explains why they matter, and you write the actual HCL. You already know AWS, so the focus here is Terraform mechanics: how HCL is structured, how state works, and the gotchas specific to this provider.

**Goal (from README.md):** a static site live on an S3 website endpoint — public bucket policy, HTML/CSS content, nothing dynamic.

---

## 0. Working directory

Create `trailmark/chapter-1-launch-page/` yourself and do all work for this chapter inside it. Per `PLANNING.md`, chapters 1–2 are self-contained root configs (no shared modules yet).

---

## 1. Providers — the thing that talks to AWS

Two pieces, usually split into a `versions.tf`:

- A `terraform` block with `required_providers`, pinning the AWS provider to a version constraint (e.g. `~> 5.0`). This is what makes `terraform init` know what to download.
- A `provider "aws" { }` block, which is where the region gets configured. Since you already have AWS CLI credentials configured, you don't need to pass credentials here at all — the provider will pick them up from your default credential chain (env vars, `~/.aws/credentials`, or SSO profile). Don't hardcode credentials into this file, ever.

**Why version pinning matters:** without it, `terraform init` grabs whatever's latest, and a provider major-version bump can silently change resource schemas out from under you (this actually happened to the S3 website-config resource — see the gotchas section). Pin it.

---

## 2. Resources — what you're actually declaring

General shape: `resource "<type>" "<local_name>" { ... }`. The type is fixed by the provider; the local name is yours, used to reference the resource elsewhere in your config (e.g. `aws_s3_bucket.site.id`).

For this chapter you need five resources, in this rough dependency order:

1. **`aws_s3_bucket`** — the bucket itself. Needs a globally-unique name (S3 bucket names are global across all AWS accounts, not just yours).
2. **`aws_s3_bucket_public_access_block`** — by default, AWS blocks public bucket policies at the account/bucket level regardless of what policy you attach. You must explicitly set this resource's four boolean flags to allow a public policy through, *before* your policy will actually take effect. This trips up almost everyone the first time — if your bucket policy applies cleanly but the site still 403s, this is the first thing to check.
3. **`aws_s3_bucket_website_configuration`** — turns the bucket into a website endpoint, with an `index_document` and `error_document` block. **Gotcha:** older Terraform/S3 tutorials configure a `website { }` block directly inside `aws_s3_bucket`. That was removed in AWS provider v4 — website config is now its own separate resource, referencing the bucket by ID. If you're looking at an old blog post and it looks like a one-block solution, that's why it won't apply cleanly.
4. **`aws_s3_bucket_policy`** — a JSON IAM policy granting `s3:GetObject` to `*` (public) on the bucket's objects. Note the resource ARN needs to target the objects, not just the bucket — that means appending `/*` to the bucket ARN in the policy's `Resource` field. You can write the JSON inline as a string, or build it with Terraform's `jsonencode()` function and the `data "aws_iam_policy_document"` data source — worth trying the latter once, since data sources come back in Chapter 2.
5. **`aws_s3_object`** — one resource per file you upload (or looped with `for_each` over a fileset — up to you how far to take this in Chapter 1). Set `content_type` explicitly (e.g. `text/html`, `text/css`) — S3 doesn't guess this from the extension, and a wrong/missing content type makes browsers download the file instead of rendering it.

---

## 3. Input variables

A `variable "name" { type = ..., default = ... }` block declares an input; you reference it elsewhere as `var.name`. Good candidates to parameterize in this chapter rather than hardcode:

- the bucket name (so it's not buried in a resource block)
- the AWS region
- the index/error document filenames

You don't need a `terraform.tfvars` file yet if defaults are reasonable — that becomes more important starting Chapter 4.

---

## 4. Outputs

An `output "name" { value = ... }` block surfaces a value after apply, both in the CLI output and via `terraform output`. Worth outputting here: the bucket's website endpoint (`aws_s3_bucket_website_configuration` exposes this as an attribute) — that's the URL you'll actually open in a browser to verify things worked.

---

## 5. The init → plan → apply → destroy lifecycle

- **`terraform init`** — downloads the provider plugin per your version constraint, sets up the local `.terraform/` directory. Run it once at the start, and again any time you change provider requirements or backend config.
- **`terraform plan`** — computes a diff between your config and the current state (right now, no state yet, so everything shows as a create). Read it before applying — check resource counts and that nothing unexpected is being replaced/destroyed.
- **`terraform apply`** — re-runs plan, shows you the same diff, asks for confirmation (`yes`), then executes. State (`terraform.tfstate`) gets written locally in this chapter — remote state doesn't arrive until Chapter 2.
- **`terraform destroy`** — reverse of apply. Run this when you're done verifying, to avoid leaving billable resources up per the cost-discipline note in `PLANNING.md` (S3 is cheap, but it's still the right habit to build now).

---

## 6. Suggested step order

1. `mkdir trailmark/chapter-1-launch-page && cd` into it
2. Write `versions.tf` (required_providers + provider block)
3. `terraform init`
4. Write `variables.tf`
5. Write the five resources (bucket → public access block → website config → bucket policy → objects)
6. Write `outputs.tf`
7. Create actual `index.html` / `error.html` / (optionally) a CSS file as local content files referenced by the `aws_s3_object` resources
8. `terraform plan` — read it end to end before proceeding
9. `terraform apply`
10. Open the website-endpoint output URL in a browser — confirm it actually loads
11. `terraform destroy` once you're satisfied

---

## 7. Checkpoints — pause and answer before moving on

- Before writing the bucket policy: what would happen if you attached this policy *without* first configuring the public access block? (Then go verify you were right.)
- After your first successful `apply`: run `terraform plan` again with no config changes — what does it report, and why should it report that?
- Before `destroy`: what specifically in your state file/config would break if two people ran `apply` from their own laptops against this same config right now? (You don't need to fix this yet — Chapter 2 is the answer — just be able to name the problem.)

---

## 8. Definition of done

- Site loads over plain HTTP at the S3 website endpoint shown in your `terraform output`.
- You've run the full `init → plan → apply → destroy` cycle at least once, and can explain what each command did.
- You can explain, in your own words: what a provider is, what a resource block declares, the difference between a variable and an output, and why the public-access-block + website-config gotchas above exist.
- Resources destroyed (or intentionally left up only because you're moving straight into Chapter 2, which builds on this bucket).
