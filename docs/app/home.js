import { html, useState, useEffect, useStore, refresh, act, openSheet, closeSheet, Sheet, Icon, Avatar, Spinner, Busy, set, store } from "./ui.js";
import { todayLong, relDay, timeText, whenText, suggestTimes, isoLocal, sb, lv, shortTime } from "./lib.js";

const agentName = (clientId) => store.grants.find((g) => g.client?.id === clientId)?.client?.name || "Your agent";
const ago = (d) => {
  const m = Math.round((Date.now() - new Date(d)) / 60000);
  return m < 1 ? "just now" : m < 60 ? `${m} min ago` : m < 1440 ? `${Math.round(m / 60)} h ago` : `${Math.round(m / 1440)} d ago`;
};

export function ApprovalSheet({ a }) {
  return html`<${Sheet} label="Needs your OK">
    <div class="row-x">
      <div class="avatar sq" aria-hidden="true">${agentName(a.client_id).charAt(0)}</div>
      <div class="stack-s" style="gap:1px"><div class="b" style="font-size:15px">${agentName(a.client_id)} wants to</div><div class="small">Your agent · ${ago(a.created_at)}</div></div>
    </div>
    <h2 class="h3">${a.summary.charAt(0).toUpperCase() + a.summary.slice(1)}</h2>
    <div class="why"><div class="k">Why it needs your OK</div>
      ${a.reasons.map((r) => html`<div class="r"><${Icon} n=${/match with|follow|list|level/i.test(r) ? "you" : /court|miles/i.test(r) ? "pin" : "clock"} s=${18} c="var(--warn)" style="flex-shrink:0;margin-top:1px"/><div>${r}</div></div>`)}
    </div>
    <div class="sub">Nothing has been sent yet. ${agentName(a.client_id)} will see your answer.</div>
    <div class="stack" style="gap:8px">
      <${Busy} cls="btn big primary" onClick=${async () => { const r = await act("decide_approval", { approval_id: a.approval_id, decision: "approve" }); if (r.ok !== false) closeSheet(); }}>Approve and send<//>
      <${Busy} cls="btn big" onClick=${async () => { await act("decide_approval", { approval_id: a.approval_id, decision: "decline" }, { ok: "Declined." }); closeSheet(); }}>Decline<//>
      <a class="btn ghost" href="#/agents" onClick=${closeSheet}>Change my rules</a>
    </div>
  <//>`;
}

function CounterSheet({ o }) {
  const me = store.me;
  const times = suggestTimes(me?.weekly_availability || [], { days: 10, noticeHours: 2, max: 9 });
  const court = o.slots[0]?.court_id;
  const [picked, setPicked] = useState([]);
  const toggle = (t) => setPicked((p) => (p.includes(t) ? p.filter((x) => x !== t) : p.length < 3 ? [...p, t] : p));
  return html`<${Sheet} label="Suggest other times">
    <h2 class="h3">Suggest other times to ${o.from.name}</h2>
    <div class="sub">Same court: ${o.slots[0]?.court}. Pick up to 3.</div>
    ${times.length ? html`<div class="time-grid">${times.map((t) => html`<button class=${"tchip" + (picked.includes(t) ? " on" : "")} aria-pressed=${picked.includes(t)} onClick=${() => toggle(t)}><span class="d">${relDay(t)}</span><span class="t">${timeText(t)}</span></button>`)}</div>`
      : html`<div class="empty">Add weekly availability in You › Availability to get time suggestions.</div>`}
    <${Busy} cls="btn big primary" disabled=${!picked.length} onClick=${async () => {
      const r = await act("respond_to_offer", { offer_id: o.offer_id, action: "counter", slots: picked.map((t) => ({ start: isoLocal(t), court_id: court })) });
      if (r.ok !== false) closeSheet();
    }}>Send ${picked.length || ""} time${picked.length === 1 ? "" : "s"}<//>
    <${Busy} cls="btn big danger" onClick=${async () => { await act("respond_to_offer", { offer_id: o.offer_id, action: "decline" }); closeSheet(); }}>Can't play, decline<//>
  <//>`;
}

function OfferCard({ o }) {
  const [sel, setSel] = useState(0);
  const s = o.slots[sel];
  return html`<div class="card">
    <div class="row-x"><${Avatar} name=${o.from.name}/>
      <div class="grow stack-s" style="gap:2px"><div class="b">${o.from.name} wants to play ${o.format}</div>
      <div class="sub">${o.from.level ? `${lv(o.from.level)} · ` : ""}${o.round > 1 ? "suggested new times" : o.mode === "open" ? "open game" : "invited you"}</div></div>
    </div>
    ${o.note ? html`<div class="sub" style="font-style:italic">“${o.note.untrusted_user_text}”</div>` : null}
    <div class="stack-s">${o.slots.map((x, i) => html`<button class=${"slot" + (i === sel ? " on" : "")} aria-pressed=${i === sel} onClick=${() => setSel(i)}>
      <div class="radio"></div><div class="b" style="font-size:15px;white-space:nowrap">${relDay(x.start)} ${timeText(x.start)}</div><div class="sub grow" style="font-size:15px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${x.court}</div></button>`)}</div>
    <div class="row-x" style="gap:8px">
      <${Busy} cls="btn primary grow" onClick=${() => act("respond_to_offer", { offer_id: o.offer_id, action: "accept", slot_index: s.slot_index })}>Accept ${relDay(s.start) === "Today" ? "" : relDay(s.start) + " "}${shortTime(s.start)}<//>
      ${o.format === "singles" ? html`<button class="btn" onClick=${() => openSheet(() => html`<${CounterSheet} o=${o}/>`)}>Other time</button>`
        : html`<${Busy} cls="btn" onClick=${() => act("respond_to_offer", { offer_id: o.offer_id, action: "decline" })}>Decline<//>`}
    </div>
  </div>`;
}

function ApprovalCard({ a }) {
  return html`<div class="card" style="gap:10px">
    <div class="row-x" style="gap:8px"><span class="tag-warn">NEEDS YOUR OK</span><span class="small">from ${agentName(a.client_id)} · ${ago(a.created_at)}</span></div>
    <button style="all:unset;cursor:pointer" onClick=${() => openSheet(() => html`<${ApprovalSheet} a=${a}/>`)}>
      <div class="b" style="line-height:1.35">${a.summary.charAt(0).toUpperCase() + a.summary.slice(1)}?</div></button>
    <div class="sub">${a.reasons.join(" · ")}</div>
    <div class="row-x" style="gap:8px">
      <${Busy} cls="btn dark grow" onClick=${() => act("decide_approval", { approval_id: a.approval_id, decision: "approve" })}>Approve<//>
      <${Busy} cls="btn grow" onClick=${() => act("decide_approval", { approval_id: a.approval_id, decision: "decline" }, { ok: "Declined." })}>Decline<//>
    </div>
  </div>`;
}

function NextMatch({ m, me }) {
  const others = m.players.filter((p) => p.player_id !== me.player_id);
  return html`<a class="next" href=${"#/match/" + m.match_id}>
    <div class="between" style="align-items:flex-start"><div class="stack-s" style="gap:4px">
      <div class="k">${relDay(m.start)} · ${m.format}${m.status === "forming" ? " · filling" : ""}</div>
      <div class="t">${relDay(m.start) === "Today" || relDay(m.start) === "Tomorrow" ? "" : relDay(m.start) + " "}${timeText(m.start)}</div>
      <div class="c">${m.court.name}</div></div><div class="ball" style="margin-top:4px"></div></div>
    <div class="foot"><div class="grow" style="font-size:15px">${others.length ? "vs " + others.map((p) => p.name).join(", ") : "Waiting for players"}</div>
      ${m.status === "forming" ? html`<div style="font-size:13px;color:var(--on-green-muted)">${m.players.length}/4 in</div>` : null}</div>
  </a>`;
}

function OpenGame({ g }) {
  const s = g.slots[0];
  return html`<div class="list-row">
    <div class="grow stack-s" style="gap:2px"><div class="b">${g.format === "doubles" ? "Doubles" : "Singles"} · ${relDay(s.start)} ${timeText(s.start)}</div>
      <div class="sub">${s.court} · ${g.from.name}${g.spots_left > 1 ? ` · ${g.spots_left} spots` : g.format === "doubles" ? " · 1 spot left" : ""}</div></div>
    <${Busy} cls="btn pill" onClick=${() => act("respond_to_offer", { offer_id: g.offer_id, action: "accept", slot_index: 0 })}>Join<//>
  </div>`;
}

function Activity() {
  const [ev, setEv] = useState(null);
  useEffect(() => { sb.from("events").select("id,summary,created_at").order("id", { ascending: false }).limit(25).then(({ data }) => setEv(data || [])); }, []);
  return html`<${Sheet} label="Recent activity"><h2 class="h3">Recent activity</h2>
    ${ev === null ? html`<${Spinner}/>` : ev.length ? html`<div class="card flush">${ev.map((e) => html`<div class="list-row" style="align-items:flex-start"><div class="grow" style="font-size:15px;line-height:1.4">${e.summary}</div><div class="small" style="flex-shrink:0">${ago(e.created_at)}</div></div>`)}</div>`
      : html`<div class="empty">Nothing yet. Invites, bookings and your agents' actions show up here.</div>`}
  <//>`;
}

export function Home() {
  const st = useStore();
  useEffect(() => {
    refresh();
    const t = setInterval(() => document.visibilityState === "visible" && refresh(), 30000);
    const v = () => document.visibilityState === "visible" && refresh();
    document.addEventListener("visibilitychange", v);
    return () => { clearInterval(t); document.removeEventListener("visibilitychange", v); };
  }, []);
  const me = st.me, ib = st.inbox;
  if (!me || !ib) return html`<div class="screen"><${Spinner}/></div>`;
  const needs = ib.incoming_offers.length + ib.waiting_on_your_player.length;
  const [next, ...later] = ib.upcoming_matches;
  return html`<main class="screen">
    <div class="between" style="align-items:flex-end">
      <div class="stack-s" style="gap:2px"><div class="eyebrow">${todayLong()}</div><h1 class="large-title">Home</h1></div>
      <button class="btn" style="width:44px;padding:0;border-radius:22px" aria-label="Recent activity" onClick=${() => openSheet(() => html`<${Activity}/>`)}><${Icon} n="bell" s=${20} w=${1.8}/></button>
    </div>

    ${needs ? html`<section class="stack">
      <div class="row-x" style="gap:8px"><h2 class="h2">Needs you</h2><span class="badge">${needs}</span></div>
      ${ib.waiting_on_your_player.map((a) => html`<${ApprovalCard} key=${a.approval_id} a=${a}/>`)}
      ${ib.incoming_offers.map((o) => html`<${OfferCard} key=${o.offer_id} o=${o}/>`)}
    </section>` : null}

    <section class="stack">
      <h2 class="h2">Up next</h2>
      ${next ? html`<${NextMatch} m=${next} me=${me}/>` : html`<div class="empty">No matches booked yet.<br/><a href="#/play" style="font-weight:600;text-decoration:none">Set one up</a> or ask your agent.</div>`}
      ${later.length ? html`<div class="card flush">${later.map((m) => html`<a class="list-row" href=${"#/match/" + m.match_id} style="color:inherit;text-decoration:none">
        <div class="grow stack-s" style="gap:2px"><div class="b">${whenText(m.start)}</div><div class="sub">${m.court.name} · ${m.players.filter((p) => p.player_id !== me.player_id).map((p) => p.name).join(", ") || "filling"}</div></div><${Icon} n="chev" s=${14} w=${2.6} c="var(--faint)"/></a>`)}</div>` : null}
    </section>

    ${ib.my_open_requests.length ? html`<section class="stack"><h2 class="h2">Waiting for a reply</h2>
      <div class="card flush">${ib.my_open_requests.map((r) => html`<div class="list-row">
        <div class="grow stack-s" style="gap:2px"><div class="b">${r.format === "doubles" ? "Doubles" : "Singles"} · ${r.mode === "open" ? "open game" : "invite"}</div><div class="sub">${(r.slots || []).join(" or ")}</div></div>
        <${Busy} cls="btn ghost" onClick=${() => act("cancel_request", { request_id: r.request_id }, { ok: "Withdrawn." })}>Withdraw<//></div>`)}</div></section>` : null}

    <section class="stack">
      <h2 class="h2">Open games near you</h2>
      ${st.open?.length ? html`<div class="card flush">${st.open.slice(0, 5).map((g) => html`<${OpenGame} key=${g.offer_id} g=${g}/>`)}</div>`
        : html`<div class="empty">No open games at your level right now.</div>`}
    </section>
  </main>`;
}
