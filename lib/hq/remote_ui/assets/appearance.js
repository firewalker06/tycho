/* Runs in the head before CSS so saved appearance also applies to the boot shell. */
(function (scope) {
  "use strict";

  function createAppearance(window) {
    const key = "hq.remote.appearance";
    const themesKey = "hq.remote.themes.v1";
    const defaults = { dark: "dracula", light: "nord" };
    const roles = ["canvas", "surface", "sunken", "text", "muted", "border", "accent", "inverse", "info", "success", "warning", "danger"];
    const sample = { id: "midnight", name: "Midnight", mode: "dark", colors: {
      canvas: "#17152b", surface: "#242039", sunken: "#100f20", text: "#f4edff", muted: "#c0b5d4", border: "#807099",
      accent: "#c9a0ff", inverse: "#17152b", info: "#88dcf0", success: "#9fe3b0", warning: "#f7cc85", danger: "#ff929f"
    } };
    const lightSample = { id: "sandstone", name: "Sandstone", mode: "light", colors: {
      canvas: "#f4efe6", surface: "#fffcf5", sunken: "#e4dccc", text: "#282d3b", muted: "#51586b", border: "#626879",
      accent: "#a9c7e6", inverse: "#282d3b", info: "#234f85", success: "#b4d4b0", warning: "#f0d18b", danger: "#a53743"
    } };
    let themes = { selected: { ...defaults }, custom: [] };
    let themePersistent = true;
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
    function validateTheme(value) {
      if (!value || typeof value !== "object" || typeof value.id !== "string" || !/^[a-z][a-z0-9-]{0,39}$/.test(value.id) || Object.values(defaults).includes(value.id)) throw new Error("Use a unique theme id: a letter, then letters, digits or hyphens (40 characters maximum).");
      if (typeof value.name !== "string" || !value.name.trim() || value.name.length > 60) throw new Error("Use a theme name with 1 to 60 characters.");
      if (!["dark", "light"].includes(value.mode)) throw new Error("Theme mode must be dark or light.");
      if (!value.colors || roles.some((role) => typeof value.colors[role] !== "string" || !/^#[0-9a-f]{6}$/i.test(value.colors[role]))) throw new Error("Each color role must contain a six-digit hex color, such as #242039.");
      if (Object.keys(value).some((key) => !["id", "name", "mode", "colors"].includes(key)) || Object.keys(value.colors).some((key) => !roles.includes(key))) throw new Error("Unknown theme fields. Use the template color roles.");
      return { id: value.id, name: value.name.trim(), mode: value.mode, colors: Object.fromEntries(roles.map((role) => [role, value.colors[role]])) };
    }
    function readThemes(raw) {
      const next = { selected: { ...defaults }, custom: [] };
      try {
        const saved = JSON.parse(raw);
        if (!Array.isArray(saved.custom) || saved.custom.length > 30) return next;
        next.custom = saved.custom.map(validateTheme);
        if (new Set(next.custom.map((theme) => theme.id)).size !== next.custom.length) return { selected: { ...defaults }, custom: [] };
        for (const mode of ["dark", "light"]) {
          const id = saved.selected?.[mode];
          if (id === defaults[mode] || next.custom.some((theme) => theme.id === id && theme.mode === mode)) next.selected[mode] = id;
        }
      } catch (_error) { /* Invalid saved themes fall back to the built-in palettes. */ }
      return next;
    }
    try { themes = readThemes(storage.getItem(themesKey)); } catch (_error) { themePersistent = false; }
    try {
      media = window.matchMedia("(prefers-color-scheme: dark)");
    } catch (_error) {
      // An unavailable OS preference keeps System on the existing dark default.
    }

    function getState() {
      const mode = preference === "system" ? (media ? (media.matches ? "dark" : "light") : "dark") : preference;
      return { preference, mode, persistent: persistent && themePersistent };
    }

    let appliedProperties = [];
    function apply() {
      const state = getState();
      const root = window.document.documentElement;
      root.dataset.appearance = state.mode;
      root.style.colorScheme = state.mode;
      const theme = themes.custom.find((item) => item.id === themes.selected[state.mode]);
      root.dataset.theme = themes.selected[state.mode];
      // Only validated colors enter fixed CSS properties; no CSS or URLs are accepted.
      const properties = {};
      if (theme) {
        const c = theme.colors;
        const groups = {
          canvas: ["ds-background-canvas", "ds-color-dracula-900", "nord5", "boot-bg"],
          surface: ["ds-background-surface", "ds-background-surface-raised", "ds-background-overlay", "nord6"],
          sunken: ["ds-background-surface-sunken", "ds-color-dracula-950", "ds-color-dracula-700", "panel-soft", "nord4"],
          text: ["ds-text-primary", "ds-text-secondary", "ds-color-white", "nord0", "nord1", "nord2", "boot-text"],
          muted: ["ds-text-muted", "ds-text-disabled"], border: ["ds-border-default", "ds-border-subtle", "ds-border-strong", "ds-color-dracula-500", "nord3"],
          accent: ["ds-action-brand", "ds-action-brand-hover", "ds-action-brand-active", "ds-selection", "ds-focus-ring", "ds-color-lavender", "ds-color-pink", "nord7", "nord8", "nord9", "nord15"],
          inverse: ["ds-text-inverse", "accent-contrast"], info: ["ds-feedback-info", "ds-link", "ds-color-cyan", "nord10"],
          success: ["ds-feedback-success", "ds-color-green", "nord14"], warning: ["ds-feedback-warning", "ds-color-orange", "ds-color-yellow", "nord12", "nord13"], danger: ["ds-feedback-danger", "ds-color-red", "nord11"]
        };
        for (const [role, names] of Object.entries(groups)) for (const name of names) properties[`--${name}`] = c[role];
        Object.assign(properties, { "background-color": c.canvas, "--accent": c.accent, "--accent-soft": c.sunken, "--pink": c.accent, "--yellow": c.warning,
          "--ds-action-brand-subtle": c.sunken, "--ds-action-neutral-hover": c.sunken, "--harness-mark-color": c.muted });
        if (state.mode === "light") Object.assign(properties, {
          "--accent": c.text, "--pink": c.border, "--yellow": c.muted,
          "--ds-focus-ring": c.border, "--ds-feedback-success": c.text, "--ds-feedback-warning": c.text
        });
      }
      for (const name of appliedProperties) root.style.removeProperty(name);
      for (const [name, value] of Object.entries(properties)) root.style.setProperty(name, value);
      appliedProperties = Object.keys(properties);
      const meta = window.document.querySelector('meta[name="theme-color"]');
      if (meta) meta.content = theme ? theme.colors.canvas : (state.mode === "light" ? "#e5e9f0" : "#282a36");
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
      if (event.key !== key && event.key !== themesKey && event.key !== null) return;
      if (event.storageArea && event.storageArea !== storage) return;
      if (event.key === themesKey || event.key === null) themes = readThemes(event.key === null ? null : event.newValue);
      if (event.key === key || event.key === null) preference = valid(event.newValue) ? event.newValue : "dark";
      apply();
    }
    function onSystemChange() {
      if (preference === "system") apply();
    }
    window.addEventListener("storage", onStorage);
    if (media?.addEventListener) media.addEventListener("change", onSystemChange);
    else media?.addListener?.(onSystemChange);
    apply();
    function saveThemes() {
      try { storage.setItem(themesKey, JSON.stringify(themes)); themePersistent = true; }
      catch (_error) { themePersistent = false; }
      apply();
    }
    function getThemeState() {
      return JSON.parse(JSON.stringify({ ...themes, sample, samples: { dark: sample, light: lightSample } }));
    }
    function setTheme(mode, id) {
      if (!["dark", "light"].includes(mode) || !(id === defaults[mode] || themes.custom.some((theme) => theme.id === id && theme.mode === mode))) return false;
      themes.selected[mode] = id;
      saveThemes();
      return true;
    }
    function importTheme(raw) {
      if (raw.length > 10000) throw new Error("Theme JSON must be smaller than 10,000 characters.");
      let value;
      try { value = JSON.parse(raw); } catch (_error) { throw new Error("Enter valid JSON. Use the template below."); }
      const theme = validateTheme(value);
      const existing = themes.custom.find((item) => item.id === theme.id);
      if (existing && existing.mode !== theme.mode) throw new Error("Use a different id when you change the theme mode.");
      if (!existing && themes.custom.length >= 30) throw new Error("Remove a custom theme before adding another (30 maximum).");
      themes.custom = themes.custom.filter((item) => item.id !== theme.id).concat(theme);
      themes.selected[theme.mode] = theme.id;
      saveThemes();
      return theme;
    }
    function removeTheme(mode) {
      if (!["dark", "light"].includes(mode)) return false;
      const id = themes.selected[mode];
      if (id === defaults[mode]) return false;
      themes.custom = themes.custom.filter((theme) => theme.id !== id);
      themes.selected[mode] = defaults[mode];
      saveThemes();
      return true;
    }
    return { getState, setPreference, getThemeState, setTheme, importTheme, removeTheme };
  }

  if (typeof module === "object" && module.exports) module.exports = { createAppearance };
  if (scope.document) scope.TychoAppearance = createAppearance(scope);
})(globalThis);
