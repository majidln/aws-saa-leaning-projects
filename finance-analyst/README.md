# Personal Finance / Expense Analyst

A chat bot where you talk to your own spending, such as "why was March higher than February?".

## Goals
- Learn **Bedrock AgentCore** (Runtime, Gateway, Identity, Memory) with a real use case.
- Use **Auth0 roles** to control what the AI can see and do per user.
- Make **Bedrock Guardrails** central, since finance needs the strictest rules.
- Call **third-party APIs** as agent tools.
- Keep everything **serverless**.

## What the agent does
- Summarises spending by category, merchant and period, and compares periods.
- Explains changes ("what drove the increase in March?").
- Detects recurring charges and unusual transactions.
- Converts currencies using live exchange rates.
- Optionally looks up stock or fund prices for context. It never gives investment advice.

## Data sources
| Source | Notes |
|---|---|
| Plaid sandbox (or another open banking API) | Accounts and transactions with fake data. Start here. |
| CSV upload to S3 | Fallback and easy testing. A Lambda parses it into DynamoDB. |
| Exchange-rate API | For multi-currency totals. |
| Stock price API | Optional, read-only context. |

## Planned tools (via AgentCore Gateway)
- `get_transactions` (filters: date range, category, merchant)
- `get_spending_summary` (aggregated by category and period)
- `detect_recurring_charges`
- `convert_currency`
- `get_stock_price` (optional)

## Access levels (Auth0)
| Role | What the AI can do |
|---|---|
| Free | Monthly summary only, no transaction-level detail. |
| Premium | Transaction-level analysis, comparisons, recurring-charge detection. |
| Family admin | Also sees the sub-accounts of family members who agreed to share. |

Scope comes from verified token claims plus a sharing record in DynamoDB, never from the chat text.

## Guardrails
- Block personalised investment advice. Add a disclaimer on responses that touch investments.
- Mask account and card numbers in input and output.
- Denied topics: tax and legal advice, loan approval decisions.
- Contextual grounding: numbers in answers must come from tool results, not the model's memory.
- Prompt-injection defence: transaction descriptions and merchant names are untrusted input.

## Architecture (draft)
- Chat UI (React or Next.js) on S3 and CloudFront, Auth0 login.
- API Gateway with a Lambda authorizer (same pattern as Gatekeeper).
- Lambda invokes the AgentCore Runtime agent and streams the response.
- AgentCore Memory for preferences (budgets, currency, categories of interest).
- Transactions stored in DynamoDB, partitioned by user (and tenant or family).
- Plaid tokens in Secrets Manager.
- Terraform for all infrastructure.

## Suggested build order
1. Auth0 and chat UI skeleton, plus a "hello" agent on AgentCore Runtime.
2. CSV upload and ingestion into DynamoDB with fake data.
3. Read-only tools via Gateway (`get_transactions`, `get_spending_summary`).
4. Guardrails (investment advice, PII masking, grounding).
5. Role-based tool filtering (Free vs Premium).
6. Plaid sandbox, currency conversion, Family admin role, Memory.

## Open questions
- Should aggregation happen in the tool (Lambda) or be left to the model? Prefer the tool, so numbers are exact.
- How should the Free tier hide transaction detail: tool filtering, or different tool outputs?
- How should family sharing consent be recorded and revoked?
