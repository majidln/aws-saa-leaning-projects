# Chapter 4 — Environments (dev / prod)

The Chapter 3 three-tier stack, stood up twice from one set of modules. `dev` and `prod` are **Terraform workspaces** against a single root config, not separate directories.

See [CHAPTER-4-GUIDE.md](../CHAPTER-4-GUIDE.md) for why, and what that choice costs.

---

## Layout

```
chapter-4-envs/
  modules/network/        VPC, subnets, IGW, NAT, route tables
  modules/app-tier/       ALB, ASG, launch template, IAM, security groups
  modules/db-tier/        RDS Postgres, subnet group, Secrets Manager
  workspace-lab/          the only root config — run every command from here
    main.tf               module wiring + outputs
    terraform.tf          provider, S3 backend, version pins
    variables.tf
    dev.tfvars
    prod.tfvars
```

---

## Prerequisites

- Terraform `~> 1.15.8`
- AWS credentials with permission to create VPC / EC2 / RDS / ELB / IAM / Secrets Manager
- **Region must be `us-east-1`.** The backend, both `.tfvars`, and every resource live there. If your AWS CLI defaults elsewhere, verification commands will silently inspect an empty region:

  ```bash
  aws configure set region us-east-1
  aws configure set cli_pager ""     # stops AWS CLI v2 piping output into $PAGER
  ```

State lives in `s3://trailmark-state-backend`, key `chapter-4-envs/terraform.tfstate`, with native S3 locking (`use_lockfile = true`). Each workspace gets its own object under an `env:/<workspace>/` prefix.

---

## Run it

All commands run from `workspace-lab/`.

```bash
cd workspace-lab
terraform init
```

Create the workspaces once:

```bash
terraform workspace new dev
terraform workspace new prod
```

Then, for either environment — **the workspace and the `-var-file` must match**:

```bash
terraform workspace select dev
terraform plan  -var-file=dev.tfvars
terraform apply -var-file=dev.tfvars
```

Same for prod, swapping both `dev` → `prod`.

Expect roughly 5–10 minutes; RDS and the NAT Gateway are the slow parts.

## Verify

```bash
terraform output alb_dns
curl http://$(terraform output -raw alb_dns)/health
```

Expect `ok`. If it hangs, give the ASG a few minutes — instances boot, install `python3`, then need two passing health checks before the ALB routes to them.

The database should **not** be reachable from your laptop. That's the point:

```bash
nc -zv $(terraform output -raw db_endpoint) 5432    # should time out
```

## Tear down

```bash
terraform destroy -var-file=dev.tfvars
```

Do this promptly. Both environments up at once is ~$0.25/hr (~$6/day) — three NAT Gateways, two ALBs, two RDS instances.

---

## What differs between dev and prod

Everything below is set in `.tfvars`. No environment-conditional logic lives inside `modules/`.

| Variable | dev | prod |
|---|---|---|
| `instance_type` | `t2.micro` | `t3.micro` |
| `asg_min_size` / `max` / `desired` | 1 / 2 / 1 | 2 / 4 / 2 |
| `single_nat_gateway` | `true` — one shared | `false` — one per AZ |
| `recovery_window_in_days` | `0` — instant secret delete | `30` — recoverable |
| `db_instance_class` | `db.t3.micro` | `db.t3.micro` (deliberate) |

`single_nat_gateway` is the interesting one. Dev routes both app subnets through a single gateway (cross-AZ hop, roughly half the cost). Prod gives each AZ its own, so egress survives an AZ failure.

---

## Gotchas

**The workspace and `-var-file` are two independent selectors.** `workspace select prod` with `-var-file=dev.tfvars` plans cleanly and writes `chapter-4-dev-*` resources into prod's state. Run `terraform workspace show` before any apply.

**Secrets Manager tombstones block re-apply.** `destroy` only *schedules* a secret for deletion; the name stays reserved for the recovery window. Dev sets `recovery_window_in_days = 0` to avoid this. If prod (window `30`) blocks a re-apply:

```bash
aws secretsmanager delete-secret \
  --secret-id chapter-4-prod-db-password \
  --force-delete-without-recovery --region us-east-1
```

**A failed apply leaves resources running.** The apply is not atomic — a failure partway through can leave a NAT Gateway and RDS instance billing. Check what's actually up before assuming a failed run cost nothing.

---

## Outputs

| Output | |
|---|---|
| `alb_dns` | public ALB hostname — `curl http://<this>/health` |
| `vpc_id` | VPC ID |
| `app_sg_id` | app security group (the source for RDS ingress) |
| `db_endpoint` | RDS hostname — private, should fail from your laptop |
| `db_port` / `db_name` | `5432` / `trailmark` |
| `db_secret_arn` | Secrets Manager ARN holding the DB credentials |

---

## Architecture overview

<!-- TODO: diagram + walkthrough.
     Worth covering:
       - VPC CIDR and the three subnet tiers across two AZs
       - traffic path: internet -> ALB (public) -> app tier (private) -> RDS (isolated)
       - security group chaining: ALB SG -> app SG -> db SG, each referencing the previous
       - egress path: app subnets -> NAT -> IGW, and how it differs dev vs prod
       - why db subnets have no route table association at all
       - how the app reads its DB credentials from Secrets Manager via the instance profile
-->

_To be written._
