import { html, useState, useEffect, useStore, refreshMe, toast, Icon, Spinner, Busy, Back } from "./ui.js";
import { api, sb, BASE, LEVELS } from "./lib.js";

export function SignIn() {
  const [email, setEmail] = useState("");
  const [adult, setAdult] = useState(false);
  const [sent, setSent] = useState(false);
  const send = async () => {
    if (!/^\S+@\S+\.\S+$/.test(email.trim())) { toast("Enter your email address.", true); return; }
    const { error } = await sb.auth.signInWithOtp({ email: email.trim(), options: { emailRedirectTo: location.origin + BASE } });
    if (error) toast(error.message, true); else setSent(true);
  };
  return html`<main class="screen no-tabs" style="padding-top:calc(env(safe-area-inset-top) + 48px)">
    <div class="brand"><span class="ball"></span>Pickup</div>
    <div class="stack-s" style="gap:8px"><h1 class="title2">Tennis matches, booked for you</h1>
      <p class="p">Find players at your level, agree on a time and court, and let your AI agent handle the back-and-forth, within rules you set.</p></div>
    ${sent ? html`<div class="card"><div class="b">Check your email</div><p class="p">We sent a sign-in link to ${email}. Open it on this device to finish.</p>
        <button class="btn ghost" onClick=${() => setSent(false)}>Use a different email</button></div>`
      : html`<div class="stack">
        <label class="lbl" for="email">Email</label>
        <input id="email" class="field" type="email" autocomplete="email" inputmode="email" placeholder="you@example.com" value=${email} onInput=${(e) => setEmail(e.target.value)} onKeyDown=${(e) => e.key === "Enter" && adult && send()}/>
        <label class="check"><input type="checkbox" checked=${adult} onChange=${(e) => setAdult(e.target.checked)}/><span>I'm 18 or older</span></label>
        <${Busy} cls="btn big primary" disabled=${!adult} onClick=${send}>Email me a sign-in link<//>
        <div class="small center">Pickup is in a private pilot in Charlotte.</div>
      </div>`}
  </main>`;
}

const Progress = ({ step }) => html`<div class="progress" aria-label=${`Step ${step} of 3`}>${[1, 2, 3].map((i) => html`<div class=${i <= step ? "on" : ""}></div>`)}</div>`;

function StepLevel({ me, next, edit }) {
  const [name, setName] = useState(me.name || "");
  const [lvl, setLvl] = useState(me.self_level ? +me.self_level : null);
  return html`<main class="screen no-tabs" style="gap:18px">
    ${edit ? html`<${Back} to="#/you" label="You"/>` : html`<${Progress} step=${1}/>`}
    <div class="stack-s" style="gap:6px">${edit ? null : html`<div class="eyebrow">Step 1 of 3</div>`}<h1 class="title2">${edit ? "Name and level" : "Welcome. What should players call you?"}</h1></div>
    <input class="field" aria-label="Your name" placeholder="First name and last initial" value=${name} onInput=${(e) => setName(e.target.value)} maxlength="60"/>
    <div class="stack-s" style="gap:6px"><div class="b">Your level</div><div class="sub">Pick the closest. Your Pickup Rating takes over after 5 matches.</div></div>
    <div class="stack-s" style="gap:8px">${LEVELS.map((l) => html`<button class=${"level" + (lvl === l.v ? " on" : "")} aria-pressed=${lvl === l.v} onClick=${() => setLvl(l.v)}>
      <div class="n">${l.v.toFixed(1)}</div><div class="stack-s" style="gap:2px"><div class="b">${l.t}</div><div class="sub">${l.d}</div></div></button>`)}</div>
    <${Busy} cls="btn big primary" disabled=${!name.trim() || !lvl} onClick=${async () => {
      const { error } = await sb.from("profiles").update({ display_name: name.trim(), self_level: lvl }).eq("id", me.player_id);
      if (error) { toast(error.message, true); return; }
      await refreshMe(); next();
    }}>${edit ? "Save" : "Continue"}<//>
  </main>`;
}

const miles = (a, b, c, d) => { const r = (x) => (x * Math.PI) / 180; const h = Math.sin(r(c - a) / 2) ** 2 + Math.cos(r(a)) * Math.cos(r(c)) * Math.sin(r(d - b) / 2) ** 2; return 3958.8 * 2 * Math.asin(Math.sqrt(h)); };

function StepCourts({ me, next, edit }) {
  const [courts, setCourts] = useState(null);
  const [sel, setSel] = useState(me.home_courts.map((c) => c.court_id));
  const [here, setHere] = useState(null);
  const [q, setQ] = useState("");
  useEffect(() => { sb.from("courts").select("id,name,address,lat,lng,is_public,court_count").order("name").then(({ data }) => setCourts(data || [])); }, []);
  const locate = () => navigator.geolocation?.getCurrentPosition((p) => setHere([p.coords.latitude, p.coords.longitude]), () => toast("Couldn't get your location. Search instead.", true), { timeout: 8000 });
  const toggle = (id) => setSel((s) => (s.includes(id) ? s.filter((x) => x !== id) : s.length < 3 ? [...s, id] : s));
  let list = (courts || []).filter((c) => !q || (c.name + " " + c.address).toLowerCase().includes(q.toLowerCase()));
  if (here) list = list.map((c) => ({ ...c, d: miles(here[0], here[1], c.lat, c.lng) })).sort((a, b) => a.d - b.d);
  list.sort((a, b) => (sel.includes(b.id) ? 1 : 0) - (sel.includes(a.id) ? 1 : 0));
  return html`<main class="screen no-tabs" style="gap:18px">
    ${edit ? html`<${Back} to="#/you" label="You"/>` : html`<${Progress} step=${2}/>`}
    <div class="stack-s" style="gap:6px">${edit ? null : html`<div class="eyebrow">Step 2 of 3</div>`}<h1 class="title2">Where do you like to play?</h1>
      <p class="p">Pick up to 3 home courts. Your agent can book these, or anywhere within 5 miles.</p></div>
    <div class="row-x" style="gap:8px">
      <input class="field" type="search" placeholder="Search courts" aria-label="Search courts" value=${q} onInput=${(e) => setQ(e.target.value)}/>
      <button class="btn" style="flex-shrink:0" onClick=${locate}><${Icon} n="pin" s=${18}/>Near me</button>
    </div>
    ${courts === null ? html`<${Spinner}/>` : html`<div class="card flush">${list.slice(0, 30).map((c) => html`<button class="list-row" aria-pressed=${sel.includes(c.id)} onClick=${() => toggle(c.id)}>
      <div style="width:22px">${sel.includes(c.id) ? html`<${Icon} n="check" s=${22} w=${2.2} c="var(--green-text)"/>` : null}</div>
      <div class="grow stack-s" style="gap:1px"><div class="b" style=${sel.includes(c.id) ? "" : "font-weight:500"}>${c.name}</div>
      <div class="small">${[c.d != null ? `${c.d.toFixed(1)} mi` : null, `${c.court_count} courts`, c.is_public ? "public" : "private club"].join(" · ")}</div></div></button>`)}</div>`}
    <${Busy} cls="btn big primary" disabled=${!sel.length} onClick=${async () => {
      const del = await sb.from("home_courts").delete().eq("user_id", me.player_id);
      if (del.error) { toast(del.error.message, true); return; }
      const ins = await sb.from("home_courts").insert(sel.map((id, i) => ({ user_id: me.player_id, court_id: id, rank: i + 1 })));
      if (ins.error) { toast(ins.error.message, true); return; }
      const first = courts.find((c) => c.id === sel[0]);
      await sb.from("profiles").update({ area_lat: Math.round(first.lat * 100) / 100, area_lng: Math.round(first.lng * 100) / 100, city: "Charlotte" }).eq("id", me.player_id);
      await refreshMe(); next();
    }}>${edit ? "Save" : "Continue"}<//>
  </main>`;
}

const PARTS = [["Morning", "07:00", "11:00", "7–11"], ["Midday", "11:00", "16:00", "11–4"], ["Evening", "17:00", "21:00", "5–9"]];
const DAYS = [[1, "Mon"], [2, "Tue"], [3, "Wed"], [4, "Thu"], [5, "Fri"], [6, "Sat"], [0, "Sun"]];

function StepTimes({ me, done, edit }) {
  const init = new Set();
  for (const w of me.weekly_availability) PARTS.forEach(([, s, e], i) => { if (w.start < e && w.end > s) init.add(`${w.weekday}-${i}`); });
  const [on, setOn] = useState(init);
  const custom = me.weekly_availability.some((w) => !PARTS.some(([, s, e]) => w.start === s && w.end === e));
  const flip = (k) => setOn((s) => { const n = new Set(s); n.has(k) ? n.delete(k) : n.add(k); return n; });
  const hours = [...on].reduce((h, k) => { const i = +k.split("-")[1]; const [, s, e] = PARTS[i]; return h + (parseInt(e) - parseInt(s)); }, 0);
  return html`<main class="screen no-tabs" style="gap:18px">
    ${edit ? html`<${Back} to="#/you" label="You"/>` : html`<${Progress} step=${3}/>`}
    <div class="stack-s" style="gap:6px">${edit ? null : html`<div class="eyebrow">Step 3 of 3</div>`}<h1 class="title2">When can you usually play?</h1>
      <p class="p">Tap the times that work most weeks. Your agent books only inside these unless you OK it.</p></div>
    <div class="card avail" style="padding:12px">
      <div class="r"><div></div>${PARTS.map((p) => html`<div class="hd">${p[0]}</div>`)}</div>
      ${DAYS.map(([d, n]) => html`<div class="r"><div class="b" style="font-size:15px">${n}</div>
        ${PARTS.map((p, i) => { const k = `${d}-${i}`; return html`<button class=${"cell" + (on.has(k) ? " on" : "")} aria-pressed=${on.has(k)} aria-label=${`${n} ${p[0]}`} onClick=${() => flip(k)}>${p[3]}</button>`; })}</div>`)}
    </div>
    <div class="small">Morning 7–11 · Midday 11–4 · Evening 5–9.${custom ? " Saving replaces your current custom hours." : ""}</div>
    <div class="stack-s" style="gap:8px">
      <${Busy} cls="btn big primary" disabled=${!on.size} onClick=${async () => {
        const weekly = [...on].map((k) => { const [d, i] = k.split("-").map(Number); return { weekday: d, start: PARTS[i][1], end: PARTS[i][2] }; });
        const r = await api("update_availability", { weekly });
        if (r.ok === false) { toast(r.error.message, true); return; }
        if (!me.onboarded) await sb.from("profiles").update({ onboarded: true }).eq("id", me.player_id);
        await refreshMe(); done();
      }}>${edit ? "Save" : "Finish setup"}<//>
      <div class="small center">${on.size} window${on.size === 1 ? "" : "s"} a week · about ${hours} hours</div>
    </div>
  </main>`;
}

export function Setup({ step, edit }) {
  const { me } = useStore();
  if (!me) return html`<div class="screen"><${Spinner}/></div>`;
  const go = (n) => (location.hash = edit ? "#/you" : `#/setup/${n}`);
  if (step === 2) return html`<${StepCourts} me=${me} edit=${edit} next=${() => go(3)}/>`;
  if (step === 3) return html`<${StepTimes} me=${me} edit=${edit} done=${() => (location.hash = edit ? "#/you" : "#/home")}/>`;
  return html`<${StepLevel} me=${me} edit=${edit} next=${() => go(2)}/>`;
}
