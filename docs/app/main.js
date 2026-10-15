import { html, useState, useEffect, useStore, refreshMe, TabBar, Spinner, set, store } from "./ui.js";
import { render } from "https://cdn.jsdelivr.net/npm/htm@3.1.1/preact/standalone.module.js";
import { sb, setTZ } from "./lib.js";
import { Home } from "./home.js";
import { Play } from "./play.js";
import { Match } from "./match.js";
import { SignIn, Setup } from "./setup.js";
import { Players, You, Agents, loadGrants } from "./you.js";

function parse() {
  const h = location.hash.replace(/^#\/?/, "") || "home";
  const [path, qs] = h.split("?");
  const parts = path.split("/");
  return { name: parts[0] || "home", arg: parts[1], query: Object.fromEntries(new URLSearchParams(qs || "")) };
}

function App() {
  const st = useStore();
  const [route, setRoute] = useState(parse());
  const [auth, setAuth] = useState("loading");

  useEffect(() => {
    const on = () => { setRoute(parse()); scrollTo(0, 0); set({ sheet: null }); };
    addEventListener("hashchange", on);
    sb.auth.getSession().then(({ data }) => setAuth(data.session ? "in" : "out"));
    const { data: sub } = sb.auth.onAuthStateChange((_e, s) => setAuth(s ? "in" : "out"));
    return () => { removeEventListener("hashchange", on); sub.subscription.unsubscribe(); };
  }, []);

  useEffect(() => {
    if (auth !== "in") return;
    refreshMe().then((me) => {
      if (me?.ok) { setTZ(me.time_zone); if (!me.onboarded && parse().name !== "setup") location.hash = "#/setup/1"; }
    });
    loadGrants();
  }, [auth]);

  if (auth === "loading") return html`<div class="app"><${Spinner}/></div>`;
  if (auth === "out") return html`<div class="app"><${SignIn}/>${st.toast ? html`<div class=${"toast" + (st.toast.err ? " err" : "")} role="status">${st.toast.text}</div>` : null}</div>`;
  if (!st.me) return html`<div class="app"><${Spinner}/></div>`;

  const { name, arg, query } = route;
  let screen, tabs = true;
  if (name === "play") screen = html`<${Play} key=${location.hash} query=${query}/>`;
  else if (name === "players") screen = html`<${Players}/>`;
  else if (name === "you") screen = html`<${You}/>`;
  else if (name === "agents") screen = html`<${Agents}/>`;
  else if (name === "match") { screen = html`<${Match} id=${arg}/>`; tabs = false; }
  else if (name === "setup") { screen = html`<${Setup} step=${+arg || 1} edit=${!!query.edit}/>`; tabs = false; }
  else screen = html`<${Home}/>`;
  const tab = name === "agents" ? "you" : name;

  return html`<div class="app">
    ${screen}
    ${tabs ? html`<${TabBar} route=${tab}/>` : null}
    ${st.sheet ? st.sheet() : null}
    ${st.toast ? html`<div class=${"toast" + (st.toast.err ? " err" : "")} role="status">${st.toast.text}</div>` : null}
  </div>`;
}

render(html`<${App}/>`, document.getElementById("root"));

if ("serviceWorker" in navigator) navigator.serviceWorker.register(new URL("../sw.js", import.meta.url), { scope: new URL("../", import.meta.url).pathname }).catch(() => {});
