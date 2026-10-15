import { html, useState, useEffect, useStore, refreshMe, toast, openSheet, closeSheet, Sheet, Icon, Avatar, Spinner, Busy, Back, set, store } from "./ui.js";
import { api, sb, FN, lv } from "./lib.js";

// ---------- Players ----------
function PlayerSheet({ p }) {
  return html`<${Sheet} label=${p.name}>
    <div class="row-x" style="gap:14px"><${Avatar} lg name=${p.name}/><div class="stack-s" style="gap:2px"><h2 class="h3">${p.name}</h2><div class="sub">${p.city || ""}</div></div></div>
    <div class="card" style="display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px;text-align:center">
      <div><div class="h2">${lv(p.level) ?? "–"}</div><div class="small">${p.rating_status === "established" ? "Pickup Rating" : "Level"}</div></div>
      <div><div class="h2">${p.reliability_pct != null ? p.reliability_pct + "%" : "New"}</div><div class="small">Shows up</div></div>
      <div><div class="h2">${p.miles_away != null ? p.miles_away : "–"}</div><div class="small">Miles away</div></div>
    </div>
    ${p.played_before ? html`<div class="sub">You've played before.</div>` : null}
    <a class="btn big primary" href=${`#/play?with=${p.player_id}&name=${encodeURIComponent(p.name)}`} onClick=${closeSheet}>Invite to play</a>
  <//>`;
}

export function Players() {
  const [q, setQ] = useState("");
  const [list, setList] = useState(null);
  useEffect(() => {
    const t = setTimeout(() => api("find_players", q ? { name: q, limit: 30 } : { limit: 30, within_miles: 25 }).then((r) => setList(r.players || [])), q ? 250 : 0);
    return () => clearTimeout(t);
  }, [q]);
  return html`<main class="screen">
    <h1 class="large-title">Players</h1>
    <input class="field" type="search" placeholder="Search by name" aria-label="Search players" value=${q} onInput=${(e) => setQ(e.target.value)}/>
    <section class="stack"><h2 class="h2">${q ? "Results" : "Good matches for you"}</h2>
      ${list === null ? html`<${Spinner}/>` : list.length ? html`<div class="card flush">${list.map((p) => html`<button class="list-row" onClick=${() => openSheet(() => html`<${PlayerSheet} p=${p}/>`)}>
        <${Avatar} name=${p.name}/><div class="grow stack-s" style="gap:2px"><div class="b">${p.name}</div>
        <div class="sub">${[lv(p.level), p.reliability_pct != null ? `shows up ${p.reliability_pct}%` : "new", p.miles_away != null ? `${p.miles_away} mi` : null].filter(Boolean).join(" · ")}</div></div>
        <${Icon} n="chev" s=${14} w=${2.6} c="var(--faint)"/></button>`)}</div>`
      : html`<div class="empty">${q ? `No players named “${q}”.` : "No players near your level yet. The pilot group is joining soon."}</div>`}
    </section>
  </main>`;
}

// ---------- You ----------
export function You() {
  const { me } = useStore();
  if (!me) return html`<div class="screen"><${Spinner}/></div>`;
  const row = (href, label, value, onClick) => html`<a class="list-row" href=${href || "#"} onClick=${onClick} style="color:inherit;text-decoration:none">
    <div class="grow" style="font-size:16px">${label}</div>${value ? html`<div class="sub" style="font-size:15px;text-align:right">${value}</div>` : null}<${Icon} n="chev" s=${14} w=${2.6} c="var(--faint)"/></a>`;
  const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const availText = [...new Set(me.weekly_availability.map((w) => days[w.weekday]))].join(", ") || "Not set";
  return html`<main class="screen">
    <div class="row-x" style="gap:14px"><${Avatar} lg name=${me.name}/><div class="stack-s" style="gap:2px">
      <h1 class="large-title" style="font-size:28px">${me.name || "You"}</h1><div class="sub">${me.level ? `Level ${lv(me.level)} · ${me.rating_status}` : "Level not set"}</div></div></div>
    <section class="stack"><div class="eyebrow">Your agents</div>
      <div class="card flush">${row("#/agents", "Agents and rules", store.grants.length ? `${store.grants.length} connected` : "None yet")}</div></section>
    <section class="stack"><div class="eyebrow">Profile</div>
      <div class="card flush">
        ${row("#/setup/1?edit=1", "Name and level", lv(me.level) || "")}
        ${row("#/setup/2?edit=1", "Home courts", me.home_courts.map((c) => c.name).join(", ") || "Not set")}
        ${row("#/setup/3?edit=1", "Availability", availText)}
      </div></section>
    <section class="stack"><div class="eyebrow">App</div>
      <div class="card flush">
        ${row(null, "Notifications", "", (e) => { e.preventDefault(); import("./push.js").then((m) => m.enablePush()); })}
        ${row(null, "Sign out", "", async (e) => { e.preventDefault(); await sb.auth.signOut(); location.hash = "#/home"; location.reload(); })}
      </div></section>
    <div class="small center">Stats, results and your Pickup Rating arrive in the next update.</div>
  </main>`;
}

// ---------- Agents and rules ----------
const RULES = [
  { k: "autonomy", label: "Booking", opts: [["auto", "Within my rules"], ["ask", "Always ask me"]] },
  { k: "within_availability", label: "When", opts: [[true, "My availability"], [false, "Any time"]] },
  { k: "home_courts_or_miles", label: "Where", fmt: (v) => `Home courts + ${+v} mi`, opts: [0, 2, 5, 10, 25].map((n) => [n, n ? `Home courts + ${n} mi` : "Home courts only"]) },
  { k: "formats", label: "Format", fmt: (v) => v.map((x) => x[0].toUpperCase() + x.slice(1)).join(", "), opts: [[["singles", "doubles"], "Singles, doubles"], [["singles"], "Singles only"], [["doubles"], "Doubles only"]] },
  { k: "opponents", label: "Opponents", opts: [["anyone", "Anyone eligible"], ["following", "People I follow"]] },
  { k: "level_band", label: "Level range", fmt: (v) => `±${(+v).toFixed(1)}`, opts: [0.5, 1, 1.5].map((n) => [n, `±${n.toFixed(1)} of my level`]) },
  { k: "max_per_week", label: "Per week", fmt: (v) => `Up to ${v}`, opts: [1, 2, 3, 4, 5, 7].map((n) => [n, `Up to ${n} matches`]) },
  { k: "min_notice_hours", label: "Notice", fmt: (v) => `${v} hours`, opts: [1, 2, 4, 12, 24].map((n) => [n, `At least ${n} hour${n === 1 ? "" : "s"} ahead`]) },
  { k: "new_opponent_needs_ok", label: "New opponents", opts: [[true, "Ask me"], [false, "Book them"]] },
];
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b) || (typeof a === "number" && b != null && +b === a);
const show = (r, v) => r.fmt ? r.fmt(v) : (r.opts.find(([x]) => same(x, v)) || [, String(v)])[1];

function RuleSheet({ r, value }) {
  return html`<${Sheet} label=${r.label}><h2 class="h3">${r.label}</h2>
    <div class="card flush">${r.opts.map(([v, l]) => html`<button class="list-row" aria-pressed=${same(v, value)} onClick=${async () => {
      const { error } = await sb.from("agent_rules").update({ [r.k]: v }).eq("user_id", store.me.player_id);
      if (error) toast(error.message, true); else { toast("Saved."); await refreshMe(); closeSheet(); }
    }}><div class="grow" style="font-size:16px">${l}</div>${same(v, value) ? html`<${Icon} n="check" s=${20} w=${2.4} c="var(--green-text)"/>` : null}</button>`)}</div>
  <//>`;
}

const ACT = { request_match: "Sent a match request", accept_offer: "Accepted a match", counter_offer: "Suggested other times", decline_offer: "Declined an offer", cancel_match: "Cancelled a match", cancel_request: "Withdrew a request", send_message: "Sent a message", update_availability: "Updated availability", respond_to_offer: "Answered an offer" };
const ago = (d) => { const m = Math.round((Date.now() - new Date(d)) / 60000); return m < 60 ? `${Math.max(m, 1)}m` : m < 1440 ? `${Math.round(m / 60)}h` : `${Math.round(m / 1440)}d`; };

function ConnectSheet() {
  const url = `${FN}/mcp`;
  return html`<${Sheet} label="Connect an agent"><h2 class="h3">Connect an agent</h2>
    <p class="p">In your agent's settings, add a custom connector with this link. Then sign in to Pickup and tap Allow.</p>
    <div class="card" style="gap:8px"><div class="small">Connector link</div><div style="font-size:14px;word-break:break-all;font-family:ui-monospace,monospace">${url}</div>
      <button class="btn" onClick=${() => navigator.clipboard?.writeText(url).then(() => toast("Copied."))}>Copy link</button></div>
    <div class="sub">Works with Claude today; ChatGPT, Grok and others are next.</div>
  <//>`;
}

export function Agents() {
  const { me, grants } = useStore();
  const [log, setLog] = useState(null);
  useEffect(() => {
    loadGrants();
    sb.from("activity_log").select("client_id,action,decision,created_at").eq("actor", "agent").order("created_at", { ascending: false }).limit(30).then(({ data }) => setLog(data || []));
  }, []);
  if (!me) return html`<div class="screen"><${Spinner}/></div>`;
  const rules = me.agent_rules || {};
  return html`<main class="screen">
    <${Back} to="#/you" label="You"/>
    <h1 class="large-title" style="margin-top:-8px">Agents</h1>
    ${grants.map((g) => { const mine = (log || []).filter((x) => x.client_id === g.client.id).slice(0, 3); return html`<div class="card">
      <div class="row-x" style="gap:12px"><div class="avatar sq" aria-hidden="true">${g.client.name.charAt(0)}</div>
        <div class="grow stack-s" style="gap:2px"><div class="b" style="font-size:17px">${g.client.name}</div>
        <div class="row-x small" style="gap:6px"><span class="dot"></span>Connected ${new Date(g.granted_at).toLocaleDateString("en-US", { month: "short", day: "numeric" })}</div></div>
        <${Busy} cls="btn" onClick=${async () => { const { error } = await sb.auth.oauth.revokeGrant({ clientId: g.client.id }); if (error) toast(error.message, true); else { toast(`${g.client.name} disconnected.`); loadGrants(); } }}><span style="color:var(--danger);font-size:14px">Disconnect</span><//></div>
      ${mine.length ? html`<div class="stack-s" style="gap:8px;padding-top:12px;border-top:1px solid var(--line2);font-size:14px">${mine.map((x) => html`<div class="between"><div>${x.decision === "needs_approval" ? "Asked for your OK" : ACT[x.action] || x.action}</div><div class="small">${ago(x.created_at)}</div></div>`)}</div>` : null}
    </div>`; })}
    ${!grants.length ? html`<div class="empty">No agents connected yet.</div>` : null}
    <button class="btn big" style="border-style:dashed;background:transparent;color:var(--green-text)" onClick=${() => openSheet(() => html`<${ConnectSheet}/>`)}>Connect ${grants.length ? "another" : "an"} agent</button>

    <section class="stack-s" style="gap:8px"><div class="eyebrow">What your agents may do alone</div>
      <div class="card flush">${RULES.map((r) => html`<button class="list-row" onClick=${() => openSheet(() => html`<${RuleSheet} r=${r} value=${rules[r.k]}/>`)}>
        <div class="grow" style="font-size:16px">${r.label}</div><div class="sub" style="font-size:15px;text-align:right">${rules[r.k] === undefined ? "" : show(r, rules[r.k])}</div><${Icon} n="chev" s=${14} w=${2.6} c="var(--faint)"/></button>`)}</div>
      <div class="small">Anything outside these waits for your OK. Agents can't change these rules.</div>
    </section>
  </main>`;
}

export async function loadGrants() {
  try { const { data } = await sb.auth.oauth.listGrants(); set({ grants: Array.isArray(data) ? data : [] }); } catch { set({ grants: [] }); }
}
