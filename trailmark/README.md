# Trailmark: Learning Terraform on AWS Through a Growing Startup

## The Scenario

You are the solo infrastructure engineer at Trailmark, a startup that publishes hiking trail guides. The company doesn't exist yet as a codebase — it exists as a series of real problems that show up in order, the same way they would at an actual startup. Each chapter of this project is a response to the previous chapter's pain point. You build only what the story currently needs, using Terraform to do it, and by the end you'll have touched the tools that matter most in real-world infrastructure work: providers, state, modules, security boundaries, environments, and CI/CD.

The project is split into chapters. Each chapter has a trigger (why this work exists), an architecture (what you build), and Terraform concepts (what you learn by building it).

---

## Chapter 1 — The Launch Page

**Trigger:** Trailmark needs a landing page live today, before a launch email goes out. No backend, no dynamic content — just a page announcing the company.

**Architecture:**
- One S3 bucket configured for static website hosting
- Public read bucket policy
- HTML/CSS files uploaded as the site content

**Terraform concepts:**
- Providers and provider configuration
- Basic resources (`aws_s3_bucket`, bucket policy, website configuration)
- Input variables and outputs
- `terraform init`, `plan`, `apply`, `destroy`

**Outcome:** A live, publicly reachable static website on an S3 website endpoint.

---

## Chapter 2 — Real Traffic, Real Speed (CDN + HTTPS)

**Trigger:** The launch email works. Traffic spikes. Someone points out the site is serving plain `http://` from an ugly S3 URL, and pages are loading slowly for users far from the bucket's region.

**Architecture:**
- CloudFront distribution in front of the S3 bucket (as origin)
- ACM certificate for HTTPS (using a placeholder/self-managed domain or CloudFront's default domain, since Route 53 is out of scope for now)
- Origin access control so the S3 bucket is no longer directly public — only CloudFront can read from it
- Remote state: move local `.tfstate` into an S3 backend, with a DynamoDB table for state locking

**Terraform concepts:**
- Data sources
- Resource dependencies and implicit/explicit `depends_on`
- Remote backends and state locking
- Why state matters once more than one person (or one laptop) touches the infrastructure

**Outcome:** A fast, HTTPS-served static site, and a Terraform state setup that's safe for a team.

---

## Chapter 3 — The Trail Search Feature (3-Tier Architecture)

**Trigger:** Static pages aren't enough anymore. Users want to search trails by difficulty, distance, and location. That requires a real backend and a real database — and Trailmark's engineering lead is adamant about one rule: the database must never be reachable from the internet, directly or indirectly, except through the app layer.

This is where the project becomes a proper 3-tier architecture, and where the VPC, subnets, and security groups stop being boilerplate and start being the actual point.

**Architecture:**

A VPC spanning 2 Availability Zones, divided into three subnet tiers:

| Layer | Subnet | Contents | Reachable from |
|---|---|---|---|
| Presentation | Public subnets | Application Load Balancer (ALB) | Internet, port 443 |
| Application | Private subnets | EC2 instances in an Auto Scaling Group, running the trail-search API | ALB's security group only |
| Data | Private (isolated) subnets | RDS Postgres instance | App tier's security group only, port 5432 |

Supporting pieces:
- Internet Gateway (for the public subnets)
- NAT Gateway (so app-tier instances can reach the internet outward — e.g. OS updates — without being reachable inward)
- Security groups chained by reference (ALB SG → App SG → DB SG), not by IP range
- DB subnet group for RDS
- Credentials for RDS stored in AWS Secrets Manager, not hardcoded in `.tf` files or variables

**Terraform structure:** three modules, composed in a root configuration:
- `modules/network` — VPC, subnets, route tables, IGW, NAT Gateway
- `modules/app-tier` — launch template, Auto Scaling Group, ALB, target group, listener
- `modules/data-tier` — RDS instance, subnet group, Secrets Manager secret

**Terraform concepts:**
- Writing and consuming your own modules (inputs/outputs between modules)
- `count` and `for_each` (e.g. for subnets across 2 AZs)
- Security group referencing (SG-to-SG rules)
- Secrets management via Secrets Manager, referenced (not embedded) in Terraform config

**Outcome:** A working 3-tier app — public load balancer, private application servers, fully isolated database — where every access path between layers is explicit and enforced by Terraform-managed security groups.

---

## Chapter 4 — "We Broke Prod Again" (Environments)

**Trigger:** A risky change goes straight to production and causes an outage. The team decides nothing gets applied to prod without first being tested somewhere identical but safe.

**Architecture:**
- The same three modules from Chapter 3, reused for two environments: dev and prod
- Environment-specific `.tfvars` files (instance sizes, instance counts, DB size, etc.)
- Either Terraform workspaces or a folder-per-environment layout (`environments/dev`, `environments/prod`) — both are valid, and comparing them is part of the learning

**Terraform concepts:**
- Environment separation strategies and their trade-offs
- Variable files (`-var-file`)
- Conditional logic and environment-driven sizing

**Outcome:** Two independent environments built from the same reusable modules, so changes can be tested in dev before touching prod.

---

## Chapter 5 — "Just Review It Before It Goes Live" (CI/CD)

**Trigger:** The team lead no longer wants anyone running `terraform apply` from their laptop with personal AWS credentials. Every change should be reviewed before it touches real infrastructure.

**Architecture:**
- GitHub Actions workflow: `terraform plan` runs automatically on every pull request, posting the plan output for review
- `terraform apply` runs automatically on merge to `main`
- Authentication to AWS via OIDC (GitHub's OIDC provider assuming an IAM role), not long-lived static AWS access keys

**Terraform concepts:**
- Infrastructure automation and review workflows
- Secrets-free AWS authentication (OIDC federation)
- Treating `.tf` changes like any other code change — reviewed before merge

**Outcome:** A pipeline where infrastructure changes are proposed, reviewed, and applied without anyone holding long-lived AWS credentials on their machine.

---

## Summary Table

| Chapter | Trigger | New AWS Services | Core Terraform Concepts |
|---|---|---|---|
| 1 | Need a page live today | S3 (static hosting) | providers, resources, variables, outputs |
| 2 | Traffic spike, needs HTTPS/speed | CloudFront, ACM | data sources, dependencies, remote state, locking |
| 3 | Needs a real backend + DB, securely | VPC, ALB, ASG/EC2, RDS, Secrets Manager | modules, count/for_each, security group chaining |
| 4 | Broke prod once | (reuse of Ch. 3 modules) | environments, .tfvars, workspaces |
| 5 | No more laptop applies | GitHub Actions, IAM OIDC | CI/CD, plan/apply automation, secretless auth |

---

## Notes on Scope

- Route 53 / custom domain is intentionally excluded for now — HTTPS in Chapter 2 uses CloudFront's default domain or a placeholder ACM setup. It can be added later as a natural "Chapter 2.5" without disrupting the rest of the story.
- Each chapter is meant to be applied and destroyed (`terraform apply` / `terraform destroy`) as you go, to control AWS costs — especially the NAT Gateway and RDS in Chapter 3, which are the most expensive pieces in this project if left running.
- The project is designed so each chapter's Terraform code builds on the last, but each chapter is also independently useful if you only want to practice one concept at a time.
