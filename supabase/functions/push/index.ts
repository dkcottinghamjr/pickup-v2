// Pickup push sender. Called by a database trigger (via pg_net) for each new
// event; sends it to the player's devices with Web Push.
import postgres from "npm:postgres@3.4.5";
import webpush from "npm:web-push@3.6.7";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 2, idle_timeout: 20 });
// Keys and the shared hook secret live in Supabase Vault.
let cfg: Promise<{ hook: string }> | null = null;
function config() {
  cfg ??= (async () => {
    const rows = await sql`select name, decrypted_secret as v from vault.decrypted_secrets
      where name in ('pickup_push_secret', 'pickup_vapid_public', 'pickup_vapid_private')`;
    const m = Object.fromEntries(rows.map((r) => [r.name, r.v as string]));
    webpush.setVapidDetails(Deno.env.get("PUSH_CONTACT") ?? "https://dkcottinghamjr.github.io/pickup-v2/", m.pickup_vapid_public, m.pickup_vapid_private);
    return { hook: m.pickup_push_secret ?? "" };
  })();
  return cfg;
}

const TITLES: Record<string, string> = {
  offer_received: "New match invite",
  approval_needed: "Needs your OK",
  match_booked: "Match booked",
  match_cancelled: "Match cancelled",
  player_joined: "Player joined",
  offer_declined: "Invite declined",
  request_expired: "Request expired",
  request_closed: "Request closed",
  request_withdrawn: "Invite withdrawn",
  message: "New message",
};

function timingSafeEqual(a: string, b: string) {
  if (a.length !== b.length || !a) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

export async function handler(req: Request): Promise<Response> {
  const { hook } = await config();
  if (req.method !== "POST" || !timingSafeEqual(req.headers.get("x-pickup-hook") ?? "", hook)) {
    return new Response("forbidden", { status: 403 });
  }
  const { event_id } = await req.json().catch(() => ({}));
  if (!event_id) return new Response("missing event_id", { status: 400 });
  const [ev] = await sql`select id, user_id, type, payload, summary from public.events where id = ${event_id} and pushed_at is null`;
  if (!ev) return Response.json({ sent: 0, reason: "not found or already pushed" });
  const subs = await sql`select id, endpoint, p256dh, auth from public.push_subscriptions where user_id = ${ev.user_id}`;
  const p = ev.payload ?? {};
  const url = p.match_id ? `./#/match/${p.match_id}` : "./#/home";
  const body = JSON.stringify({ title: TITLES[ev.type] ?? "Pickup", body: ev.summary, url, tag: p.match_id ?? p.approval_id ?? p.offer_id ?? String(ev.id) });
  let sent = 0;
  for (const s of subs) {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, body, { TTL: 3600, urgency: "high" });
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await sql`delete from public.push_subscriptions where id = ${s.id}`;
      else console.error("push failed", code, (e as Error).message);
    }
  }
  await sql`update public.events set pushed_at = now() where id = ${ev.id}`;
  return Response.json({ sent });
}

if (!Deno.env.get("PICKUP_NO_SERVE")) Deno.serve(handler);
