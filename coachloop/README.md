# CoachLoop — AI Training Coach

A chat bot that knows your training history, answers questions about it, and plans and schedules your next workouts.

## Goals
- Learn **Bedrock AgentCore** (Runtime, Gateway, Identity, Memory) with a real use case.
- Use **Auth0 roles** to control what the AI can do per user.
- Add **Bedrock Guardrails** for health-related safety.
- Call **third-party APIs** as agent tools.
- Keep everything **serverless**.

## What the agent does
- Answers history questions ("How did my long runs trend this quarter?", "Am I overtraining?").
- Builds a weekly or block plan from load, goals and free time.
- Schedules workouts on Google Calendar after checking availability, and reschedules on request.
- Moves outdoor sessions when the weather forecast is bad.
- Sends a reminder the evening before a workout.

## Data sources
| Source | Notes |
|---|---|
| Strava | Main integration. OAuth2, webhooks, low rate limits (~100 req / 15 min). |
| Apple Health | No cloud API. User uploads `export.xml` to S3, a Lambda parses it. Optional. |
| Garmin | Official API needs business approval; unofficial libs are fragile. Skip for now. |
| Open-Meteo | Weather forecast, free. |
| Google Calendar | Availability and event creation. |

## Planned tools (via AgentCore Gateway)
- `get_recent_activities`, `get_activity_detail` (Strava)
- `get_weather_forecast` (Open-Meteo)
- `find_free_slots`, `create_event` (Google Calendar)
- `get_health_summary` (parsed Apple Health data)
- `save_plan`, `get_plan` (DynamoDB)

## Access levels (Auth0)
| Role | What the AI can do |
|---|---|
| Free | Read-only chat over the last 30 days. Suggests plans but cannot write to the calendar. 10 messages per day. |
| Pro | Full history, plan generation, calendar scheduling, weather-aware rescheduling. |
| Coach | Pro, plus access to athletes who granted consent. Can write plans into their account. |
| Admin | Usage and guardrail-violation dashboard. No access to health data. |

The Coach role is the key design problem: the agent's identity and data scope must come from verified claims plus a consent record in DynamoDB, never from the chat text.

## Guardrails
- Denied topics: medical diagnosis, medication or dosage advice, extreme dieting, eating-disorder patterns.
- Mask precise home location (strip start and end GPS points of routes).
- Contextual grounding: no invented activities.
- Prompt-injection defence: Strava titles and descriptions are untrusted input.
- Plans always carry a "listen to your body" disclaimer.

## Architecture (draft)
- Chat UI (React or Next.js) on S3 and CloudFront, Auth0 login.
- API Gateway with a Lambda authorizer (same pattern as Gatekeeper).
- Lambda invokes the AgentCore Runtime agent and streams the response.
- AgentCore Memory for goals and preferences ("mornings only, no Sundays").
- Strava webhook -> API Gateway -> SQS -> Lambda -> DynamoDB.
- EventBridge Scheduler for reminders and weekly plan reviews.
- Secrets Manager for per-user OAuth tokens, with refresh.
- Terraform for all infrastructure.

## Suggested build order
1. Auth0 and chat UI skeleton, plus a "hello" agent on AgentCore Runtime.
2. Strava OAuth connect, then an ingestion Lambda writing to DynamoDB.
3. Read-only tools via Gateway for history questions.
4. Guardrails, then role-based tool filtering.
5. Weather and calendar tools, then scheduling with a human confirmation step.
6. Apple Health upload, Memory, and the Coach role.

## Open questions
- Strava terms restrict showing one user's data to other users. How does the Coach role fit within that?
- How should the agent confirm write actions (calendar events) before executing them?
- Where do per-user rate limits for the Free tier live (DynamoDB counter vs API Gateway usage plans)?
