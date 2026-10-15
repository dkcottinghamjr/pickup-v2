// Pickup app: Supabase client, the api() door to the shared core, and helpers.
export const SUPABASE_URL = "https://oqqrmyehlnguexnzyvxw.supabase.co";
export const SUPABASE_KEY = "sb_publishable__sgBtE86ux4_z-w4E23QDA_btmzqRsu";
export const FN = `${SUPABASE_URL}/functions/v1`;
export const BASE = new URL("..", import.meta.url).pathname; // "/pickup-v2/"

export const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { flowType: "pkce", detectSessionInUrl: true, persistSession: true, autoRefreshToken: true },
});

export async function session() {
  const { data } = await sb.auth.getSession();
  return data.session;
}

// Every action goes through the same core the agents use.
export async function api(action, params = {}, idempotent = false) {
  const s = await session();
  if (!s) throw new Error("Signed out");
  const res = await fetch(`${FN}/api`, {
    method: "POST",
    headers: { authorization: `Bearer ${s.access_token}`, "content-type": "application/json" },
    body: JSON.stringify({ action, params, idempotency_key: idempotent ? crypto.randomUUID() : undefined }),
  });
  let body;
  try { body = await res.json(); } catch { body = { ok: false, error: { message: "Pickup didn't respond. Check your connection." } }; }
  return body;
}

export function errText(r) {
  return r?.error?.message || "Something went wrong. Try again.";
}

// ---- time helpers (all display in the player's time zone) ----
export let TZ = "America/New_York";
export function setTZ(tz) { if (tz) TZ = tz; }

const fmt = (opts) => new Intl.DateTimeFormat("en-US", { timeZone: TZ, ...opts });
export const timeText = (d) => fmt({ hour: "numeric", minute: "2-digit" }).format(new Date(d));
export const dayShort = (d) => fmt({ weekday: "short" }).format(new Date(d));
export const dateLong = (d) => fmt({ weekday: "short", month: "short", day: "numeric" }).format(new Date(d));
export const todayLong = () => fmt({ weekday: "long", month: "short", day: "numeric" }).format(new Date());

function ymd(d) {
  const p = Object.fromEntries(fmt({ year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(new Date(d)).map((x) => [x.type, x.value]));
  return `${p.year}-${p.month}-${p.day}`;
}
export function relDay(d) {
  const t = ymd(Date.now()), x = ymd(d), tm = ymd(Date.now() + 864e5);
  if (x === t) return "Today";
  if (x === tm) return "Tomorrow";
  return dayShort(d);
}
export function whenText(d) {
  const r = relDay(d);
  return `${r === "Today" || r === "Tomorrow" ? r : dateLong(d)}, ${timeText(d)}`;
}

// Offset (minutes) of TZ at a given UTC instant.
function tzOffset(utcMs) {
  const p = Object.fromEntries(fmt({ year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" })
    .formatToParts(new Date(utcMs)).map((x) => [x.type, x.value]));
  const asUTC = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second);
  return (asUTC - utcMs) / 60000;
}
// A wall-clock time in TZ -> Date.
export function zoned(y, m, d, hh, mm) {
  const guess = Date.UTC(y, m - 1, d, hh, mm);
  const off1 = tzOffset(guess);
  const off2 = tzOffset(guess - off1 * 60000);
  return new Date(guess - off2 * 60000);
}
export function isoLocal(date) {
  // ISO with the TZ offset, e.g. 2026-10-17T09:00:00-04:00
  const off = tzOffset(date.getTime());
  const local = new Date(date.getTime() + off * 60000);
  const sign = off >= 0 ? "+" : "-";
  const a = Math.abs(off);
  return local.toISOString().slice(0, 19) + `${sign}${String(Math.floor(a / 60)).padStart(2, "0")}:${String(a % 60).padStart(2, "0")}`;
}

// Next starts of the player's weekly windows: smart time chips for Play.
export function suggestTimes(weekly, { days = 7, noticeHours = 1, max = 8 } = {}) {
  const out = [];
  const now = Date.now();
  for (let i = 0; i < days; i++) {
    const [y, m, d] = ymd(now + i * 864e5).split("-").map(Number);
    const dow = new Date(Date.UTC(y, m - 1, d)).getUTCDay();
    for (const w of weekly.filter((x) => x.weekday === dow).sort((a, b) => a.start.localeCompare(b.start))) {
      const [sh, sm] = w.start.split(":").map(Number);
      const [eh, em] = w.end.split(":").map(Number);
      // first start, plus a later one if the window is long
      const starts = [[sh, sm]];
      if ((eh * 60 + em) - (sh * 60 + sm) >= 240) starts.push([sh + 2, sm]);
      for (const [h, mi] of starts) {
        const t = zoned(y, m, d, h, mi);
        if (t.getTime() > now + noticeHours * 36e5 && (h * 60 + mi + 90) <= eh * 60 + em) out.push(t);
      }
    }
  }
  return out.slice(0, max);
}

export const lv = (x) => (x == null || x === "" ? null : (+x).toFixed(1));
export const shortTime = (d) => timeText(d).replace(":00", "");
export const initials = (name) => (name || "?").split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join("") || "?";

export const LEVELS = [
  { v: 2.5, t: "Learning", d: "Can rally slowly; still learning to keep score and serve in." },
  { v: 3.0, t: "Getting consistent", d: "Medium-pace rallies; directing the ball is still hit or miss." },
  { v: 3.5, t: "Solid rallies", d: "Good control at medium pace; starting to come to the net." },
  { v: 4.0, t: "Dependable", d: "Placement and spin on both sides; plays points with a plan." },
  { v: 4.5, t: "Strong", d: "Power and spin; varies the game and hits a reliable second serve." },
  { v: 5.0, t: "Tournament", d: "Strong shots under pressure; plays competitive events." },
];

export function icsFor(m) {
  const z = (d) => new Date(d).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
  const other = (m.players || []).map((p) => p.name).join(" vs ");
  const lines = [
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Pickup//EN", "BEGIN:VEVENT",
    `UID:${m.match_id}@pickup`, `DTSTAMP:${z(Date.now())}`, `DTSTART:${z(m.start)}`, `DTEND:${z(m.end)}`,
    `SUMMARY:Tennis ${m.format}: ${other}`, `LOCATION:${m.court?.name || ""}`,
    "BEGIN:VALARM", "TRIGGER:-PT2H", "ACTION:DISPLAY", "DESCRIPTION:Tennis in 2 hours", "END:VALARM",
    "END:VEVENT", "END:VCALENDAR",
  ];
  return "data:text/calendar;charset=utf-8," + encodeURIComponent(lines.join("\r\n"));
}
