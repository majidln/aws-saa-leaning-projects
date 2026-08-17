# Chapter 4 Guide — "We Broke Prod Again" (Environments)

Same format as before: concepts and resource names, no ready-to-paste HCL, you write the actual code. Less new AWS surface area than Chapter 3 — no new resource types to learn — but the Terraform-mechanics jump is real: this is the first chapter where the same infrastructure exists twice, on purpose, and where you have to reason about *which copy* a command is about to touch before you run it.

**Goal (from README.md):** the same 3-tier architecture from Chapter 3, stood up twice — dev and prod — from one set of reusable modules, with a change proven safe in dev before it ever touches prod.

**Decisions already made for this chapter:**

- **Workspaces are the structure (decided).** `dev` and `prod` are Terraform workspaces against one root config, not separate directories. Folder-per-environment would have meant an `environments/dev/main.tf` and an `environments/prod/main.tf` that are byte-identical except for module `source` paths, with all real difference living in `.tfvars` — duplication carrying no Terraform concept the workspace version doesn't already exercise. There is no `environments/` directory in this chapter. **What this choice costs you is covered in §3 and §6 — read those, because the cost is real.**
- This chapter's modules are its **own independent copy** — not sourced from `chapter-3-trail-search/modules/`, per `PLANNING.md`'s independence principle. Nothing in this chapter's directory tree references `chapter-3-trail-search/`.
- Same cost risks as Chapter 3 (NAT Gateway, RDS) — now potentially **doubled** if both workspaces are up at once. Default to applying one workspace, verifying, destroying, then the other.

---

## 0. Layout (as built)

```
trailmark/chapter-4-envs/
  modules/network/
  modules/app-tier/
  modules/db-tier/
  workspace-lab/          <- the only root config
    main.tf
    terraform.tf
    variables.tf
    dev.tfvars
    prod.tfvars
```

`workspace-lab/` is a single root config with its own provider/backend/terraform blocks, calling the three modules via `../modules/...`. Nothing under `modules/` knows or cares which workspace is calling it — that's the actual point of a module boundary, and it's what makes this whole chapter possible.

`workspace-lab` is the chapter's only environment root, despite what the name suggests. Renaming it (to `envs/`, or promoting its files up to `chapter-4-envs/`) is optional cleanup; if you rename it, the backend `key` in §3 needs to move with it.

---

## 1. Carrying forward Chapter 3, correctly

Verified present in this chapter's module copies:

- **RDS `allocated_storage` = 20.** Postgres on General Purpose (gp2/gp3) storage requires **≥ 20 GiB** — a smaller value isn't a style choice, it fails at `apply`.
- **`db_port` defaults to `5432`,** matching the Postgres engine the module actually provisions. A `3306` default here would be a landmine for any caller who doesn't set it explicitly.
- **The ALB listener stays on port 80.** Route 53/ACM are still out of scope in this chapter — nothing about adding environments changes that trade-off from Chapter 3 §3.
- **No redundant `instance_refresh { triggers = ["launch_template"] }`** on the ASG. Current provider versions treat a launch template change as an implicit trigger already.

Nothing to do here. Recorded so a re-read doesn't re-derive it.

---

## 2. What actually varies between dev and prod

Nothing in the *shape* of the infrastructure should differ — same three-tier topology, same security-group chaining, same routing rules. What varies is **size and posture**, driven entirely by inputs the modules expose.

Already parameterized and differing across `dev.tfvars` / `prod.tfvars`: `instance_type`, `asg_min_size`, `asg_max_size`, `asg_desired_capacity`.

**NAT Gateway strategy — the chapter's worked example of conditional sizing. ✅ done.** Chapter 3 fixed one NAT Gateway per AZ, matching real HA practice, at ~2x the cost of a single shared one. That's the right call for prod. For dev, a single shared NAT Gateway (all app subnets routing to the same one, regardless of AZ) is a defensible, common cost-saving trade-off real teams make — dev doesn't need to survive an AZ failure.

`modules/network` takes a `single_nat_gateway` bool, `true` in `dev.tfvars` and `false` in `prod.tfvars`. Confirmed by plan: dev creates 1 EIP + 1 NAT Gateway (39 resources total), prod creates 2 + 2 (41).

Two details that mattered in the implementation:

- **The `for_each` key set changes size, not just a count.** The EIP and NAT Gateway resources iterate `local.nat_subnets`, a derived local that is either every public subnet or just the first one. Flipping the bool on a live environment therefore *adds or destroys a resource address* rather than modifying one in place — which is what §7's last checkpoint is about.
- **The AZ→gateway lookup has to degrade gracefully.** `local.nat_gateway_by_az` only holds an entry for AZs that actually host a gateway, so with one shared gateway the second AZ's app route table would throw a key error. The route uses `lookup(local.nat_gateway_by_az, each.value.az, local.fallback_nat_gateway_id)`, so app subnets in an AZ without a local gateway route cross-AZ to the shared one — that cross-AZ hop *is* the trade being made. Route tables stay one-per-app-subnet in both modes, so flipping the bool rewrites a route target instead of recreating tables.

The module defaults `single_nat_gateway` to `false`. A caller who forgets it gets the highly-available layout and a larger bill, not a silently non-HA prod — the safer direction to fail in.

What should **not** vary: anything hardcoded inside the module files. If you catch yourself writing `count = var.environment == "prod" ? 2 : 1` *inside a module*, stop — that's environment-awareness leaking into a thing that's supposed to be environment-agnostic. The module takes a boolean or a number; the root config decides its value.

---

## 3. The two-selector problem — the core of this chapter

With folder-per-environment, one thing determined which environment you were touching: the directory you were standing in. State key, resource names, and sizing all followed from it, and `cd` is hard to get wrong.

What you built instead has **two independent selectors**:

| Selector | Controls |
|---|---|
| `terraform workspace select <name>` | which state file, and `var.environment` (via `terraform.workspace`) |
| `-var-file=<name>.tfvars` | `prefix` (resource names) and all sizing |

Nothing ties them together. `terraform workspace select prod` with `-var-file=dev.tfvars` is a valid command that plans cleanly: it writes to prod's state, tags everything `Environment = prod`, and names every resource `chapter-4-dev-*` at dev's sizing.

**This is not hypothetical here.** `workspace-lab/errored.tfstate` in this repo contains `chapter-4-dev-app-asg`, `chapter-4-dev-app-instance-role`, and a `chapter-4-dev` VPC, while `.terraform/environment` reads `prod`. Whatever the exact sequence was, the two selectors disagreed during a real run. Read that file before you delete it — it's the most useful artifact this chapter has produced so far.

**The fix, and the actual remaining Terraform work: collapse two selectors into one.** The workspace should be the only thing you choose. Two pieces:

- **Derive `prefix` instead of passing it.** `terraform.workspace` already tells the config which environment it is. A `local` computing the prefix from it means a wrong `-var-file` can no longer produce misnamed resources or orphans — only wrong sizing, which is at least visible in the plan diff.
- **Replace the `.tfvars` files with a map keyed by workspace.** A `local` shaped like `{ dev = {...}, prod = {...} }[terraform.workspace]` removes `-var-file` from the command line entirely. One selector, no flag to forget.

Weigh what that costs before you do it: sizing moves out of data files and into code, an unrecognized workspace name now fails with a map-index error rather than a clean variable error, and you lose the `-var-file` mechanic you already exercised. Decide deliberately — but "two selectors that can silently disagree" is not a defensible end state for a config whose entire purpose is keeping dev and prod apart.

**Also fix the backend key.** `terraform.tf` currently sets `key = "chapter-4-envs/dev/terraform.tfstate"`, so with the `env:` workspace prefix your prod state lands at `env:/prod/chapter-4-envs/dev/terraform.tfstate` — a path that reads as "prod's dev state." The key is the *config's* identity, not an environment's; the workspace prefix supplies the environment. Something like `chapter-4-envs/terraform.tfstate` is honest. Changing it means re-initializing and migrating or abandoning the existing (empty) state objects — cheap to do now, annoying later.

---

## 4. The actual point: prove a change in dev first

The README's trigger for this chapter is a bad prod deploy — so the workflow you're building toward isn't "apply both, done," it's: make a change, run it through dev, verify it, *then* run the same change through prod.

Concretely: pick something real (the `single_nat_gateway` work from §2 is the obvious candidate), then `workspace select dev` → `plan` → read it → `apply` → verify → `workspace select prod` → `plan` → read it → `apply`. Reading each plan before confirming is the part that matters; the infrastructure isn't the point.

Note what §3 does to this workflow: every step above depends on `workspace select` having actually taken effect. Run `terraform workspace show` before each `apply` until that reflex is automatic.

---

## 5. Where you are, and what's left

**Done:** modules written with Chapter 3's fixes carried forward; `workspace-lab` root config wired to all three modules; `dev` and `prod` workspaces created; both applied and destroyed at least once against real AWS; state confirmed separating under `env:/dev/…` and `env:/prod/…`; `single_nat_gateway` implemented and differing across the two environments (§2).

**Left:**

1. Collapse the two selectors — derive `prefix` from the workspace, and decide on the workspace-keyed map vs. `.tfvars` (§3).
2. Fix the backend `key` so it stops claiming to be dev (§3).
3. Read, then delete, `workspace-lab/errored.tfstate`.
4. Move the `az_count` variable out of `modules/network/main.tf` into that module's `variables.tf`, where the other variables live.
5. Run the §4 workflow once end to end — apply dev, verify, then apply prod.
6. Answer §6 in writing.
7. Destroy both workspaces.

---

## 6. The trade-off you now have to be able to argue

This chapter builds one structure, so the comparison the README asks for can't come from having built both. It has to come from having built this one and reasoned honestly about the other. Write down an answer to this — a paragraph, in your own words, not this guide's framing:

**Which structure would you trust more at 6am during an incident, and why?**

Ground it in specifics you actually have: the `errored.tfstate` mixup, the fact that `terraform workspace show` is a thing you have to remember to run, and the fact that the folder version would have been near-duplicate code you'd have had to keep in sync by hand. Both structures have a real failure mode. Name both, then pick.

The answer that doesn't count: "workspaces are DRYer." That's true and it's not what the question asked.

---

## 7. Checkpoints

- After the §3 work: with `prefix` derived from the workspace, what is the *worst* thing a wrong `-var-file` can still do? Is that acceptable, or does it argue for the workspace-keyed map?
- After `dev` is verified: why is proving the change in `dev` first meaningfully different from just running `terraform plan` against `prod` and reading it carefully? What does an actual `apply` in `dev` catch that a plan alone can't?
- Look back at your module files: is there anywhere sizing/environment logic leaked *into* a module instead of staying in the root config? If so, why did it end up there, and what would it take to push it back out?
- The `single_nat_gateway` change alters the key set of a `for_each`. What does that do to resources already in state, and how would you find out *before* applying it to prod?

---

## 8. Definition of done

- `dev` and `prod` both stood up at least once from this chapter's own module copies, with separate state. ✅
- Modules carry forward Chapter 3's fixes (RDS storage ≥ 20 GiB, `db_port` default matching Postgres). ✅
- No environment-conditional logic (`if prod then...`) living inside `modules/` — only in the root config. ✅
- `single_nat_gateway` implemented, differing between the two environments. ✅
- Environment selection driven by a single selector, not two that can silently disagree.
- Backend `key` no longer names one environment.
- A real change applied to `dev` first, verified, then applied to `prod` — not both edited blind.
- §6 answered in writing.
- Both workspaces destroyed — this chapter can be up to 2x Chapter 3's cost if left running, and nothing later in the project depends on either environment still being live.
