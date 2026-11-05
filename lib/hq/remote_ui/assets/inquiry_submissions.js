(function initInquirySubmissions(global) {
  const uncertainMessage = "Answer not confirmed. Retry to check if it was saved.";
  const matches = (record, entry) => record?.version === 1 && record.client_request_id === entry.id &&
    record.agent_key === entry.destination.agent_key && record.server_id === entry.destination.server_id &&
    record.inquiry_id === entry.inquiryId;

  function validate(data, entry) {
    const receipt = data?.answer_receipt;
    if (!matches(receipt, entry) || receipt.accepted !== true || typeof receipt.replayed !== "boolean" ||
        !/^\d{4}-\d{2}-\d{2}T/.test(receipt.accepted_at || "") || !Number.isFinite(Date.parse(receipt.accepted_at)) ||
        !(receipt.authority === null || (receipt.authority?.owner === "user" && Number.isInteger(receipt.authority.generation) && receipt.authority.generation > 0)) ||
        !["not_requested", "attempted", "started", "not_started", "superseded", "already_running"].includes(receipt.start_result)) {
      throw new Error(uncertainMessage);
    }
    return receipt;
  }

  function storage() {
    let connection;
    const open = () => connection ||= new Promise((resolve, reject) => {
      const request = global.indexedDB.open("tycho-inquiry-answers", 1);
      request.onupgradeneeded = () => request.result.createObjectStore("answers", {keyPath: "key"});
      request.onsuccess = () => resolve(request.result);
      request.onerror = request.onblocked = () => reject(new Error("Could not keep your answer for retry. Try again."));
    });
    const transaction = async (mode, action) => {
      const db = await open();
      return new Promise((resolve, reject) => {
        const tx = db.transaction("answers", mode);
        const request = action(tx.objectStore("answers"));
        tx.oncomplete = () => resolve(request.result);
        tx.onerror = tx.onabort = () => reject(new Error("Could not keep your answer for retry. Try again."));
      });
    };
    return {all: () => transaction("readonly", store => store.getAll()),
      put: entry => transaction("readwrite", store => store.put(entry)),
      remove: key => transaction("readwrite", store => store.delete(key))};
  }

  class Answers {
    constructor({store, send, changed = () => {}, accepted = () => {}}) {
      Object.assign(this, {store, send, changed, accepted});
      this.entries = new Map();
      this.pendingWrites = new Map();
      this.controllers = new Map();
      this.loaded = false;
      this.ready = store.all().then(entries => {
        for (const entry of entries) this.entries.set(entry.key, {...entry, attemptGeneration: Number(entry.attemptGeneration) || 0,
          retrying: false, status: entry.status === "rejected" ? "rejected" : "uncertain"});
        this.loaded = true;
        changed();
      });
    }
    async add(entry) {
      await this.ready;
      const prior = this.entries.get(entry.key);
      if (prior && prior !== entry && prior.status !== "rejected") throw new Error(uncertainMessage);
      // Storage failure prevents the first write; keep the visible form and its files.
      await this.store.put(entry);
      entry.status = "uncertain";
      this.entries.set(entry.key, entry);
      this.changed();
      return this.retry(entry.key, {initial: true});
    }
    retry(key, {initial = false} = {}) {
      if (!this.loaded) return this.ready.then(() => this.retry(key, {initial}));
      const entry = this.entries.get(key);
      if (!entry) return Promise.resolve(false);
      if (entry.status === "rejected" || entry.status === "sending") return Promise.resolve(false);
      const generation = (Number(entry.attemptGeneration) || 0) + 1;
      entry.attemptGeneration = generation;
      entry.status = "sending";
      entry.retrying = !initial;
      entry.attempted = true;
      const controller = new AbortController();
      this.controllers.set(key, controller);
      this.changed();
      return this.performRetry(key, entry, generation, controller);
    }
    async performRetry(key, entry, generation, controller) {
      const current = () => this.entries.get(key) === entry && entry.attemptGeneration === generation;
      try {
        await this.pendingWrites.get(key);
        if (!current()) return false;
        await this.persist(key, entry);
        if (!current()) return false;
        const data = await this.send(entry, controller.signal);
        if (!current()) return false;
        if (matches(data?.answer_rejection, entry)) {
          entry.status = "rejected";
          entry.retrying = false;
          entry.correctionDraftRestored = false;
          entry.error = String(data.error || "Review your answer and try again.");
          await this.persist(key, entry);
          return false;
        }
        const receipt = validate(data, entry);
        if (!current()) return false;
        // A failed delete retains an exact replay after reload.
        await this.store.remove(key).catch(() => {});
        if (!current()) return false;
        entry.attemptGeneration += 1;
        this.controllers.delete(key);
        this.entries.delete(key);
        this.accepted(entry, receipt, data);
        return true;
      } catch (error) {
        if (!current()) return false;
        entry.status = "uncertain";
        entry.retrying = false;
        entry.error = uncertainMessage;
        await this.persist(key, entry).catch(() => {});
        return false;
      } finally {
        if (current()) {
          entry.retrying = false;
          this.controllers.delete(key);
          this.changed();
        }
      }
    }
    persist(key, entry) {
      const prior = this.pendingWrites.get(key) || Promise.resolve();
      const write = prior.catch(() => {}).then(() => this.store.put(entry));
      this.pendingWrites.set(key, write);
      return write.finally(() => {
        if (this.pendingWrites.get(key) === write) this.pendingWrites.delete(key);
      });
    }
    updateCorrectionDraft(key, correctionDraft) {
      const entry = this.entries.get(key);
      if (!entry || entry.status !== "uncertain") return Promise.resolve(false);
      entry.correctionDraft = correctionDraft;
      return this.persist(key, entry).then(() => true);
    }
    discard(key) {
      const entry = this.entries.get(key);
      if (!entry || !["uncertain", "sending"].includes(entry.status)) return Promise.resolve(false);
      entry.attemptGeneration = (Number(entry.attemptGeneration) || 0) + 1;
      entry.status = "discarded";
      this.controllers.get(key)?.abort();
      this.controllers.delete(key);
      this.entries.delete(key);
      this.changed();
      return (async () => {
        try {
          await this.pendingWrites.get(key)?.catch(() => {});
          await this.store.remove(key);
          return entry;
        } catch (error) {
          if (entry.status === "discarded") {
            entry.status = "uncertain";
            entry.retrying = false;
            this.entries.set(key, entry);
            this.changed();
          }
          throw error;
        }
      })();
    }
  }
  global.TychoInquirySubmissions = {Answers, storage, validate, matches};
})(globalThis);
