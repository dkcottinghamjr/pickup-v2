// Shared UI pieces and a tiny app store.
import { html, useState, useEffect } from "https://cdn.jsdelivr.net/npm/htm@3.1.1/preact/standalone.module.js";
import { api, initials } from "./lib.js";
export { html, useState, useEffect };

// ---- store ----
const listeners = new Set();
export const store = { me: null, inbox: null, open: null, grants: [], toast: null, sheet: null };
export function set(patch) { Object.assign(store, patch); listeners.forEach((f) => f()); }
export function useStore() {
  const [, bump] = useState(0);
  useEffect(() => { const f = () => bump((n) => n + 1); listeners.add(f); return () => listeners.delete(f); }, []);
  return store;
}
let toastTimer;
export function toast(text, err = false) {
  clearTimeout(toastTimer);
  set({ toast: { text, err } });
  toastTimer = setTimeout(() => set({ toast: null }), err ? 5000 : 3000);
}
export function openSheet(render) { set({ sheet: render }); }
export function closeSheet() { set({ sheet: null }); }

export async function refresh() {
  const [inbox, open] = await Promise.all([api("needs_attention"), api("find_open_games")]);
  set({ inbox: inbox.ok ? inbox : store.inbox, open: open.ok ? open.games : store.open });
}
export async function refreshMe() {
  const me = await api("get_me");
  if (me.ok) set({ me });
  return me;
}

// Run an action with a toast; returns the result.
export async function act(action, params, { ok, idem = true } = {}) {
  const r = await api(action, params, idem);
  if (r.ok === false) toast(r.error?.message || "That didn't work.", true);
  else if (ok !== false) toast(ok || r.summary || "Done.");
  refresh();
  return r;
}

// ---- icons (inline stroke SVG) ----
const P = {
  home: html`<path d="M3 10.5 12 3l9 7.5V21h-6v-6H9v6H3z"/>`,
  players: html`<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20c.8-3.5 3.4-5.5 6.5-5.5s5.7 2 6.5 5.5"/><circle cx="17" cy="9" r="2.5"/><path d="M16 14.6c2.7.2 4.6 2 5.3 4.9"/>`,
  you: html`<circle cx="12" cy="8" r="4"/><path d="M4 21c1-4 4.2-6 8-6s7 2 8 6"/>`,
  plus: html`<path d="M12 5v14M5 12h14"/>`,
  back: html`<path d="m15 18-6-6 6-6"/>`,
  chev: html`<path d="m9 18 6-6-6-6"/>`,
  check: html`<path d="M20 6 9 17l-5-5"/>`,
  clock: html`<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>`,
  cal: html`<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>`,
  chat: html`<path d="M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z"/>`,
  pin: html`<path d="M12 21s-7-6.2-7-11.5a7 7 0 0 1 14 0C19 14.8 12 21 12 21z"/><circle cx="12" cy="9.5" r="2.5"/>`,
  bell: html`<path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>`,
  search: html`<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>`,
  send: html`<path d="m22 2-7 20-4-9-9-4z"/><path d="M22 2 11 13"/>`,
  bot: html`<rect x="4" y="7" width="16" height="12" rx="3"/><path d="M12 3v4M9 12h.01M15 12h.01"/>`,
};
export const Icon = ({ n, s = 20, w = 2, c = "currentColor", style = "" }) =>
  html`<svg width=${s} height=${s} viewBox="0 0 24 24" fill="none" stroke=${c} stroke-width=${w} stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style=${style}>${P[n]}</svg>`;

export const Avatar = ({ name, lg, sq }) => html`<div class=${"avatar" + (lg ? " lg" : "") + (sq ? " sq" : "")} aria-hidden="true">${initials(name)}</div>`;
export const Spinner = () => html`<div class="spinner" role="status" aria-label="Loading"></div>`;
export const Back = ({ to = "#/home", label = "Back" }) => html`<a class="back" href=${to}><${Icon} n="back" s=${20} w=${2.4}/>${label}</a>`;

export function TabBar({ route }) {
  const t = (href, key, label, icon) => html`<a class=${"tab" + (route === key ? " on" : "")} href=${href} aria-current=${route === key ? "page" : undefined}>${icon}${label}</a>`;
  return html`<nav class="tabbar" aria-label="Main"><div class="in">
    ${t("#/home", "home", "Home", html`<${Icon} n="home" s=${24}/>`)}
    ${t("#/play", "play", "Play", html`<div class="plus"><${Icon} n="plus" s=${18} w=${2.4} c="#fff"/></div>`)}
    ${t("#/players", "players", "Players", html`<${Icon} n="players" s=${24}/>`)}
    ${t("#/you", "you", "You", html`<${Icon} n="you" s=${24}/>`)}
  </div></nav>`;
}

export function Sheet({ children, label }) {
  useEffect(() => {
    const k = (e) => { if (e.key === "Escape") closeSheet(); };
    addEventListener("keydown", k);
    return () => removeEventListener("keydown", k);
  }, []);
  return html`<div class="scrim" onClick=${closeSheet}></div>
    <div class="sheet" role="dialog" aria-modal="true" aria-label=${label}><div class="grabber"></div>${children}</div>`;
}

export function Busy({ onClick, children, cls = "btn", ...rest }) {
  const [busy, setBusy] = useState(false);
  return html`<button class=${cls} disabled=${busy || rest.disabled} onClick=${async (e) => { setBusy(true); try { await onClick(e); } finally { setBusy(false); } }}>${children}</button>`;
}
