# Landing Zone Lite: Learning AWS Multi-Account Governance with Terraform

A small, self-contained AWS multi-account foundation, built to learn the identity, governance, and audit patterns that sit underneath any real company's cloud environment — before a single workload gets deployed into it.

## Why this project exists

Most learning projects jump straight to "build an app." This one deliberately doesn't. Before any application matters, someone has to answer a smaller, less glamorous set of questions: who is allowed to do what, across how many accounts, enforced how, and audited how. Get this wrong and every application built on top of it inherits the mistake. Get it right once, at the foundation, and every workload dropped into it inherits the guardrails automatically.

That's the actual subject of this project: not a product, but the governed foundation a product would later stand on.

Where [Trailmark](../trailmark/) teaches Terraform by growing one account's workload — S3, then CDN, then VPC and databases, then CI/CD — this project teaches the layer underneath: Organizations, cross-account IAM, and org-wide policy. The two share no code, modules, or state. They're separate on purpose, and each is independently understandable without the other still standing.

## What gets built

A minimal but real AWS Organizations structure: one security account and two workload accounts (`workload-dev` and `workload-prod`), sitting under an OU structure that enforces guardrails at the organizational level rather than per-account. Centralized logging that workload accounts can't tamper with. A cross-account identity that can look, but not touch. And, as the payoff at the end, a small Lambda-based compliance scanner that uses that identity to actually check the workload accounts for common misconfigurations and report on what it finds.

Everything is built with Terraform. Nothing is clicked into existence through the console and left undocumented.

## The chapters

Each chapter builds on the one before it, and each ends with a check you can actually run rather than a resource you merely created. The order isn't arbitrary: you need accounts before you can have an identity that crosses them, an identity before you can prove a guardrail didn't block it, and all three before a scanner has anything to scan.

---

### Chapter 1 — Org Foundation

**Trigger:** There's nothing to govern yet. Before any policy or identity work, there have to be accounts to apply it to — and creating them by hand in the console is exactly the habit this project exists to avoid.

**Architecture:**
- An AWS Organization with all features enabled (not just consolidated billing — SCPs in Chapter 3 require this)
- An OU structure separating the security account from workload accounts
- Member accounts provisioned as code, placed into their OUs at creation
- A naming and tagging convention applied from the first resource rather than retrofitted

**Terraform concepts:**
- `aws_organizations_organization`, `aws_organizations_organizational_unit`, `aws_organizations_account`
- Provider configuration and the management-account credential boundary
- Variables and outputs — account IDs become inputs to every later chapter
- `default_tags` at the provider level, so tagging is structural rather than per-resource discipline

**Done when:** `terraform apply` creates the accounts and OUs from scratch, and the account IDs are exposed as outputs the later chapters consume.

---

### Chapter 2 — Security & Audit Identity

**Trigger:** The accounts exist and are isolated, which means nothing in the security account can see into them. Isolation without a deliberate, narrow path across it isn't security — it's just blindness.

**Architecture:**
- A cross-account IAM role in each workload account, assumable only by the security account
- A trust policy scoped to a specific principal, not a whole account wildcard
- A permissions policy that is genuinely read-only — the point is proving the boundary holds, not granting convenience
- The role assumed for real from the security account, not assumed to work

**Terraform concepts:**
- `aws_iam_role`, trust policies vs. permissions policies, and why they're separate documents
- `aws_iam_policy_document` data sources instead of inline JSON heredocs
- Provider aliases with `assume_role` — one Terraform run acting in several accounts
- `for_each` over the workload accounts, so adding a fourth account is a variable change

**Done when:** you can assume the auditor role from the security account, successfully list resources in a workload account, and get an explicit `AccessDenied` on a write.

---

### Chapter 3 — Guardrails via SCP

**Trigger:** The auditor role proves you can watch the workload accounts. It doesn't stop anyone in them from doing something you'd rather they couldn't — including an admin with full IAM rights in their own account.

**Architecture:**
- Service Control Policies attached at the OU level, not to individual accounts
- A guardrail set worth defending: deny leaving the organization, deny disabling CloudTrail, deny region use outside an approved list
- A deliberate test of inheritance — an account created *after* the SCP exists, placed under the OU, and found to be governed with no extra action

**Terraform concepts:**
- `aws_organizations_policy` and `aws_organizations_policy_attachment`
- Policy inheritance and evaluation: why an SCP is a ceiling on permissions rather than a grant
- Attachment targets as the unit of reuse — the difference between governing a group and governing a list

**Done when:** an action allowed by a workload account's own IAM is still denied by the SCP, and a newly created account inherits that denial without being touched.

---

### Chapter 4 — Centralized Logging

**Trigger:** The guardrails prevent some things and permit the rest. Everything permitted still needs a record — and a record that the account being recorded can edit is not evidence.

**Architecture:**
- An organization-wide CloudTrail trail, created once in the management account, covering every member account including future ones
- Delivery to a locked-down S3 destination in the security account
- A bucket policy and public access block that let workload accounts write but never read, alter, or delete
- Log file validation enabled, so tampering is detectable rather than merely discouraged

**Terraform concepts:**
- `aws_cloudtrail` with `is_organization_trail`, and why it must be created from the management account
- Resource-based policies as an access boundary distinct from IAM
- `aws_s3_bucket_policy`, `aws_s3_bucket_public_access_block`, and lifecycle rules for log retention cost
- Service principals as trusted writers

**Done when:** an API call made in a workload account appears in the security account's bucket, and an attempt to delete that object from the workload account fails.

---

### Chapter 5 — Compliance Scanner

**Trigger:** Four chapters of foundation exist and nothing has yet used them together. This is the payoff: a thing that only works *because* the identity, the guardrails, and the logging are all in place.

**Architecture:**
- A scheduled Lambda in the security account
- It assumes the Chapter 2 auditor role into each workload account in turn
- It checks a defined set of misconfigurations: publicly readable S3 buckets, security groups open to `0.0.0.0/0`, and root account activity found in the Chapter 4 trail
- It reports findings — the standalone, demoable use case the whole foundation exists to support

**Terraform concepts:**
- `aws_lambda_function` with the `archive_file` data source for packaging
- EventBridge scheduling as infrastructure rather than a cron line on a server
- An execution role whose only real power is `sts:AssumeRole` into accounts it doesn't own
- Iterating infrastructure over a data structure — the account list drives the scan targets

**Done when:** the scanner runs on schedule, deliberately misconfigured resources in a workload account are reported, and the same scan finds nothing to report after they're fixed.

---

## Summary

| Chapter | Trigger | New AWS Services | Core Terraform Concepts |
|---|---|---|---|
| 1 | Nothing exists to govern | Organizations, OUs, member accounts | resources, variables/outputs, `default_tags` |
| 2 | Isolation means blindness | IAM cross-account roles, STS | policy documents, provider aliases, `assume_role`, `for_each` |
| 3 | Watching isn't preventing | Service Control Policies | policy attachment, inheritance, org-level targeting |
| 4 | Permitted actions need evidence | CloudTrail (org trail), S3 | resource-based policies, service principals, lifecycle rules |
| 5 | Make the foundation do something | Lambda, EventBridge | packaging, execution roles, iterating over accounts |

## What this project deliberately leaves out

**AWS Control Tower** is out of scope. It automates a lot of what this project builds by hand, but it also provisions real, non-trivial infrastructure that costs money to leave running. Building the pieces manually here is slower but teaches the mechanics Control Tower would otherwise hide.

**A fully separate logging account** is also out of scope, as a stated simplification rather than an oversight. A production landing zone typically isolates logging into its own account, separate from security tooling. Here, logging lives inside the same security account as the auditor role, to keep the account count — and the cost and cleanup burden — smaller for a learning project. This trade-off is worth being able to explain, not hide.

## Before starting

- Terraform and the AWS CLI installed
- Credentials for an account that is (or can become) an Organizations **management account** — this is a higher bar than the usual sandbox admin, and Chapter 1 can't start without it
- A working email address scheme for member accounts. Each AWS account needs a unique one; the `you+workload-dev@example.com` subaddressing trick is the usual answer
- A decision on state. Chapter 1 can run with local state, but every later chapter consumes Chapter 1's outputs, so a remote backend is worth setting up before the account IDs only exist on one laptop

## A note on cost and cleanup

Creating AWS accounts under an Organization is straightforward; closing them is not instant — expect a waiting period once an account is no longer needed. Decide up front whether you're committing to keeping any accounts created here, or reusing existing sandbox accounts instead. Nothing here should be left running indefinitely between sessions — most of what's built is low-cost, but the discipline of applying, verifying, and tearing back down is worth carrying over regardless of the actual dollar amount.

## Status

Planning stage. The chapters and their exit criteria are defined above; no Terraform has been written yet. Chapter 1 is the entry point.
