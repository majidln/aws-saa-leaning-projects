# Step 2 Guide — Plumbing Before a Lock

A coaching guide, not a code drop. It names what to build and why; you write the Go and the HCL.

**Goal (from [PLANNING.md](PLANNING.md)):** `curl` a REST API's `GET /hello` and get 200 from a Go Lambda — no auth at all. Prove the plumbing before Step 3 adds something that rejects requests.

---

## 1. Layout

```
gatekeeper/
├── Makefile
├── cmd/hello/        # own Go module: go.mod, main.go
├── build/            # gitignored — bootstrap binaries
└── infra/            # one Terraform root, grows every step
```

Add a `.gitignore` before the first `terraform init`: `.terraform/`, `*.tfstate*`, `build/`, `*.zip`. **Do commit `.terraform.lock.hcl`** — it pins provider versions. State files never go in git; they can hold secrets in plain text.

Flat `.tf` files split by concern (`lambda.tf`, `api.tf`, `iam.tf`) are enough. A module earns its place when something is reused — not yet.

---

## 2. The function

`cmd/hello`: `aws-lambda-go`, handler takes `events.APIGatewayProxyRequest`, returns `events.APIGatewayProxyResponse` with 200 and a small JSON body.

**Log the path, not the whole event.** From Step 3 on, the event carries an `Authorization` header — log the event and you write bearer tokens into CloudWatch.

Build via the Makefile, per function: `GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -tags lambda.norpc -o ../../build/hello/bootstrap .` from inside `cmd/hello`. Terraform zips the result; it never compiles Go.

---

## 3. Lambda + IAM

- `archive_file` zips `build/hello/bootstrap`. `aws_lambda_function` with `provided.al2023`, `arm64`, handler `bootstrap`.
- **`source_code_hash = data.archive_file.….output_base64sha256`.** Without it, Terraform sees the same filename and never redeploys new code.
- Declare the log group `/aws/lambda/<name>` yourself, with retention (7 days), and create it **before** the function. Otherwise Lambda creates it on first invoke — never-expiring, and outside Terraform.
- Execution role: skip the `AWSLambdaBasicExecutionRole` managed policy — it grants log access on `*`. Write your own: `logs:CreateLogStream` and `logs:PutLogEvents` on *this* log group only. Security project, least privilege from the first role.

---

## 4. API Gateway (REST)

REST API is five resources plus a permission, where HTTP API would be one. Each is worth knowing:

- `aws_api_gateway_rest_api` — `endpoint_configuration { types = ["REGIONAL"] }`. The default, `EDGE`, puts an AWS-managed CloudFront in front that you don't need.
- `aws_api_gateway_resource` (`hello`) → `aws_api_gateway_method` (`GET`, `authorization = "NONE"` — Step 3 changes this line).
- `aws_api_gateway_integration`, type `AWS_PROXY`. **`integration_http_method` must be `POST`** even though the route is `GET` — it's the method API Gateway uses to invoke Lambda, not the client's.
- `aws_lambda_permission` for `apigateway.amazonaws.com`, `source_arn` scoped to `<execution_arn>/*/GET/hello`, not `*`.
- `aws_api_gateway_deployment` + `aws_api_gateway_stage` (`prod`). **A deployment is a snapshot.** Change a method later and nothing goes live until a new deployment. Give the deployment a `triggers` hash over the resources it depends on, with `create_before_destroy`.

Output the stage's `invoke_url`.

---

## 5. Provider and state

Pin the current major of the `aws` and `archive` providers. `default_tags { Project = "gatekeeper" }` on the provider, so every resource is tagged without repeating it.

State: §5 of PLANNING recommends trailmark's `state-backend` bucket with key `gatekeeper/terraform.tfstate`. Look up its bucket name and locking setup in `trailmark/state-backend/` — or start local and migrate later with `terraform init -migrate-state`. Decide, and write down which.

---

## 6. Suggested order

1. `.gitignore`, then `cmd/hello` + `go mod init` + `go mod tidy`
2. Makefile, `make build`, confirm `build/hello/bootstrap` exists
3. `infra/`: provider, IAM, log group, function
4. `terraform init`, `terraform plan`, `terraform apply` — invoke it in the console once before adding the API
5. API Gateway resources, permission, deployment, stage; `apply`
6. `curl "$(terraform output -raw invoke_url)/hello"`
7. `terraform destroy`, then `apply` again from scratch
8. Checkpoints, one line each in RESULTS.md
9. `git tag gatekeeper-step-2-complete`

---

## 7. Checkpoints

- `curl` a path that doesn't exist. What status and message come back? Who answered — API Gateway or Lambda?
- Change the response text, `make build`, `terraform plan`. Does the function show an update? If not, what's missing?
- Add a second route without touching the deployment's `triggers`. Does `curl` see it after `apply`? Why not?
- In the console, open the function's resource-based policy. Who is allowed to invoke it, and from where?
- After one invoke, what retention does the log group show?

---

## 8. Definition of done

- `GET /hello` returns 200 with no `Authorization` header.
- `destroy` → `apply` works cleanly from scratch.
- A code change redeploys on the next `apply`.
- Log group has 7-day retention; the role's log permissions name one log group, not `*`.
- No state, zips, or binaries in git.
- Tagged `gatekeeper-step-2-complete`. Free tier — leave it running.
