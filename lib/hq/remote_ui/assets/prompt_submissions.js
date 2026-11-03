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

  // Store only this message and its destination. Never store credentials or catalogs.
  function browserStorage() {
    let connection;
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
        const request = action(transaction.objectStore("pending"));
        transaction.oncomplete = () => resolve(request.result);
        transaction.onerror = transaction.onabort = () => reject(new Error("Could not keep your message for retry. Please try again."));
      });
    };
    return {
      all: () => transact("readonly", store => store.getAll()),
      put: entry => transact("readwrite", store => store.put(entry)),
      remove: id => transact("readwrite", store => store.delete(id)),
    };
  }

  class Outbox {
    constructor({ storage, send, onAccepted = () => {}, onError = () => {}, onCancelled = () => {}, onChange = () => {} }) {
      Object.assign(this, { storage, send, onAccepted, onError, onCancelled, onChange });
      this.entries = new Map();
      this.lanes = new Set();
      this.ordinal = 0;
      this.ready = storage.all().then(entries => {
        entries.sort((a, b) => (a.order || 0) - (b.order || 0));
        for (const entry of entries.filter(entry => entry.status !== "cancelled")) this.entries.set(entry.id, { ...entry, status: "uncertain", error: message });
        this.onChange();
      });
    }

    async add(entry) {
      await this.ready;
      entry.status = "waiting";
      entry.order = Date.now() * 1000 + this.ordinal++;
      this.entries.set(entry.id, entry);
      try {
        await this.storage.put(entry);
        entry.saved = true;
      } catch (error) {
        entry.status = "uncertain";
        entry.error = error.message;
        this.onError(entry, error);
      }
      if (this.entries.get(entry.id) !== entry || entry.status === "cancelled") return;
      this.onChange();
      void this.drain(entry.key);
    }

    async retry(id) {
      await this.ready;
      const entry = this.entries.get(id);
      if (!entry || entry.status === "sending" || entry.status === "cancelled") return;
      entry.status = "waiting";
      entry.error = "";
      try {
        await this.storage.put(entry);
        entry.saved = true;
      } catch (error) {
        entry.status = "uncertain";
        entry.error = error.message;
        this.onError(entry, error);
      }
      this.onChange();
      void this.drain(entry.key);
    }

    async cancel(id) {
      await this.ready;
      const entry = this.entries.get(id);
      if (!entry) return;
      // Persist a tombstone before removing the local retry. No server mutation.
      entry.status = "cancelled";
      try { await this.storage.put({id, status: "cancelled"}); }
      catch (error) {
        // A response may have arrived while cancellation was being saved.
        // Keep its original ID uncertain if the browser could not save the stop.
        entry.status = "uncertain";
        this.onChange();
        throw error;
      }
      this.entries.delete(id);
      this.onCancelled(entry);
      this.onChange();
      void this.drain(entry.key);
    }

    async reconcile(key, proofs) {
      await this.ready;
      for (const data of proofs || []) {
        const entry = this.entries.get(data?.receipt?.client_request_id);
        if (!entry || entry.key !== key || entry.status === "cancelled") continue;
        let receipt;
        try { receipt = validateReceipt(data, entry); } catch (_error) { continue; }
        await this.accept(entry, receipt);
      }
    }

    async accept(entry, receipt) {
      if (this.entries.get(entry.id) !== entry || entry.status === "cancelled") return;
      this.entries.delete(entry.id);
      await this.storage.remove(entry.id).catch(() => {});
      try { this.onAccepted(entry, receipt); } catch (_error) { /* Acceptance survives rendering/read failure. */ }
      this.onChange();
      void this.drain(entry.key);
    }

    async drain(key) {
      if (this.lanes.has(key)) return;
      this.lanes.add(key);
      try {
        while (true) {
          const entry = [...this.entries.values()].find(candidate => candidate.key === key);
          if (!entry || entry.status !== "waiting" || !entry.saved) return;
          entry.status = "sending";
          this.onChange();
          let receipt;
          try {
            receipt = validateReceipt(await this.send(entry), entry);
          } catch (error) {
            if (this.entries.get(entry.id) !== entry || entry.status === "cancelled") continue;
            const rejection = error.data?.rejection;
            if (error.status === 409 && rejection?.version === 1 && rejection.client_request_id === entry.id &&
                rejection.agent_key === entry.destination.agent_key && rejection.server_id === entry.destination.server_id) {
              entry.error = error.message;
              error.rejected = true;
              this.entries.delete(entry.id);
              await this.storage.remove(entry.id).catch(() => {});
              this.onError(entry, error);
              this.onChange();
              continue;
            }
            entry.status = "uncertain";
            entry.error = message;
            // The same durable payload and ID remain available after any lost response.
            this.onError(entry, error);
            this.onChange();
            return;
          }
          await this.accept(entry, receipt);
        }
      } finally {
        this.lanes.delete(key);
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
