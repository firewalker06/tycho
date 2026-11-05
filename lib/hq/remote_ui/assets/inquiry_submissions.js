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
      this.ready = store.all().then(entries => {
        for (const entry of entries) this.entries.set(entry.key, {...entry, status: entry.status === "rejected" ? "rejected" : "uncertain"});
        changed();
      });
    }
    async add(entry) {
      await this.ready;
      const prior = this.entries.get(entry.key);
      if (prior && prior !== entry && prior.status !== "rejected") throw new Error(uncertainMessage);
      // Storage failure prevents the first write; keep the visible form and its files.
      await this.store.put(entry);
      entry.status = "sending";
      this.entries.set(entry.key, entry);
      this.changed();
      return this.retry(entry.key, {resumeSending: true});
    }
    async retry(key, {resumeSending = false} = {}) {
      await this.ready;
      const entry = this.entries.get(key);
      if (!entry || entry.status === "rejected" || (entry.status === "sending" && !resumeSending)) return;
      try {
        await this.pendingWrites.get(key);
        if (!resumeSending) {
          await this.store.put(entry);
          entry.status = "sending";
          this.changed();
        }
        const data = await this.send(entry);
        if (matches(data?.answer_rejection, entry)) {
          entry.status = "rejected";
          entry.error = String(data.error || "Review your answer and try again.");
          await this.store.put(entry);
          return;
        }
        const receipt = validate(data, entry);
        // A failed delete retains an exact replay after reload.
        await this.store.remove(key).catch(() => {});
        this.entries.delete(key);
        this.accepted(entry, receipt, data);
      } catch (error) {
        entry.status = "uncertain";
        entry.error = uncertainMessage;
        await this.store.put(entry).catch(() => {});
      } finally {
        this.changed();
      }
    }
    updateAnswer(key, answer, preview) {
      const entry = this.entries.get(key);
      if (!entry || entry.status !== "uncertain") return Promise.resolve(false);
      entry.payload = {...entry.payload, answer};
      entry.preview = preview;
      const prior = this.pendingWrites.get(key) || Promise.resolve();
      const write = prior.then(() => this.store.put(entry)).then(() => true);
      this.pendingWrites.set(key, write);
      return write.finally(() => {
        if (this.pendingWrites.get(key) === write) this.pendingWrites.delete(key);
      });
    }
    async discard(key) {
      await this.ready;
      await this.pendingWrites.get(key);
      const entry = this.entries.get(key);
      if (!entry || entry.status !== "uncertain") return false;
      await this.store.remove(key);
      this.entries.delete(key);
      this.changed();
      return entry;
    }
  }
  global.TychoInquirySubmissions = {Answers, storage, validate, matches};
})(globalThis);
