self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener("push", (event) => {
  let payload = {};
  if (event.data) {
    try {
      payload = event.data.json();
    } catch (_error) {
      payload = { body: event.data.text() };
    }
  }

  const title = payload.title || "Tycho";
  const options = {
    body: payload.body || "Tycho has an update.",
    tag: payload.tag || "hq-remote",
    renotify: Boolean(payload.renotify && payload.tag),
    silent: payload.silent === true,
    icon: "/pwa-icon-192.png",
    badge: "/pwa-icon-192.png",
    data: {
      url: payload.url || "/",
    },
  };

  const badgePromise = Object.prototype.hasOwnProperty.call(payload, "badge_count")
    ? syncAppBadge(payload.badge_count)
    : Promise.resolve();
  event.waitUntil(
    badgePromise.then(() => self.registration.showNotification(title, options))
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const targetUrl = new URL(event.notification.data?.url || "/", self.location.origin).href;

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clients) => {
      for (const client of clients) {
        const clientUrl = new URL(client.url);
        if (clientUrl.origin !== self.location.origin) continue;
        if (typeof client.navigate === "function") client.navigate(targetUrl);
        return client.focus();
      }
      return self.clients.openWindow(targetUrl);
    })
  );
});

function syncAppBadge(count) {
  if (!("setAppBadge" in self.navigator) || !("clearAppBadge" in self.navigator)) {
    return Promise.resolve();
  }

  const number = Number(count);
  if (!Number.isFinite(number) || number <= 0) {
    return self.navigator.clearAppBadge().catch(() => {});
  }

  return self.navigator.setAppBadge(Math.trunc(number)).catch(() => {});
}
