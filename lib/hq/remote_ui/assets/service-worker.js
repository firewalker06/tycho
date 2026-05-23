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
    icon: "/pwa-icon-192.png",
    badge: "/pwa-icon-192.png",
    data: {
      url: payload.url || "/",
    },
  };

  event.waitUntil(self.registration.showNotification(title, options));
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
