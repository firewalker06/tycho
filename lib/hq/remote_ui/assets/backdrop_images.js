/* Browser-only raster storage. No image bytes or URLs enter theme JSON or the API. */
(function (scope) {
  "use strict";
  const MAX_BYTES = 5 * 1024 * 1024;
  const formats = ["image/png", "image/jpeg", "image/webp"];
  const modes = ["dark", "light"];
  const settings = { intensity: 0.65, fade: 0.65, x: 50, y: 50 };

  function dimensions(bytes, type) {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const ascii = (start, length) => String.fromCharCode(...bytes.slice(start, start + length));
    if (type === "image/png" && bytes.length >= 24 && ascii(1, 3) === "PNG" && view.getUint32(0) === 0x89504e47 && view.getUint32(4) === 0x0d0a1a0a && ascii(12, 4) === "IHDR") return [view.getUint32(16), view.getUint32(20)];
    if (type === "image/webp" && bytes.length >= 30 && ascii(0, 4) === "RIFF" && ascii(8, 4) === "WEBP") {
      const chunk = ascii(12, 4);
      if (chunk === "VP8X") return [1 + bytes[24] + (bytes[25] << 8) + (bytes[26] << 16), 1 + bytes[27] + (bytes[28] << 8) + (bytes[29] << 16)];
      if (chunk === "VP8 " && ascii(23, 3) === "\x9d\x01\x2a") return [view.getUint16(26, true) & 0x3fff, view.getUint16(28, true) & 0x3fff];
      if (chunk === "VP8L" && bytes[20] === 0x2f) return [1 + bytes[21] + ((bytes[22] & 0x3f) << 8), 1 + (bytes[22] >> 6) + (bytes[23] << 2) + ((bytes[24] & 0xf) << 10)];
    }
    if (type === "image/jpeg" && bytes[0] === 0xff && bytes[1] === 0xd8) {
      let offset = 2;
      while (offset + 4 <= bytes.length) {
        if (bytes[offset++] !== 0xff) break;
        while (bytes[offset] === 0xff) offset++;
        const marker = bytes[offset++];
        if (marker === 0xda || marker === 0xd9) break;
        if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
        if (offset + 2 > bytes.length) break;
        const size = view.getUint16(offset);
        if (size < 2 || offset + size > bytes.length) break;
        if ([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].includes(marker) && size >= 7) return [view.getUint16(offset + 5), view.getUint16(offset + 3)];
        offset += size;
      }
    }
    throw new Error("This file is not a supported PNG, JPEG, or WebP image.");
  }
  function checkDimensions(width, height) {
    if (!width || !height || width > 4096 || height > 4096 || width * height > 12000000) throw new Error("Image dimensions must be at most 4096 pixels per side and 12 megapixels.");
  }
  async function inspect(blob) {
    if (!formats.includes(blob.type)) throw new Error("Choose a PNG, JPEG, or WebP raster image. SVG and URLs are not supported.");
    if (!blob.size || blob.size > MAX_BYTES) throw new Error("Choose an image no larger than 5 MiB.");
    const size = dimensions(new Uint8Array(await blob.arrayBuffer()), blob.type);
    checkDimensions(...size);
  }

  function createBackdropImages(window) {
    let database;
    let opening;
    let records = {};
    let cache = {};
    let error = "";
    let loaded = false;
    let generation = 0;
    let disposed = false;
    const versions = { dark: 0, light: 0 };
    const busy = new Set();
    let channel;
    const identifier = () => window.crypto?.randomUUID?.() || `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const savedSettings = record => Object.fromEntries(Object.keys(settings).filter(key => Number.isFinite(record?.[key]) && record[key] >= 0 && record[key] <= (["x", "y"].includes(key) ? 100 : 1)).map(key => [key, record[key]]));
    const mode = () => window.TychoAppearance.getState().mode;
    function notify() {
      apply();
      window.document.dispatchEvent(new window.CustomEvent("tycho:backdrop-images-change"));
    }
    function open() {
      if (database) return Promise.resolve(database);
      if (opening) return opening;
      opening = new Promise((resolve, reject) => {
        let finished = false;
        const fail = () => { if (!finished) { finished = true; reject(new Error("Image storage is unavailable. Allow site storage, close older tabs, then retry.")); } };
        const timer = window.setTimeout(fail, 4000);
        let request;
        try { request = window.indexedDB.open("tycho-backdrop-images", 1); } catch (_error) { window.clearTimeout(timer); fail(); return; }
        request.onupgradeneeded = () => { request.result.createObjectStore("backdrops", { keyPath: "mode" }); };
        request.onerror = request.onblocked = () => { window.clearTimeout(timer); fail(); };
        request.onsuccess = () => {
          window.clearTimeout(timer);
          if (finished || disposed) { request.result.close(); return; }
          finished = true;
          database = request.result;
          database.onversionchange = () => { database.close(); database = null; opening = null; };
          resolve(database);
        };
      }).catch(cause => { opening = null; throw cause; });
      return opening;
    }
    async function read() {
      const db = await open();
      return new Promise((resolve, reject) => {
        const transaction = db.transaction("backdrops", "readonly");
        const request = transaction.objectStore("backdrops").getAll();
        transaction.oncomplete = () => resolve(request.result);
        transaction.onabort = transaction.onerror = () => reject(new Error("Cannot read saved images. Retry image storage."));
      });
    }
    async function write(target, update) {
      const db = await open();
      return new Promise((resolve, reject) => {
        const transaction = db.transaction("backdrops", "readwrite");
        const store = transaction.objectStore("backdrops");
        const request = store.get(target);
        request.onsuccess = () => {
          try {
            const next = update(request.result);
            if (next === null) store.delete(target);
            else if (next) store.put(next);
          } catch (_error) { transaction.abort(); }
        };
        transaction.oncomplete = resolve;
        transaction.onabort = transaction.onerror = () => reject(new Error("Cannot save this image. Site storage may be full or blocked. The previous image is unchanged."));
      });
    }
    async function refresh() {
      const stamp = ++generation;
      const created = [];
      try {
        const saved = await read();
        const nextRecords = {}, nextCache = {};
        for (const record of saved) {
          if (!modes.includes(record.mode)) continue;
          nextRecords[record.mode] = record;
          if (record.assetId && record.blob instanceof window.Blob && formats.includes(record.blob.type) && record.blob.size === cache[record.mode]?.bytes && record.assetId === cache[record.mode]?.assetId) { nextCache[record.mode] = cache[record.mode]; continue; }
          let url;
          try {
            await inspect(record.blob);
            url = window.URL.createObjectURL(record.blob);
            created.push(url);
            const image = new window.Image(); image.src = url; await image.decode();
            checkDimensions(image.naturalWidth, image.naturalHeight);
            nextCache[record.mode] = { assetId: record.assetId, url, bytes: record.blob.size };
          } catch (_error) {
            if (url) window.URL.revokeObjectURL(url);
            nextCache[record.mode] = { error: "Saved image is missing or damaged. Choose another image or remove it." };
          }
        }
        if (stamp !== generation || disposed) { created.forEach(url => window.URL.revokeObjectURL(url)); return; }
        for (const [target, item] of Object.entries(cache)) if (item.url && item.url !== nextCache[target]?.url) window.URL.revokeObjectURL(item.url);
        records = nextRecords; cache = nextCache; loaded = true; error = "";
      } catch (cause) { if (stamp !== generation || disposed) return; error = cause.message; loaded = true; }
      notify();
    }
    function getState() {
      const target = mode(), record = records[target], item = cache[target];
      return { mode: target, loaded, busy: busy.has(target), error: error || item?.error || "", image: record ? {
        name: record.name, width: record.width, height: record.height, bytes: record.blob?.size || 0, mime: record.blob?.type,
        ...settings, ...savedSettings(record), url: item?.url || ""
      } : null };
    }
    function apply() {
      const state = getState(), root = window.document.documentElement;
      root.dataset.imageBackdrop = state.image?.url ? "ready" : loaded ? "none" : "loading";
      const props = { "--theme-raster-image": state.image?.url ? `url("${state.image.url}")` : "none", "--theme-raster-opacity": String(state.image?.intensity ?? 0),
        "--theme-raster-position": `${state.image?.x ?? 50}% ${state.image?.y ?? 50}%`, "--theme-raster-fade": `${(state.image?.fade ?? 0) * 100}%` };
      for (const [key, value] of Object.entries(props)) root.style.setProperty(key, value);
    }
    function broadcast() {
      try { channel?.postMessage("changed"); } catch (_error) { /* Focus refresh remains available. */ }
      try { window.localStorage.setItem("hq.remote.backdrops.changed", identifier()); } catch (_error) { /* Blobs never use localStorage. */ }
    }
    async function mutate(target, action) {
      if (!modes.includes(target)) throw new Error("Select Dark or Light mode first.");
      const version = ++versions[target];
      busy.add(target); error = ""; notify();
      try {
        await action(version);
        if (version !== versions[target]) return;
        await refresh(); broadcast();
      } catch (cause) { if (version === versions[target]) error = `${target} image: ${cause.message}`; throw cause; }
      finally { if (version === versions[target]) busy.delete(target); notify(); }
    }
    async function choose(file, target = mode()) {
      return mutate(target, async version => {
        await inspect(file);
        let bitmap;
        try { bitmap = await window.createImageBitmap(file); } catch (_error) { throw new Error("The image could not be decoded. Choose a different file."); }
        let blob, width, height;
        try {
          checkDimensions(bitmap.width, bitmap.height);
          const scale = Math.min(1, 2560 / Math.max(bitmap.width, bitmap.height));
          width = Math.max(1, Math.round(bitmap.width * scale)); height = Math.max(1, Math.round(bitmap.height * scale));
          const canvas = window.document.createElement("canvas"); canvas.width = width; canvas.height = height;
          const context = canvas.getContext("2d");
          if (!context) throw new Error("Image processing is unavailable. Choose a smaller image or retry.");
          context.drawImage(bitmap, 0, 0, width, height);
          blob = await new Promise(resolve => canvas.toBlob(resolve, "image/webp", 0.9));
          canvas.width = canvas.height = 1;
          if (!blob || !formats.includes(blob.type) || blob.size > MAX_BYTES) throw new Error("The saved raster copy is too large. Choose a smaller image.");
        } finally { bitmap.close(); }
        if (version !== versions[target]) return;
        const assetId = identifier();
        await write(target, current => version === versions[target] ? { ...settings, ...savedSettings(current), mode: target, assetId,
          name: String(file.name || "Local image").slice(0, 120), blob, width, height } : undefined);
      });
    }
    async function update(values, target = mode()) {
      const next = {};
      for (const [key, value] of Object.entries(values)) {
        if (!Object.hasOwn(settings, key) || typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > (["x", "y"].includes(key) ? 100 : 1)) throw new Error("Invalid image backdrop setting.");
        next[key] = value;
      }
      return mutate(target, async version => write(target, current => current && version === versions[target] ? { ...current, ...next } : undefined));
    }
    async function remove(target = mode()) { return mutate(target, async version => write(target, () => version === versions[target] ? null : undefined)); }
    function dispose() {
      disposed = true; generation++;
      Object.values(cache).forEach(item => { if (item.url) window.URL.revokeObjectURL(item.url); });
      cache = {}; database?.close(); channel?.close();
    }
    window.document.addEventListener("tycho:appearance-change", apply);
    window.addEventListener("storage", event => { if (event.key === "hq.remote.backdrops.changed" || event.key === null) void refresh(); });
    window.addEventListener("focus", () => { void refresh(); });
    window.document.addEventListener("visibilitychange", () => { if (!window.document.hidden) void refresh(); });
    window.addEventListener("pagehide", event => { if (!event.persisted) dispose(); });
    try { channel = new window.BroadcastChannel("tycho-backdrop-images"); channel.onmessage = () => { void refresh(); }; } catch (_error) { /* Storage events and focus provide fallbacks. */ }
    apply(); void refresh();
    return { getState, choose, update, remove, refresh, dispose };
  }
  if (typeof module === "object" && module.exports) module.exports = { dimensions, checkDimensions, inspect };
  if (scope.document) scope.TychoBackdropImages = createBackdropImages(scope);
})(globalThis);
