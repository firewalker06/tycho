/* Runs in the head before CSS so saved appearance also applies to the boot shell. */
(function (scope) {
  "use strict";

  function createAppearance(window) {
    const key = "hq.remote.appearance";
    const valid = (value) => ["dark", "light", "system"].includes(value);
    let preference = "dark";
    let persistent = true;
    let storage;
    let media;
    try {
      storage = window.localStorage;
      const saved = storage.getItem(key);
      if (valid(saved)) preference = saved;
    } catch (_error) {
      persistent = false;
    }
    try {
      media = window.matchMedia("(prefers-color-scheme: dark)");
    } catch (_error) {
      // An unavailable OS preference keeps System on the existing dark default.
    }

    function getState() {
      const mode = preference === "system" ? (media ? (media.matches ? "dark" : "light") : "dark") : preference;
      return { preference, mode, persistent };
    }

    function apply() {
      const state = getState();
      const root = window.document.documentElement;
      root.dataset.appearance = state.mode;
      root.style.colorScheme = state.mode;
      const meta = window.document.querySelector('meta[name="theme-color"]');
      if (meta) meta.content = state.mode === "light" ? "#e5e9f0" : "#282a36";
      if (window.CustomEvent) {
        window.document.dispatchEvent(new window.CustomEvent("tycho:appearance-change", { detail: state }));
      }
    }

    function setPreference(value) {
      if (!valid(value)) return false;
      preference = value;
      try {
        storage.setItem(key, value);
        persistent = true;
      } catch (_error) {
        persistent = false;
      }
      apply();
      return true;
    }

    function onStorage(event) {
      if (event.key !== key && event.key !== null) return;
      if (event.storageArea && event.storageArea !== storage) return;
      preference = valid(event.newValue) ? event.newValue : "dark";
      apply();
    }
    function onSystemChange() {
      if (preference === "system") apply();
    }
    window.addEventListener("storage", onStorage);
    if (media?.addEventListener) media.addEventListener("change", onSystemChange);
    else media?.addListener?.(onSystemChange);
    apply();
    return { getState, setPreference };
  }

  if (typeof module === "object" && module.exports) module.exports = { createAppearance };
  if (scope.document) scope.TychoAppearance = createAppearance(scope);
})(globalThis);
