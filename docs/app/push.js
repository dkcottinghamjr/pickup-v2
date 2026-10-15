// Turn on push notifications (iPhone: only after Add to Home Screen, iOS 16.4+).
import { sb } from "./lib.js";
import { toast, store } from "./ui.js";

const VAPID_PUBLIC = "BJjZsDTZ2YzTvVWpdebK-c4c43oR0fu_x9RczU-sgq7-WUh3-amS2EjaJ7whQTZ6voxMeztKP2DF2dRKlSX2Hy4";

function b64ToBytes(s) {
  const pad = "=".repeat((4 - (s.length % 4)) % 4);
  const raw = atob((s + pad).replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}

export async function enablePush() {
  const standalone = matchMedia("(display-mode: standalone)").matches || navigator.standalone;
  if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
    toast(/iPhone|iPad/.test(navigator.userAgent) && !standalone
      ? "First add Pickup to your Home Screen: Share › Add to Home Screen. Then open it from there."
      : "This browser can't show notifications.", true);
    return;
  }
  const perm = await Notification.requestPermission();
  if (perm !== "granted") { toast("Notifications are off. You can turn them on in Settings.", true); return; }
  const reg = await navigator.serviceWorker.ready;
  const sub = (await reg.pushManager.getSubscription()) || (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64ToBytes(VAPID_PUBLIC) }));
  const j = sub.toJSON();
  const { error } = await sb.from("push_subscriptions").upsert(
    { user_id: store.me.player_id, endpoint: j.endpoint, p256dh: j.keys.p256dh, auth: j.keys.auth },
    { onConflict: "endpoint" });
  if (error) toast(error.message, true);
  else toast("Notifications on. You'll hear about invites, bookings and anything that needs your OK.");
}
