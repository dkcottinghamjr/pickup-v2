# Pickup v2

Tennis coordination for people and their AI agents. One backend, two front doors:
an iPhone-first web app for people, and an MCP connector (plus a web API) for agents
like Claude, ChatGPT, Grok and Muse. Both have identical abilities.

Product brief and system spec: see the "Pickup v2 — Product Brief & System Spec" doc.

## Layout

```
supabase/
  migrations/   Database schema, row-level security and all game logic (SQL)
  functions/    Edge Functions: `mcp` (agent connector) and `api` (app + API keys)
  tests/        SQL acceptance tests, run against a local Postgres
web/            The iPhone web app (coming in milestone 2)
```

## How the logic is organised

Every state change goes through one SQL entry point, `private.call(player, agent_client, action, params, idempotency_key)`.
The `private` schema is not exposed by Supabase's REST API. Edge Functions verify the
caller's sign-in, then call it. Agent rules are enforced there, so no agent can step
outside what its player allowed; out-of-rules actions become approvals the player
decides in the app.

## Tests

```
supabase/tests/run_local.sh   # rebuilds a scratch database from the migrations and runs tests/test_*.sql
```
Needs a local Postgres 17 on the socket in `PGHOST` (default `/tmp/pgdata`, port 54329).
