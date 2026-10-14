// Shared Supabase client for the Pickup web pages.
export const SUPABASE_URL = "https://oqqrmyehlnguexnzyvxw.supabase.co";
export const SUPABASE_KEY = "sb_publishable__sgBtE86ux4_z-w4E23QDA_btmzqRsu";
export const BASE = new URL("..", import.meta.url).pathname; // e.g. /pickup-v2/
// deno-lint-ignore no-undef
export const supabase = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { flowType: "pkce", detectSessionInUrl: true, persistSession: true },
});
export const $ = (id) => document.getElementById(id);
export function show(id, on = true) { $(id).classList.toggle("hidden", !on); }
