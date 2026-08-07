# Chapter 2 Guide — Real Traffic, Real Speed (CDN + HTTPS)

Same format as Chapter 1: concepts and resource names, no ready-to-paste HCL. You already know the mechanics of providers/resources/variables/outputs from Chapter 1 — this guide leans on that and focuses on what's new: data sources, remote state, and the trickiest part of this chapter, which is that **CloudFront + a private bucket via OAC is architecturally different from Chapter 1's setup**, not just an addition on top of it.

**Goal (from README.md):** the same site, now served over HTTPS via CloudFront, with the S3 bucket no longer directly public — only CloudFront can read from it.

---

## 0. Working directory, and why the bucket gets redeclared

Create `trailmark/chapter-2-cdn-https/`, per `PLANNING.md`'s layout decision. Per that decision, Chapters 1–2 are independent self-contained configs, not one evolving config. That means **this chapter redeclares its own `aws_s3_bucket` and re-uploads the same frontend content**, rather than reaching into Chapter 1's state. In a real long-lived project you'd evolve one config over time instead of duplicating it — we're intentionally trading that realism for chapter independence here, per the layout decision already on record. Worth understanding *why* that trade-off was made, not just copying the pattern blindly.

Practical implication: pick a new, distinct bucket name for this chapter (bucket names are still globally unique — reusing Chapter 1's exact name will collide if Chapter 1's bucket wasn't destroyed).

---

## 1. The domain/ACM decision (already effectively made for you)

The README mentions a placeholder domain as an option for the ACM certificate. In practice this isn't viable without Route 53 (or some other DNS you control): ACM certificate validation requires proving domain ownership via a DNS record, and Route 53 is explicitly out of scope until a later "Chapter 2.5." So for this chapter: **use CloudFront's default `*.cloudfront.net` domain and skip ACM entirely.** CloudFront's default domain already serves HTTPS out of the box via AWS's own managed certificate — you don't create any `aws_acm_certificate` resource this chapter. That's a real simplification, not a shortcut you're missing out on unfairly; ACM + custom domains becomes relevant once Route 53 enters the story.

---

## 2. The big gotcha: website endpoint vs. REST origin

This is the part most likely to eat your time, so read it before writing anything.

Chapter 1's bucket used **website hosting mode** (`aws_s3_bucket_website_configuration`), accessed via the special `bucket.s3-website-<region>.amazonaws.com` endpoint. That endpoint only supports anonymous HTTP(S) requests — it has no concept of SigV4-signed requests, which is exactly the mechanism Origin Access Control (OAC) uses to let CloudFront (and only CloudFront) read from an otherwise-private bucket.

**Consequence: OAC cannot front a website-hosting-mode endpoint.** For this chapter, CloudFront's origin must instead be the bucket's regular **REST/regional endpoint** (the `bucket_regional_domain_name` attribute on `aws_s3_bucket`), configured as an S3 origin, not a custom/website origin. You still create the bucket the same way, but you do **not** need `aws_s3_bucket_website_configuration` in this chapter — CloudFront takes over the job of "what to serve at `/`" and "what to serve on errors" itself, via its own settings (see §5).

If you find yourself trying to point CloudFront's origin at the `s3-website-*` endpoint to keep index/error document behavior "like before," that's the sign to stop and re-read this section — it won't work with OAC, and it's the single most common wrong turn in this chapter.

---

## 3. Remote state — a bootstrap step before the "real" config

Per `PLANNING.md`, this is the wrinkle worth expecting: the S3 bucket + DynamoDB table that will hold your remote state have to exist *somehow* before you can configure a backend that points at them — and Terraform can't use a backend to create the thing the backend depends on.

Practical approach: create a small, separate, throwaway-ish config (e.g. `trailmark/state-backend/`) with its own local state, containing just:
- one `aws_s3_bucket` for state storage (with versioning enabled — worth looking up why that matters for state files specifically)
- one `aws_dynamodb_table` for locking, with a partition key named `LockID` (string type) — this exact name is required by Terraform's S3 backend locking mechanism, not a convention you can rename freely

Apply that once, note the bucket/table names, then move on. This mini-stack is intentionally long-lived — unlike your chapter stacks, don't destroy this one casually, since destroying it mid-project would strand your remote state.

---

## 4. Concept: remote backends and state locking

Once the backend infra exists, `chapter-2-cdn-https/` gets a `terraform { backend "s3" { ... } }` block (bucket, key, region, and `dynamodb_table` for locking). Two mechanics worth understanding, not just configuring:

- **Why remote state at all:** local `terraform.tfstate` (what Chapter 1 used) works fine solo, but breaks down the moment a second person or a CI runner needs to `plan`/`apply` against the same infrastructure — everyone needs to see the *same* current state, not their own local copy.
- **Why locking specifically:** two simultaneous `apply` runs against the same state file, without locking, can corrupt it or apply conflicting changes. The DynamoDB table exists purely to hold a lock record during operations — you can literally watch an item appear in that table mid-`apply` if you want to see it happen.

Switching a config from local to remote backend requires `terraform init -migrate-state` (not just `init`) — Terraform will ask to copy your existing local state up to the new backend.

---

## 5. Resources you need, and what's new about each

- **`aws_s3_bucket`** — same as Chapter 1, new name/chapter-2 instance.
- **`aws_s3_bucket_public_access_block`** — this time, all four flags should be `true`. Nothing reads this bucket publicly anymore; CloudFront reads it via OAC, which is a different access path entirely (an IAM-policy grant to the CloudFront service principal, not "public").
- **`aws_s3_object`** — same as Chapter 1 (reuse the same `frontend/` content and the extension→content-type lookup pattern you already built).
- **`aws_cloudfront_origin_access_control`** — the OAC itself: an identity CloudFront uses to sign requests to your bucket. Note this is the *modern* replacement for the older Origin Access Identity (OAI) pattern — if you see OAI in older tutorials, that's the deprecated approach; use OAC.
- **`aws_cloudfront_distribution`** — the CDN itself. Key things it needs to declare:
  - an `origin` block pointing at the bucket's `bucket_regional_domain_name`, referencing the OAC's ID
  - `default_root_object = "index.html"` — this replaces the website-config's index-document behavior, since you no longer have that resource
  - a `default_cache_behavior` with `viewer_protocol_policy` set to redirect HTTP→HTTPS (this is where "real HTTPS" actually comes from)
  - a cache policy — rather than hand-rolling cache TTL settings, look up the **`data "aws_cloudfront_cache_policy"`** data source for AWS's managed `CachingOptimized` policy and reference its ID. This is your first real data source in this project: a read-only lookup of something that already exists, rather than a resource you create.
  - a `restrictions` block (geo restriction — `none` is fine here) and a `viewer_certificate` block (since you're using the default domain, this points at `cloudfront_default_certificate = true`, not an ACM ARN)
- **`aws_s3_bucket_policy`** — a new version, different in kind from Chapter 1's. Instead of `Principal = "*"`, the principal is the CloudFront service (`cloudfront.amazonaws.com`), and — importantly — a `Condition` block restricting `AWS:SourceArn` to this specific distribution's ARN. Without that condition, you'd be granting *any* CloudFront distribution in *any* AWS account read access, not just yours.

**Concept: implicit dependency ordering.** This bucket policy references `aws_cloudfront_distribution.<name>.arn` inside its policy document. That reference is enough for Terraform to know the distribution must be created first — no explicit `depends_on` needed here, unlike the access-block/policy ordering back in Chapter 1. Good moment to notice the difference between a dependency Terraform infers from a reference, and one you have to declare by hand.

---

## 6. Suggested step order

1. Build and apply the one-time `state-backend/` bootstrap stack (§3) — do this once, leave it running.
2. Create `chapter-2-cdn-https/`, write `versions.tf`/`provider.tf` as before.
3. `terraform init`
4. Write the bucket + public access block + objects (reusing Chapter 1 patterns, tightened per §5).
5. Write the OAC resource.
6. Write the CloudFront distribution, including the `data "aws_cloudfront_cache_policy"` lookup.
7. Write the new CloudFront-scoped bucket policy.
8. `terraform plan` — read it carefully; CloudFront resources take a while to show in plan and even longer to actually deploy (10-15+ minutes is normal for CloudFront, unlike S3).
9. `terraform apply` — be patient; this is the first resource in the project that's genuinely slow to create, and that's expected (not the same as the S3 hang from Chapter 1).
10. Verify over HTTPS at the distribution's domain name.
11. Now add the backend block and run `terraform init -migrate-state` to move this chapter's state to S3+DynamoDB.
12. Verify locking: kick off an `apply` and, from a second terminal, try a `plan` — you should see it wait/report a lock held.

---

## 7. Checkpoints

- Before writing the new bucket policy: why does `Principal = "cloudfront.amazonaws.com"` alone, without the `SourceArn` condition, not achieve what you want?
- After deploying: try opening the bucket's REST endpoint directly in a browser (`https://<bucket>.s3.amazonaws.com/index.html`) — it should now fail. What specifically about the setup causes that, when it worked in Chapter 1?
- After migrating state: open `chapter-2-cdn-https/terraform.tfstate` locally (or note that it's now basically empty/a pointer) — where does the real state live now, and what does the DynamoDB table actually store (hint: not the state itself)?

---

## 8. Definition of done

- Site loads over HTTPS at the CloudFront distribution's default domain.
- Direct requests to the S3 bucket (REST endpoint) are refused.
- State lives in S3 with DynamoDB locking, migrated via `-migrate-state`, and you've observed a lock in action.
- You can explain: why OAC requires abandoning the website-hosting endpoint, what a data source is and why `aws_cloudfront_cache_policy` is one, and the difference between an implicit dependency (via reference) and an explicit one (`depends_on`).
