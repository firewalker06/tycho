(function initPromptSubmissions(global) {
  const message = "Could not confirm your message. Retry to check it safely.";
  const timestamp = value => typeof value === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value) && Number.isFinite(Date.parse(value));
  const authority = value => value === null || (value && ["user", "parent"].includes(value.owner) && Number.isInteger(value.generation) && value.generation > 0);

  function validateReceipt(data, entry) {
    const r = data?.receipt;
    if (!r || data.accepted !== true || r.version !== 1 || r.accepted !== true ||
        r.client_request_id !== entry.id || r.agent_key !== entry.destination.agent_key ||
        r.server_id !== entry.destination.server_id || !["queued", "accepted", "replayed"].includes(r.outcome) ||
        typeof r.replayed !== "boolean" || typeof r.running !== "boolean" ||
        (r.outcome === "replayed" && !r.replayed) || (r.outcome === "accepted" && r.replayed) ||
        !timestamp(r.accepted_at) || typeof r.revision !== "string" || !r.revision || !Number.isFinite(Number(r.revision)) || Number(r.revision) <= 0 ||
        !["user", "parent", "internal_continuation"].includes(r.source) || !authority(r.authority) ||
        data.queued !== (r.outcome === "queued")) throw new Error(message);
    if (r.outcome === "queued") {
      const q = r.queue_entry;
      if (!q || q.id !== entry.id || q.client_request_id !== entry.id || q.state !== "queued" ||
          q.source !== r.source || !timestamp(q.accepted_at) || q.accepted_at !== r.accepted_at ||
          !(q.not_before === null || timestamp(q.not_before)) || !authority(q.authority) ||
          JSON.stringify(q.authority) !== JSON.stringify(r.authority)) throw new Error(message);
    } else if (r.queue_entry !== null) throw new Error(message);
    return r;
  }

  // Cancellation is a storage fence. Notifications only update live views.
  function browserStorage() {
    let connection;
    const listeners = new Set();
    const channel = typeof global.BroadcastChannel === "function" ? new global.BroadcastChannel("tycho-prompt-stops") : null;
    const notify = id => {
      // A notification is only a hint. Read the durable fence before changing UI.
      void transact("readonly", (store, done) => {
        store.get(id).onsuccess = event => done(event.target.result?.status === "cancelled");
      }).then(stopped => { if (stopped) listeners.forEach(listener => listener(id)); }).catch(() => {});
    };
    if (channel) channel.onmessage = event => { if (typeof event.data === "string") notify(event.data); };
    else global.addEventListener?.("storage", event => {
      if (event.key === "hq.prompt-stop" && event.newValue) {
        try { notify(JSON.parse(event.newValue).id); } catch (_error) { /* A malformed hint is not authority. */ }
      }
    });
    const publish = id => {
      notify(id);
      if (channel) channel.postMessage(id);
      else {
        try { global.localStorage.setItem("hq.prompt-stop", JSON.stringify({id, nonce: Math.random()})); } catch (_error) { /* Dispatch still checks IndexedDB. */ }
      }
    };
    const open = () => connection ||= new Promise((resolve, reject) => {
      const request = global.indexedDB.open("tycho-prompt-submissions", 1);
      request.onupgradeneeded = () => request.result.createObjectStore("pending", { keyPath: "id" });
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(new Error("Could not keep your message for retry. Please try again."));
      request.onblocked = () => reject(new Error("Close other Tycho tabs and try again."));
    });
    const transact = async (mode, action) => {
      const db = await open();
      return new Promise((resolve, reject) => {
        const transaction = db.transaction("pending", mode);
        let result;
        action(transaction.objectStore("pending"), value => { result = value; });
        transaction.oncomplete = () => resolve(result);
        transaction.onerror = transaction.onabort = () => reject(new Error("Could not save message state. Browser storage may be full or unavailable. Please try again."));
      });
    };
    return {
      subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); },
      isCancelled: id => transact("readonly", (store, done) => {
        store.get(id).onsuccess = event => done(event.target.result?.status === "cancelled");
      }),
      // Do not materialize or sort cancellation history at startup. Markers are
      // retained without age expiry: a suspended tab can hold an intent forever.
      all: () => transact("readonly", (store, done) => {
        const active = [];
        store.openCursor().onsuccess = event => {
          const cursor = event.target.result;
          if (!cursor) return done(active);
          if (cursor.value.status !== "cancelled") active.push(cursor.value);
          cursor.continue();
        };
      }),
      put: entry => {
        const snapshot = structuredClone(entry);
        return transact("readwrite", (store, done) => {
          store.get(snapshot.id).onsuccess = event => {
            if (event.target.result?.status === "cancelled") return done(false);
            store.put(snapshot);
            done(true);
          };
        });
      },
      cancel: async id => {
        await transact("readwrite", (store, done) => {
          store.put({id, status: "cancelled"});
          done(true);
        });
        publish(id);
      },
      remove: id => transact("readwrite", (store, done) => {
        store.get(id).onsuccess = event => {
          if (event.target.result?.status === "cancelled") return done(false);
          store.delete(id);
          done(true);
        };
      }),
      // Preparation must finish before this gate. Invoke send synchronously in
      // the transaction callback: a committed stop wins, or the request starts
      // before a later cancellation can commit. Do not await HTTP in this gate.
      start: (id, send) => transact("readwrite", (store, done) => {
        store.get(id).onsuccess = event => {
          if (event.target.result?.status === "cancelled") return done({started: false});
          const result = send();
          done({started: true, result});
        };
      }),
    };
  }

  class Outbox {
    constructor({ storage, prepare = async () => {}, send, onAccepted = () => {}, onError = () => {}, onCancelled = () => {}, onChange = () => {} }) {
      Object.assign(this, { storage, prepare, send, onAccepted, onError, onCancelled, onChange });
      this.entries = new Map();
      this.lanes = new Map();
      this.ordinal = 0;
      storage.subscribe?.(id => { void this.ready.then(() => this.applyCancellation(id)).catch(() => {}); });
      this.ready = storage.all().then(entries => {
        entries.filter(entry => entry.status !== "cancelled").sort((a, b) => (a.order || 0) - (b.order || 0))
          .forEach(entry => this.entries.set(entry.id, { ...entry, status: "uncertain", error: message }));
        this.onChange();
      });
    }

    intentFor(id) {
      return this.entries.get(id) || [...this.lanes.values()].find(lane => lane.entry?.id === id)?.entry;
    }

    active(entry) {
      return this.entries.get(entry.id) === entry && entry.status !== "cancelled";
    }

    owns(lane, entry) {
      return this.lanes.get(entry.key) === lane && this.active(entry) && entry.status === "sending";
    }

    kick(key) {
      const next = [...this.entries.values()].find(entry => entry.key === key);
      if (next?.status === "waiting" && next.saved && !this.lanes.has(key)) void this.drain(key);
    }

    release(entry) {
      const lane = this.lanes.get(entry.key);
      if (lane?.entry === entry) this.lanes.delete(entry.key);
      this.kick(entry.key);
    }

    applyCancellation(id) {
      const entry = this.entries.get(id);
      if (!entry) return;
      entry.status = "cancelled";
      this.entries.delete(id);
      this.onCancelled(entry);
      this.onChange();
      // Unknown in-flight work still owns its lane until HTTP settles or proof
      // arrives. Cancelling a waiting retry does not retract that earlier work.
      this.kick(entry.key);
    }

    async save(entry) {
      const saved = await this.storage.put(entry);
      if (saved === false) { this.applyCancellation(entry.id); return false; }
      if (!this.active(entry)) return false;
      entry.saved = true;
      return true;
    }

    async add(entry) {
      await this.ready;
      entry.status = "waiting";
      entry.order = Date.now() * 1000 + this.ordinal++;
      this.entries.set(entry.id, entry);
      try { await this.save(entry); }
      catch (error) { this.fail(entry, error); }
      if (!this.active(entry)) return;
      this.onChange();
      this.kick(entry.key);
    }

    async retry(id) {
      await this.ready;
      const entry = this.entries.get(id);
      if (!entry || entry.status !== "uncertain") return;
      entry.status = "waiting";
      entry.error = "";
      try { await this.save(entry); }
      catch (error) { this.fail(entry, error); }
      if (!this.active(entry)) return;
      this.onChange();
      this.kick(entry.key);
    }

    async cancel(id) {
      await this.ready;
      const entry = this.entries.get(id);
      if (!entry) return;
      entry.status = "cancelled";
      try { await this.storage.cancel(id); }
      catch (error) {
        if (this.entries.get(id) === entry) entry.status = "uncertain";
        this.onChange();
        throw error;
      }
      this.applyCancellation(id);
    }

    async reconcile(key, proofs) {
      await this.ready;
      for (const data of proofs || []) {
        const id = data?.receipt?.client_request_id;
        const entry = this.intentFor(id);
        if (!entry || entry.key !== key) continue;
        let receipt;
        try { receipt = validateReceipt(data, entry); } catch (_error) { continue; }
        // Proof can settle a cancelled in-flight request without applying its
        // composer effects. It is still authority to release that old lane.
        await this.accept(entry, receipt);
      }
    }

    async accept(entry, receipt) {
      if (!this.active(entry)) { this.release(entry); return; }
      if (entry.status === "settling") return;
      entry.status = "settling";
      try {
        const removed = await this.storage.remove(entry.id).catch(() => true);
        if (removed === false) this.applyCancellation(entry.id);
        if (!this.active(entry)) return;
        this.entries.delete(entry.id);
        try { this.onAccepted(entry, receipt); } catch (_error) { /* Acceptance survives rendering/read failure. */ }
        this.onChange();
      } finally {
        this.release(entry);
      }
    }

    fail(entry, error, displayMessage = error.message || message) {
      if (!this.active(entry)) return;
      entry.status = "uncertain";
      entry.error = displayMessage;
      this.onError(entry, error);
      this.onChange();
    }

    async drain(key) {
      if (this.lanes.has(key)) return;
      const lane = {};
      this.lanes.set(key, lane);
      try {
        while (this.lanes.get(key) === lane) {
          const entry = [...this.entries.values()].find(candidate => candidate.key === key);
          if (!entry || entry.status !== "waiting" || !entry.saved) return;
          lane.entry = entry;
          entry.status = "sending";
          this.onChange();
          try {
            await this.prepare(entry);
            if (!this.owns(lane, entry)) return;
            if (!await this.save(entry) || !this.owns(lane, entry)) return;
            const dispatch = await this.storage.start(entry.id, () => {
              if (!this.owns(lane, entry)) return Promise.resolve({cancelled: true});
              // Attach both handlers immediately, including synchronous failures.
              try { return Promise.resolve(this.send(entry)).then(data => ({data}), error => ({error})); }
              catch (error) { return Promise.resolve({error}); }
            });
            if (!dispatch.started) { this.applyCancellation(entry.id); return; }
            const outcome = await dispatch.result;
            if (!this.owns(lane, entry)) return;
            if (outcome.cancelled) return;
            if (outcome.error) throw outcome.error;
            await this.accept(entry, validateReceipt(outcome.data, entry));
          } catch (error) {
            if (!this.owns(lane, entry)) return;
            // A late error must also respect a stop when its tab missed the hint.
            if (await this.storage.isCancelled(entry.id).catch(() => false)) {
              this.applyCancellation(entry.id);
              return;
            }
            if (!this.owns(lane, entry)) return;
            const rejection = error.data?.rejection;
            if (error.status === 409 && rejection?.version === 1 && rejection.client_request_id === entry.id &&
                rejection.agent_key === entry.destination.agent_key && rejection.server_id === entry.destination.server_id) {
              const removed = await this.storage.remove(entry.id).catch(() => true);
              if (removed === false) this.applyCancellation(entry.id);
              if (!this.active(entry)) return;
              error.rejected = true;
              this.entries.delete(entry.id);
              entry.error = error.message;
              this.onError(entry, error);
              this.onChange();
              continue;
            }
            this.fail(entry, error, message);
            return;
          }
        }
      } finally {
        // A late old response cannot unlock a newer drain.
        if (this.lanes.get(key) === lane) {
          this.lanes.delete(key);
          this.kick(key);
        }
      }
    }
  }

  function createReconciler(read, onError = () => {}) {
    let pending = false, running = false;
    const drain = async () => {
      if (running) return;
      running = true;
      try {
        while (pending) {
          pending = false;
          try { await read(); } catch (error) { onError(error); }
        }
      } finally { running = false; }
    };
    return { request() { pending = true; setTimeout(() => { void drain(); }, 0); } };
  }

  global.TychoPromptSubmissions = { validateReceipt, browserStorage, Outbox, createReconciler };
})(globalThis);
