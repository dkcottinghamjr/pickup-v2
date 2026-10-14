// Pickup app API — the iPhone app's single write endpoint.
// POST { action, params, idempotency_key } with the player's session token.
// Runs the same private.call() the agents use. A session token (no client_id)
// acts as the player; an OAuth token (client_id) acts as that agent, so its
// rules still apply here too.

import postgres from "npm:postgres@3.4.5";
import * as jose from "npm:jose@5.9.6";

const SUPABASE_URL = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/$/, "");
const ISSUER = `${SUPABASE_URL}/auth/v1`;
const JWKS = jose.createRemoteJWKSet(new URL(`${ISSUER}/.well-known/jwks.json`));
const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 3, idle_timeout: 20 });

const ALLOWED_ORIGINS = (Deno.env.get("PICKUP_APP_ORIGINS") ?? "https://dkcottinghamjr.github.io,http://localhost:5173")
  .split(",").map((s) => s.trim());
const ACTIONS = new Set([
  "request_match", "respond_to_offer", "cancel_request", "cancel_match", "send_message",
  "update_availability", "decide_approval", "needs_attention", "get_me", "find_courts",
  "find_players", "find_open_games", "list_matches",
]);

function cors(req: Request) {
  const origin = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0],
    "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

export async function handler(req: Request): Promise<Response> {
  const h = cors(req);
  const out = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...h } });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: h });
  if (req.method !== "POST") return out({ ok: false, error: { code: "method", message: "Use POST." } }, 405);

  const m = (req.headers.get("authorization") ?? "").match(/^Bearer\s+(.+)$/i);
  if (!m) return out({ ok: false, error: { code: "not_signed_in", message: "Sign in first." } }, 401);
  let sub: string, client: string | null;
  try {
    const { payload } = await jose.jwtVerify(m[1], JWKS, { issuer: ISSUER });
    if (payload.role !== "authenticated" || typeof payload.sub !== "string") throw new Error("role");
    sub = payload.sub;
    client = typeof payload.client_id === "string" && payload.client_id ? payload.client_id : null;
  } catch {
    return out({ ok: false, error: { code: "not_signed_in", message: "Your session expired. Sign in again." } }, 401);
  }

  let body: { action?: string; params?: Record<string, unknown>; idempotency_key?: string };
  try {
    body = await req.json();
  } catch {
    return out({ ok: false, error: { code: "bad_json", message: "Body must be JSON." } }, 400);
  }
  if (!body.action || !ACTIONS.has(body.action)) {
    return out({ ok: false, error: { code: "unknown_action", message: `Unknown action ${body.action}.` } }, 400);
  }
  const key = body.idempotency_key ? `${client ?? "app"}:${body.idempotency_key}` : null;
  try {
    const [row] = await sql`select private.call(${sub}::uuid, ${client}, ${body.action}, ${sql.json((body.params ?? {}) as never)}::jsonb, ${key}) as r`;
    return out(row.r);
  } catch (e) {
    console.error("api call failed", body.action, e);
    return out({ ok: false, error: { code: "server", message: "Pickup had a problem. Try again." } }, 500);
  }
}

if (!Deno.env.get("PICKUP_NO_SERVE")) Deno.serve(handler);
