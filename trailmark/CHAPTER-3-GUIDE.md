# Chapter 3 Guide — The Trail Search Feature (3-Tier Architecture)

Same format as before: concepts and resource names, no ready-to-paste HCL, you write the actual code. This is a genuinely bigger jump than Chapters 1–2 — first real VPC, first modules, first multi-resource security boundary, first serious cost risk. Take it in pieces (§6 gives a build order that verifies the network layer before adding compute and data on top of it).

**Goal (from README.md):** a public ALB, private app-tier EC2 instances in an Auto Scaling Group, and an RDS Postgres instance that is unreachable from the internet by any path — direct or indirect — except through the app layer.

**Decisions already made for this chapter:**
- You're writing the app-tier stub yourself (a process that listens on a port and responds to a health-check path) — the guide describes what's structurally needed, not the app code.
- NAT Gateway: one per AZ, matching real high-availability practice. This roughly doubles the NAT cost of a single shared gateway for however long you leave this stack up — factor that into how long you let it run.

---

## 0. Working directory and module layout

Per the updated decision in `PLANNING.md`, Chapter 3 stays fully self-contained — modules live nested inside this chapter's own directory, not shared at the `trailmark/` top level yet. Create:

- `trailmark/chapter-3-trail-search/` — the root config
- `trailmark/chapter-3-trail-search/modules/network/`
- `trailmark/chapter-3-trail-search/modules/app-tier/`
- `trailmark/chapter-3-trail-search/modules/db-tier/`

(All `module "..." { source = "./modules/network" ... }`-style references in the root config are relative to this directory, not the `trailmark/` root.) Chapter 4 is where these modules either get promoted to a shared top-level `modules/` or referenced from outside — not a concern for this chapter.

---

## 1. Concept: modules

A module is just a directory of `.tf` files, called from elsewhere via a `module "name" { source = "../modules/whatever", ... }` block. Two things make it a *reusable* module rather than just "code in a different folder":

- **Input variables** — same `variable` blocks you already know, but now they're the module's public interface. The root config passes values in as arguments inside the `module` block.
- **Outputs** — a module's `output` blocks are how it exposes things back to whoever called it (e.g. the network module needs to hand its VPC ID and subnet IDs to the other two modules).

Nothing inside a module can reach outside its own directory except through this input/output contract — a module can't casually reference a resource declared in the root config or in a sibling module. This same input/output contract is also what makes it straightforward for Chapter 4 to build its own equivalent set of modules later — even as an independent copy (per `PLANNING.md`'s independence principle), the *shape* of the contract carries over.

---

## 2. `modules/network` — VPC, subnets, routing, gateways

**Resources you need:**

- **`aws_vpc`** — pick a CIDR block (a `/16` like `10.0.0.0/16` gives plenty of room).
- **Six subnets** across 2 AZs × 3 tiers (web, app, db), each a slice of the VPC CIDR (e.g. `/24`s). This is your first real `for_each` decision — see the gotcha below before choosing `count`.
- **`aws_internet_gateway`**, attached to the VPC.
- **Web route table(s)**: a `0.0.0.0/0` route pointing at the IGW, associated with the two web subnets.
- **`aws_eip`** — one per NAT Gateway (you're doing one per AZ, so two).
- **`aws_nat_gateway`** — one per AZ, each sitting in that AZ's *web* subnet (a NAT Gateway needs a web-tier subnet to live in, even though its job is serving the private subnets).
- **App-tier route table(s)**: one per AZ, each routing `0.0.0.0/0` to that AZ's NAT Gateway, associated with that AZ's app subnet.
- **DB-tier subnets get no default route at all.** No NAT, no IGW, nothing pointing outside the VPC. This is the actual mechanism that makes the database unreachable from the internet — not a security group rule, a routing fact. Worth sitting with that: even if every security group were accidentally left wide open, there is still no network path from the internet to that subnet.

**Gotcha: `count` vs `for_each` for the subnets.** With `count`, subnets are addressed by numeric index (`subnet[0]`, `subnet[1]`, ...). If you ever reorder or remove an entry from the list you're iterating over, Terraform can see that as "index 1 changed" rather than "one specific subnet was removed," and may destroy/recreate resources that didn't actually need to change. `for_each` over a map keyed by something stable (e.g. AZ name, or `"web-a"`/`"app-b"`-style keys) ties each resource to its key rather than its position, which avoids that whole class of surprise. Use `for_each` here.

**Outputs to expose:** VPC ID, and the three subnet-ID collections (web, app, db) — the other two modules need these as inputs.

---

## 3. `modules/app-tier` — ALB, ASG, launch template, security groups

**Security groups (this is the SG-chaining the README calls out):**
- `alb_sg` — ingress from `0.0.0.0/0` on the ALB's listener port (see the port decision below).
- `app_sg` — ingress **only from `alb_sg`'s ID**, not a CIDR range, on whatever port your stub app listens on. This is the pattern to internalize: reference the source security group directly (`security_groups = [aws_security_group.alb_sg.id]`-style), not an IP range. It means "traffic from anything wearing this SG," which stays correct even as instances get replaced and IPs change.

**The ALB listener port decision — a scope call worth understanding, not silently working around.** The README's table says port 443. A real HTTPS listener needs an ACM certificate, and (same as Chapter 2) ACM validation needs a domain you control, which Route 53 being out of scope rules out here too. Recommendation: run the ALB listener on **port 80** for this chapter, and treat "add HTTPS via ACM" as something that becomes natural once Route 53 shows up later — same trade-off Chapter 2 already made for CloudFront, just applied to a different resource this time.

**Launch template — a few things need to come together here:**
- **AMI:** don't hardcode an AMI ID. Use the **`data "aws_ami"`** data source, filtered to the latest Amazon Linux AMI owned by Amazon — your second real data source in this project (after Chapter 2's cache policy), and arguably a more important habit, since a hardcoded AMI ID silently goes stale and eventually gets deprecated out from under you.
- **`instance_type`** — `t3.micro` is a reasonable, cheap default for a learning exercise.
- **`user_data`** — this is where your stub app gets installed/started. Whatever you write needs to end up listening on a port and responding to whatever path you configure as the target group's health check.
- **An IAM instance profile — easy to forget, but required.** Your stub app (eventually) needs to read the DB secret from Secrets Manager at runtime to connect to Postgres. That means the EC2 instances need an `aws_iam_role` (with an EC2 trust policy) + a policy granting `secretsmanager:GetSecretValue`, wrapped in an `aws_iam_instance_profile` referenced by the launch template. Scope the policy's `Resource` to the *specific* secret ARN from the db-tier module's output — not `"*"` — this is the least-privilege checkpoint below.

**Auto Scaling Group:**
- `vpc_zone_identifier` = the app subnet IDs from the network module.
- **`health_check_type = "ELB"`, not the default `"EC2"`.** The default only checks whether the instance itself is running — it has no idea whether your app process actually started or is responding. `"ELB"` makes the ASG defer to the target group's health check results instead, which is the only version of "healthy" that actually means "serving traffic correctly."

**Target group + listener:** target group on your app's port with a health-check path matching what your stub app serves; ALB listener forwarding to it.

**Outputs to expose:** the ALB's DNS name (for testing), and the `app_sg`'s ID (the db-tier module needs it to build the DB security group rule).

---

## 4. `modules/db-tier` — RDS, subnet group, Secrets Manager

- **`db_sg`** — ingress on `5432`, source restricted to the **app tier's security group ID** (passed in as a module input from app-tier's output), same SG-referencing pattern as before.
- **`aws_db_subnet_group`** spanning the two db (isolated) subnets. Note this is required even though you're not using Multi-AZ (see below) — RDS subnet groups always need 2+ AZs represented, regardless of how many the instance actually uses.
- **Secrets Manager, the way the README's module list implies:** generate the password with the **`random_password`** resource (first mentioned back in Chapter 2, unused until now) rather than typing one — nobody, including you, should ever know this password by reading a file. Store it via **`aws_secretsmanager_secret`** + **`aws_secretsmanager_secret_version`**. Feed that same generated value into the RDS instance's `password` argument.

  Worth knowing about, even though the README's structure points at the DIY version above: AWS RDS also supports `manage_master_user_password = true` directly on `aws_db_instance`, which has RDS generate and fully own the secret in Secrets Manager — Terraform never sees the plaintext at all, not even in state. It's arguably the better real-world pattern now, but building the secret yourself (as above) is more valuable *here* since it's what actually teaches you how Secrets Manager and Terraform interact, which is the point of this chapter.

- **`aws_db_instance`** — engine `postgres`, a small instance class (`db.t3.micro` / `db.t4g.micro`), modest storage (e.g. 20GB), the subnet group, `vpc_security_group_ids = [db_sg]`.
  - Set **`publicly_accessible = false`** explicitly. The subnet routing already makes this unreachable from the internet, but this flag is a second, independent layer AWS provides — cheap insurance, and worth forming the habit of setting explicitly rather than relying on routing alone.
  - Set **`multi_az = false`**. Multi-AZ roughly doubles RDS cost by running a live standby replica — not needed to prove this architecture works, and `PLANNING.md` already flags RDS as one of the two big cost risks this chapter.

**Outputs to expose:** the DB endpoint, and the secret's ARN (the app-tier module's IAM policy needs to reference this exact ARN — which means, practically, you'll be wiring db-tier's output back into app-tier's input in the root config, the reverse direction from the SG wiring).

---

## 5. Root config (`chapter-3-trail-search/`) — composing the three modules

This is where the three modules actually get wired together — modules never reference each other directly; all cross-module data flows through the root config passing one module's `output` as another module's input:

- `module "network"` — no dependencies on the other two.
- `module "app_tier"` — needs the network module's VPC ID and subnet IDs, and (per the secret-ARN point above) the db-tier module's secret ARN.
- `module "db_tier"` — needs the network module's VPC ID and db subnet IDs, and the app-tier module's `app_sg` ID.

Notice `app_tier` and `db_tier` end up depending on *each other's* outputs in different directions (app needs the secret ARN, db needs the app SG ID) — Terraform's dependency graph handles this fine since it's tracking individual attribute references, not a strict module-to-module ordering, but it's worth understanding why that isn't circular: the SG-id dependency and the secret-ARN dependency are two separate edges, not a single loop.

---

## 6. Suggested build order — verify incrementally, don't write everything then apply once

Given the cost and complexity here, build and apply in layers rather than writing all three modules and hoping:

1. Write and apply `modules/network` alone (via a minimal root config just calling it). Check the VPC/subnets/route tables in the AWS console — confirm the db subnets genuinely have no route out before building anything on top.
2. Add `modules/app-tier`. Apply. Verify the ALB DNS name serves your stub app's response over plain HTTP.
3. Add `modules/db-tier`. Apply. Verify the app-tier's IAM role can actually read the secret (e.g. from an EC2 instance's own perspective, or by checking the policy is scoped correctly), and that the DB is reachable from an app-tier instance but not from your laptop.
4. Full `terraform destroy` once you're satisfied — don't leave NAT Gateways or RDS running between sessions.

---

## 7. Checkpoints

- Before writing the DB security group rule: why does referencing `app_sg`'s ID instead of a CIDR range matter here specifically, given the app tier's IPs will change every time the ASG replaces an instance?
- After the network module is up, before adding anything else: why do the db subnets need to exist in 2 AZs at all, if `multi_az = false` means only one of them is actually used by RDS?
- Before finishing the IAM policy for Secrets Manager access: what would go wrong, security-wise, if you scoped it to `Resource = "*"` instead of the specific secret ARN?
- After everything's up: try connecting to the RDS endpoint directly from your own laptop (e.g. `psql` or just a plain TCP check) — it should fail/hang. Can you explain exactly which layer is stopping you (routing, security group, or both)?

---

## 8. Definition of done

- ALB reachable on its listener port from the internet, serving your stub app's response.
- App-tier instances reachable only from the ALB's security group — not directly, not from the internet.
- RDS reachable only from the app tier's security group, on `5432` — confirmed unreachable from your own machine.
- DB credentials exist only in Secrets Manager — no plaintext password typed into any `.tf` file or `.tfvars`.
- All three modules (`network`, `app-tier`, `db-tier`) have their own inputs/outputs and are composed, not copy-pasted, in the root config.
- Stack destroyed (NAT Gateways and RDS specifically) once verified — this is the most expensive chapter so far, and `PLANNING.md` already flagged it.
