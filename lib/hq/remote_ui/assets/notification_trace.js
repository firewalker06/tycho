// Shared by the page and worker. Debug records only; never store request bodies.
(() => {
  const TTL = 24 * 60 * 60 * 1000;
  const LIMIT = 64;
  const BUILD = "__TYCHO_TRACE_BUILD__";
  const SOURCE = typeof document === "undefined" ? "worker" : "page";
  const names = new Set(["click.received", "clients.matched", "client.selected", "navigate.started", "navigate.resolved", "navigate.rejected", "focus.resolved", "focus.rejected", "window.opened", "window.rejected", "page.boot", "app.started", "page.error", "page.rejection", "route.parsed", "request.completed", "request.failed", "notification.loaded", "agent.loaded", "conversation.loaded", "view.rendered"]);
  let storage = "available";
  let queue = Promise.resolve();

  function route(value) {
    try {
      const url = new URL(value, globalThis.location.origin);
      if (url.origin === globalThis.location.origin && /^#(settings|agents|now|setup)$/.test(url.hash)) return `/${url.hash}`;
      const match = url.hash.match(/^#(notification|agent)\/([^/?#]+)$/);
      if (url.origin !== globalThis.location.origin || !match) return "other";
      const key = decodeURIComponent(match[2]);
      if (!/^[A-Za-z0-9_.:-]{1,160}$/.test(key)) return "other";
      return `/#${match[1]}/${encodeURIComponent(key)}`;
    } catch (_) { return "other"; }
  }

  function recordId(value) {
    const normalized = route(value);
    if (!normalized.startsWith("/#notification/")) return null;
    const id = decodeURIComponent(normalized.slice("/#notification/".length));
    return /^debug:[A-Za-z0-9-]{1,80}$/.test(id) ? id : null;
  }

  function clean(name, fields = {}) {
    const event = { name, source: SOURCE, build: BUILD, at: Date.now() };
    if (fields.route !== undefined) event.route = route(fields.route);
    if (typeof fields.same_origin === "boolean") event.same_origin = fields.same_origin;
    if (typeof fields.cached === "boolean") event.cached = fields.cached;
    if (typeof fields.visible === "boolean") event.visible = fields.visible;
    if (typeof fields.loading === "boolean") event.loading = fields.loading;
    if (typeof fields.revision_match === "boolean") event.revision_match = fields.revision_match;
    for (const key of ["count", "status"]) {
      if (Number.isInteger(fields[key]) && fields[key] >= 0) event[key] = Math.min(fields[key], 1000000);
    }
    for (const [key, values] of Object.entries({
      request: ["notification", "agent", "conversation", "conversation-metadata"],
      target_state: ["active", "archived", "archived_missing", "missing"],
      server: ["local", "peer"],
      view: ["notification", "conversation", "empty", "loading", "unavailable", "other"],
    })) {
      if (values.includes(fields[key])) event[key] = fields[key];
    }
    // URL.origin excludes credentials, paths and query strings.
    if (fields.origin !== undefined) {
      try { event.origin = new URL(fields.origin).origin; } catch (_) { /* omit */ }
    }
    return event;
  }

  function transaction(change) {
    if (storage === "unavailable") return Promise.resolve(null);
    return new Promise((resolve) => {
      let db;
      let finished = false;
      const finish = (value, failed = false) => {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        if (db) db.close();
        if (failed) storage = "unavailable";
        resolve(value);
      };
      const timer = setTimeout(() => finish(null, true), 500);
      try {
        const open = indexedDB.open("tycho-notification-trace", 1);
        open.onupgradeneeded = () => open.result.createObjectStore("trace");
        open.onerror = () => finish(null, true);
        open.onblocked = () => finish(null, true);
        open.onsuccess = () => {
          db = open.result;
          if (finished) { db.close(); return; }
          try {
            const tx = db.transaction("trace", "readwrite");
            const store = tx.objectStore("trace");
            const get = store.get("current");
            let result = null;
            get.onsuccess = () => {
              const state = get.result;
              const current = state?.schema === 1 && /^debug:[A-Za-z0-9-]{1,80}$/.test(state.record_id) && Array.isArray(state.events) && state.started_at > Date.now() - TTL ? state : null;
              try {
                result = change(current);
                if (result) store.put(result, "current");
                else store.delete("current");
              } catch (_) { tx.abort(); }
            };
            tx.oncomplete = () => finish(result);
            tx.onerror = tx.onabort = () => finish(null, true);
          } catch (_) { finish(null, true); }
        };
      } catch (_) { finish(null, true); }
    });
  }

  function update(change) {
    queue = queue.then(() => transaction(change)).catch(() => { storage = "unavailable"; return null; });
    return queue;
  }

  function append(state, name, fields) {
    if (!state || !names.has(name)) return state;
    const event = clean(name, fields);
    const eventRoute = event.route || "";
    const expectedRecordRoute = `/#notification/${encodeURIComponent(state.record_id)}`;
    if (eventRoute.startsWith("/#notification/") && eventRoute !== expectedRecordRoute) return state;
    if (name === "notification.loaded" && eventRoute.startsWith("/#agent/")) state.target_route = eventRoute;
    if (state.target_route && eventRoute.startsWith("/#agent/") && eventRoute !== state.target_route) return state;
    const events = [...state.events, event];
    // Keep the click boundary when later polling fills the rolling tail.
    state.events = events.length <= LIMIT ? events : [...events.slice(0, 16), ...events.slice(-(LIMIT - 16))];
    return state;
  }

  const trace = {
    route,
    recordId,
    begin(url) {
      const id = recordId(url);
      if (!id) return Promise.resolve();
      return update(() => ({ schema: 1, record_id: id, started_at: Date.now(), events: [] }));
    },
    record(name, fields = {}) { return update((state) => append(state, name, fields)); },
    clear() { return update(() => null); },
    async snapshot() {
      const state = await update((current) => current);
      const events = (state?.events || []).filter((event) => names.has(event.name)).map((event) => ({ ...clean(event.name, event), source: event.source === "worker" ? "worker" : "page", build: /^[a-f0-9]{12}$/.test(event.build) ? event.build : "unknown", at: Number.isFinite(event.at) ? event.at : 0 }));
      const click = events.some((event) => event.name === "click.received");
      const page = events.some((event) => event.name === "page.boot");
      return { schema: 1, storage, record_id: state?.record_id || null, target_route: state?.target_route ? route(state.target_route) : null, coverage: click && page ? "joined-click-and-page" : click ? "worker-only" : page ? "page-only" : "no-click-observed", events };
    },
  };
  globalThis.TychoNotificationTrace = trace;
  if (SOURCE === "page") {
    update((state) => {
      const id = recordId(location.href);
      if (id && state?.record_id !== id) state = { schema: 1, record_id: id, started_at: Date.now(), events: [] };
      return append(state, "page.boot", { route: location.href, origin: location.origin });
    });
    addEventListener("error", () => { void trace.record("page.error"); });
    addEventListener("unhandledrejection", () => { void trace.record("page.rejection"); });
  }
})();
