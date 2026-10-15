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

  const trace = globalThis.TychoNotificationTrace;
  const traced = !!trace?.recordId(targetUrl);
  if (!traced) {
    event.waitUntil(
      self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clients) => {
        for (const client of clients) {
          if (new URL(client.url).origin !== self.location.origin) continue;
          const navigation = typeof client.navigate === "function" ? client.navigate(targetUrl) : Promise.resolve(client);
          return Promise.resolve(navigation).then((navigatedClient) => {
            const focusTarget = typeof navigatedClient?.focus === "function" ? navigatedClient : client;
            return focusTarget.focus();
          });
        }
        return self.clients.openWindow(targetUrl);
      })
    );
    return;
  }
  const record = (name, fields) => trace.record(name, fields);
  event.waitUntil(
    trace.begin(targetUrl).then(async () => {
      await record("click.received", { route: targetUrl, origin: self.location.origin });
      const clients = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
      await record("clients.matched", { count: clients.length });
      for (const client of clients) {
        const clientUrl = new URL(client.url);
        if (clientUrl.origin !== self.location.origin) continue;
        await record("client.selected", { same_origin: true, route: client.url, origin: clientUrl.origin });
        await record("navigate.started", { route: targetUrl });
        const navigation = typeof client.navigate === "function" ? client.navigate(targetUrl) : Promise.resolve(client);
        return Promise.resolve(navigation).then(async (navigatedClient) => {
          await record("navigate.resolved", { route: navigatedClient?.url || targetUrl });
          const focusTarget = typeof navigatedClient?.focus === "function" ? navigatedClient : client;
          return focusTarget.focus().then(async (result) => {
            await record("focus.resolved");
            return result;
          }, async (error) => {
            await record("focus.rejected");
            throw error;
          });
        }, async (error) => {
          await record("navigate.rejected");
          throw error;
        });
      }
      return self.clients.openWindow(targetUrl).then(async (result) => {
        await record("window.opened", { route: result?.url || targetUrl, visible: !!result });
        return result;
      }, async (error) => {
        await record("window.rejected");
        throw error;
      });
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
