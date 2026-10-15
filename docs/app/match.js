import { html, useState, useEffect, useStore, act, openSheet, closeSheet, Sheet, Icon, Avatar, Spinner, Busy, Back } from "./ui.js";
import { api, sb, dateLong, timeText, icsFor } from "./lib.js";

function CancelSheet({ m, late, onDone }) {
  const [reason, setReason] = useState("");
  return html`<${Sheet} label="Cancel match">
    <h2 class="h3">Cancel ${m.format} on ${dateLong(m.start)}?</h2>
    <div class="sub">${late ? "It's less than 12 hours away, so this counts against your reliability." : "The other players are told right away."}</div>
    <input class="field" placeholder="Reason (optional)" aria-label="Reason" value=${reason} onInput=${(e) => setReason(e.target.value)}/>
    <${Busy} cls="btn big danger" onClick=${async () => { const r = await act("cancel_match", { match_id: m.match_id, reason: reason || undefined }); if (r.ok !== false) { closeSheet(); onDone(); } }}>Cancel match<//>
    <button class="btn big" onClick=${closeSheet}>Keep it</button>
  <//>`;
}

export function Match({ id }) {
  const { me } = useStore();
  const [m, setM] = useState(null);
  const [court, setCourt] = useState(null);
  const [msgs, setMsgs] = useState([]);
  const [text, setText] = useState("");

  async function load() {
    let r = await api("list_matches", { when: "upcoming" });
    let found = r.matches?.find((x) => x.match_id === id);
    if (!found) { r = await api("list_matches", { when: "past" }); found = r.matches?.find((x) => x.match_id === id); }
    setM(found || false);
    if (found) sb.from("courts").select("name,address,lat,lng,court_count,is_public,hours").eq("id", found.court.court_id).single().then(({ data }) => setCourt(data));
  }
  const loadMsgs = () => sb.from("messages").select("id,sender_id,body,created_at").eq("match_id", id).order("created_at").limit(200).then(({ data }) => data && setMsgs(data));
  useEffect(() => { load(); loadMsgs(); const t = setInterval(loadMsgs, 10000); return () => clearInterval(t); }, [id]);

  if (m === null || !me) return html`<div class="screen no-tabs"><${Back} to="#/home" label="Home"/><${Spinner}/></div>`;
  if (m === false) return html`<div class="screen no-tabs"><${Back} to="#/home" label="Home"/><div class="empty">This match isn't in your list.</div></div>`;

  const live = m.status === "booked" || m.status === "forming";
  const upcoming = new Date(m.start) > new Date();
  const freeUntil = new Date(new Date(m.start).getTime() - 12 * 36e5);
  const late = m.status === "booked" && freeUntil < new Date();
  const maps = court ? `https://maps.apple.com/?daddr=${court.lat},${court.lng}&q=${encodeURIComponent(court.name)}` : "#";

  async function send() {
    const body = text.trim(); if (!body) return;
    setText("");
    const r = await api("send_message", { match_id: m.match_id, text: body }, true);
    if (r.ok === false) setText(body); else loadMsgs();
  }

  return html`<main class="screen no-tabs" style="gap:18px">
    <${Back} to="#/home" label="Home"/>
    <div class="stack-s" style="gap:4px">
      <div class="eyebrow" style="color:var(--green-text)">${m.status === "forming" ? `Filling · ${m.players.length}/4` : m.status.charAt(0).toUpperCase() + m.status.slice(1)} · ${m.format}</div>
      <h1 class="title2">${dateLong(m.start)}<br/>${timeText(m.start)} – ${timeText(m.end)}</h1>
    </div>

    <div class="card" style=${`display:grid;grid-template-columns:repeat(${Math.min(Math.max(m.players.length, 2), 4) > 2 ? 2 : 2},minmax(0,1fr));gap:14px`}>
      ${m.players.map((p) => html`<div class="stack-s" style="align-items:center;gap:6px"><${Avatar} lg name=${p.player_id === me.player_id ? me.name : p.name}/>
        <div class="b">${p.player_id === me.player_id ? "You" : p.name}</div><div class="small">Team ${p.team}</div></div>`)}
    </div>

    <div class="card flush">
      <div class="list-row" style="align-items:flex-start">
        <${Icon} n="pin" s=${22} c="var(--green-text)" style="flex-shrink:0;margin-top:2px"/>
        <div class="grow stack-s" style="gap:2px"><div class="b">${m.court.name}</div>
          <div class="sub">${court ? [court.address, court.is_public ? "public, first come first served" : "private club", court.hours].filter(Boolean).join(" · ") : ""}</div></div>
        <a href=${maps} target="_blank" rel="noopener" style="font-size:15px;font-weight:600;text-decoration:none;flex-shrink:0">Directions</a>
      </div>
    </div>

    ${live && upcoming ? html`<div style="display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px">
      <a class="btn" href=${icsFor(m)} download="pickup-match.ics"><${Icon} n="cal" s=${18}/>Calendar</a>
      <a class="btn" href="#chat" onClick=${(e) => { e.preventDefault(); document.getElementById("chatbox")?.focus(); }}><${Icon} n="chat" s=${18}/>Message</a>
    </div>` : null}

    <section class="card" style="gap:10px">
      <div class="eyebrow">Match chat</div>
      ${msgs.length ? msgs.map((x) => html`<div class=${"bubble " + (x.sender_id === me.player_id ? "me" : "them")}>${x.body}</div>`) : html`<div class="small">No messages yet.</div>`}
      <div class="row-x" style="gap:8px">
        <input id="chatbox" class="field" style="font-size:16px;padding:10px 12px" placeholder="Message" aria-label="Message" value=${text} onInput=${(e) => setText(e.target.value)} onKeyDown=${(e) => e.key === "Enter" && send()}/>
        <button class="btn primary" style="width:44px;padding:0;flex-shrink:0" aria-label="Send" onClick=${send}><${Icon} n="send" s=${18} c="#fff"/></button>
      </div>
    </section>

    ${live && upcoming ? html`<div class="stack-s" style="align-items:center;gap:4px">
      <button class="btn ghost" style="color:var(--danger)" onClick=${() => openSheet(() => html`<${CancelSheet} m=${m} late=${late} onDone=${() => (location.hash = "#/home")}/>`)}>Cancel match</button>
      <div class="small">${m.status === "forming" ? "Free to cancel while it fills" : late ? "Cancelling now counts against reliability" : `Free to cancel until ${timeText(freeUntil)} ${dateLong(freeUntil)}`}</div>
    </div>` : null}
  </main>`;
}
