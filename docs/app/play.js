import { html, useState, useEffect, useStore, act, openSheet, closeSheet, Sheet, Icon, Avatar, Spinner, Busy, toast } from "./ui.js";
import { api, relDay, timeText, suggestTimes, isoLocal, TZ, zoned, lv } from "./lib.js";

function PickPlayers({ format, picked, onDone }) {
  const [q, setQ] = useState("");
  const [list, setList] = useState(null);
  const [sel, setSel] = useState(picked);
  const max = format === "doubles" ? 3 : 3;
  useEffect(() => {
    const t = setTimeout(() => api("find_players", q ? { name: q, limit: 20 } : { limit: 20, within_miles: 25 }).then((r) => setList(r.players || [])), q ? 250 : 0);
    return () => clearTimeout(t);
  }, [q]);
  const on = (p) => sel.some((x) => x.player_id === p.player_id);
  const toggle = (p) => setSel((s) => (on(p) ? s.filter((x) => x.player_id !== p.player_id) : s.length < max ? [...s, p] : s));
  return html`<${Sheet} label="Pick players">
    <h2 class="h3">Pick players</h2>
    <input class="field" type="search" placeholder="Search by name" aria-label="Search players" value=${q} onInput=${(e) => setQ(e.target.value)}/>
    ${list === null ? html`<${Spinner}/>` : list.length ? html`<div class="card flush">${list.map((p) => html`<button class="list-row" aria-pressed=${on(p)} onClick=${() => toggle(p)}>
        <${Avatar} name=${p.name}/><div class="grow stack-s" style="gap:2px"><div class="b">${p.name}</div>
        <div class="sub">${[lv(p.level), p.reliability_pct != null ? `shows up ${p.reliability_pct}%` : null, p.miles_away != null ? `${p.miles_away} mi` : null, p.played_before ? "played before" : null].filter(Boolean).join(" · ")}</div></div>
        ${on(p) ? html`<${Icon} n="check" s=${22} w=${2.4} c="var(--green-text)"/>` : html`<div style="width:22px"></div>`}</button>`)}</div>`
      : html`<div class="empty">No players found${q ? ` for “${q}”` : " near your level yet"}.</div>`}
    <button class="btn big primary" onClick=${() => { onDone(sel); closeSheet(); }}>${sel.length ? `Done · ${sel.length} picked` : "Done"}</button>
  <//>`;
}

function OtherTime({ onAdd }) {
  const [v, setV] = useState("");
  return html`<${Sheet} label="Pick a time">
    <h2 class="h3">Pick a time</h2>
    <input class="field" type="datetime-local" aria-label="Date and time" value=${v} onInput=${(e) => setV(e.target.value)}/>
    <button class="btn big primary" disabled=${!v} onClick=${() => {
      const [d, t] = v.split("T"); const [y, m, dd] = d.split("-").map(Number); const [hh, mm] = t.split(":").map(Number);
      const when = zoned(y, m, dd, hh, mm);
      if (when.getTime() < Date.now() + 15 * 60000) { toast("Pick a time at least 15 minutes from now.", true); return; }
      onAdd(when); closeSheet();
    }}>Add time</button>
  <//>`;
}

export function Play({ query }) {
  const { me } = useStore();
  const [format, setFormat] = useState("singles");
  const [who, setWho] = useState(query.with ? "pick" : "anyone");
  const [players, setPlayers] = useState(query.with ? [{ player_id: query.with, name: query.name || "Player" }] : []);
  const [extra, setExtra] = useState([]);
  const [times, setTimes] = useState([]);
  const [courts, setCourts] = useState(null);
  const [court, setCourt] = useState(null);
  const [count, setCount] = useState(null);

  const suggested = me ? suggestTimes(me.weekly_availability, { days: 7, noticeHours: 1, max: 5 }) : [];
  const all = [...suggested, ...extra].sort((a, b) => a - b);
  const maxTimes = format === "doubles" ? 1 : 3;

  useEffect(() => { api("find_courts", { limit: 4 }).then((r) => { setCourts(r.courts || []); setCourt((c) => c || r.courts?.[0]?.court_id); }); }, []);
  useEffect(() => { if (!times.length && suggested.length) setTimes([suggested[0].getTime()]); }, [me]);
  useEffect(() => { if (format === "doubles") setTimes((t) => t.slice(0, 1)); }, [format]);
  useEffect(() => { if (who === "anyone") api("find_players", { limit: 30, within_miles: 15 }).then((r) => setCount(r.players?.length ?? 0)); }, [who]);

  if (!me) return html`<div class="screen"><${Spinner}/></div>`;
  const toggleTime = (t) => setTimes((s) => (s.includes(t) ? s.filter((x) => x !== t) : maxTimes === 1 ? [t] : s.length < maxTimes ? [...s, t] : s));
  const level = me.level;
  const ready = times.length && court && (who === "anyone" || players.length);
  const label = who === "anyone" ? (count ? `Post to ${count} player${count === 1 ? "" : "s"} near your level` : "Post open game")
    : `Send to ${players.map((p) => p.name.split(" ")[0]).join(", ") || "players"}`;

  async function send() {
    const slots = times.sort((a, b) => a - b).map((t) => ({ start: isoLocal(new Date(t)), court_id: court }));
    const p = { format, slots, mode: who === "anyone" ? "open" : "direct" };
    if (who !== "anyone") p.invitees = players.map((x) => x.player_id);
    const r = await act("request_match", p);
    if (r.ok !== false) location.hash = "#/home";
  }

  return html`<main class="screen">
    <h1 class="large-title">New match</h1>
    <div class="seg" role="group" aria-label="Format">
      ${["singles", "doubles"].map((f) => html`<button class=${format === f ? "on" : ""} aria-pressed=${format === f} onClick=${() => setFormat(f)}>${f === "singles" ? "Singles" : "Doubles"}</button>`)}
    </div>

    <section class="stack-s" style="gap:8px"><div class="eyebrow">Who</div>
      <div class="chips">
        <button class=${"chip" + (who === "anyone" ? " on" : "")} aria-pressed=${who === "anyone"} onClick=${() => setWho("anyone")}>Anyone ${level ? `${(level - 0.5).toFixed(1)}–${(+level + 0.5).toFixed(1)}` : "at my level"}</button>
        <button class=${"chip" + (who === "pick" ? " on" : "")} aria-pressed=${who === "pick"} onClick=${() => { setWho("pick"); openSheet(() => html`<${PickPlayers} format=${format} picked=${players} onDone=${setPlayers}/>`); }}>${who === "pick" && players.length ? players.map((p) => p.name.split(" ")[0]).join(", ") : "Pick players"}</button>
      </div>
      ${format === "doubles" && who === "pick" ? html`<div class="small">Pick up to 3. It books when four players are in.</div>` : null}
    </section>

    <section class="stack-s" style="gap:8px"><div class="eyebrow">When${maxTimes > 1 ? " · pick up to 3" : ""}</div>
      <div class="time-grid">
        ${all.map((t) => { const k = t.getTime(); const on = times.includes(k); return html`<button class=${"tchip" + (on ? " on" : "")} aria-pressed=${on} onClick=${() => toggleTime(k)}><span class="d">${relDay(t)}</span><span class="t">${timeText(t)}</span></button>`; })}
        <button class="tchip" style="border-style:dashed;background:transparent" onClick=${() => openSheet(() => html`<${OtherTime} onAdd=${(d) => { setExtra((x) => [...x, d]); toggleTime(d.getTime()); }}/>`)}><span class="t" style="font-size:15px">Other…</span></button>
      </div>
      <div class="small">${suggested.length ? "Times come from your weekly availability." : "Add weekly availability in You to get suggestions."}</div>
    </section>

    <section class="stack-s" style="gap:8px"><div class="eyebrow">Where</div>
      ${courts === null ? html`<${Spinner}/>` : html`<div class="card flush">${courts.map((c) => html`<button class="list-row" aria-pressed=${court === c.court_id} onClick=${() => setCourt(c.court_id)}>
        <div style="width:22px">${court === c.court_id ? html`<${Icon} n="check" s=${22} w=${2.2} c="var(--green-text)"/>` : null}</div>
        <div class="grow stack-s" style="gap:1px"><div class="b" style=${court === c.court_id ? "" : "font-weight:500"}>${c.name}</div>
        <div class="small">${[c.home_court ? "Home court" : c.miles_away != null ? `${c.miles_away} mi` : null, c.courts ? `${c.courts} courts` : null, c.public ? "public" : "private club"].filter(Boolean).join(" · ")}</div></div></button>`)}</div>`}
    </section>

    <div class="stack-s" style="gap:8px;margin-top:4px">
      <${Busy} cls="btn big primary" disabled=${!ready} onClick=${send}>${label}<//>
      <div class="small center">${who === "anyone" ? "First to accept books it. You'll see it on Home." : "They pick a time, or suggest another."}</div>
    </div>
  </main>`;
}
