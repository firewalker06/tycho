/* Runs in the head before CSS so saved appearance also applies to the boot shell. */
(function (scope) {
  "use strict";

  /* Code-drawn scenes. Inputs are validated colors/numbers, never markup or URLs. */
  function backdropImage(backdrop, canvas) {
    const [a, b, c] = backdrop.colors;
    const start = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1600 1000"><defs><linearGradient id="wash" x2="0" y2="1"><stop stop-color="${a}"/><stop offset="1" stop-color="${b}"/></linearGradient><clipPath id="sun"><circle cx="1250" cy="460" r="170"/></clipPath><radialGradient id="glow"><stop stop-color="${c}" stop-opacity=".65"/><stop offset="1" stop-color="${c}" stop-opacity="0"/></radialGradient></defs>`;
    const stars = Array.from({ length: 65 }, (_, i) => `<circle cx="${(i * 197 + 61) % 1600}" cy="${(i * 97 + 41) % 680}" r="${i % 3 === 0 ? 2 : 1}" fill="${c}" opacity="${.3 + i % 4 * .15}"/>`).join("");
    let scene;
    if (backdrop.style === "synthwave") {
      const grid = Array.from({ length: 17 }, (_, i) => `<path d="M800 700L${i * 200 - 800} 1000"/>`).join("") + [715, 740, 775, 825, 895, 985].map(y => `<path d="M0 ${y}H1600"/>`).join("");
      const stripes = Array.from({ length: 8 }, (_, i) => `<path d="M1050 ${455 + i * 20}h400" stroke="${canvas}" stroke-width="${3 + i * 2}"/>`).join("");
      scene = `${stars}<ellipse cx="1250" cy="470" rx="430" ry="430" fill="url(#glow)"/><circle cx="1250" cy="460" r="170" fill="url(#wash)"/><g clip-path="url(#sun)">${stripes}</g><g stroke="${b}" stroke-width="1.5" opacity=".7">${grid}</g><path d="M0 720L80 570 150 660 240 500 350 710 450 650 540 760H0M1000 760L1100 680 1180 710 1290 600 1360 660 1470 510 1600 700V800H1000" fill="${canvas}" stroke="${c}" stroke-width="2"/>`;
    } else if (backdrop.style === "aurora") {
      scene = `${stars}<ellipse cx="1050" cy="220" rx="750" ry="420" fill="url(#glow)"/><path d="M-100 400Q300 -150 650 300T1700 40L1700 230Q1100 620 650 410T-100 650Z" fill="url(#wash)" opacity=".7"/><path d="M-100 460Q300 -80 650 340T1700 100" fill="none" stroke="${c}" stroke-width="12" opacity=".35"/><path d="M0 900L230 680 400 830 650 590 820 850 1100 650 1400 880 1600 700V1000H0Z" fill="${a}" opacity=".85"/>`;
    } else if (backdrop.style === "garden") {
      const leaves = Array.from({ length: 16 }, (_, i) => {
        const x = i % 2 ? 1450 - i * 9 : 70 + i * 12;
        const y = 180 + i * 46;
        return `<ellipse cx="${x}" cy="${y}" rx="100" ry="28" transform="rotate(${i % 2 ? -35 : 35} ${x} ${y})" fill="${i % 3 ? a : b}" opacity=".7"/>`;
      }).join("");
      scene = `<circle cx="1270" cy="230" r="195" fill="${c}" opacity=".65"/><path d="M80 1000Q240 550 110 120M1520 1000Q1280 540 1460 100" fill="none" stroke="${b}" stroke-width="5"/>${leaves}<path d="M0 900Q400 740 800 900T1600 880V1000H0Z" fill="${a}" opacity=".35"/>`;
    } else {
      scene = `<circle cx="1260" cy="240" r="150" fill="${c}"/><path d="M950 210q40 -35 80 0m-200 60q30 -25 60 0" fill="none" stroke="${a}" stroke-width="4"/><path d="M0 580Q300 420 650 590T1600 520V1000H0Z" fill="${a}" opacity=".55"/><path d="M0 720Q350 510 800 720T1600 660V1000H0Z" fill="${b}" opacity=".6"/><path d="M0 840Q400 700 800 860T1600 800V1000H0Z" fill="${a}" opacity=".7"/><path d="M0 925Q400 800 800 940T1600 900V1000H0Z" fill="${c}" opacity=".5"/>`;
    }
    return `url("data:image/svg+xml,${encodeURIComponent(start + scene + "</svg>")}")`;
  }

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
    const examples = [
      { ...sample, id: "builtin:synthwave", name: "Synthwave Sunset", backdrop: { style: "synthwave", colors: ["#f6c66e", "#ed4fbd", "#9a9cff"], intensity: 0.8, motion: "slow" } },
      { ...sample, id: "builtin:aurora", name: "Aurora Night", colors: { ...sample.colors, canvas: "#0b2029", surface: "#14303a", sunken: "#081a22", border: "#648c98", accent: "#88dec9", inverse: "#0b2029" }, backdrop: { style: "aurora", colors: ["#175c6e", "#4dba9b", "#8ef3cb"], intensity: 0.8, motion: "slow" } },
      { ...lightSample, id: "builtin:garden", name: "Paper Garden", backdrop: { style: "garden", colors: ["#88ad91", "#587b66", "#ecc575"], intensity: 0.7, motion: "none" } },
      { ...lightSample, id: "builtin:coast", name: "Coastal Morning", colors: { ...lightSample.colors, canvas: "#edf5f8", surface: "#f9fdff", sunken: "#d8e7ed", text: "#233947", muted: "#49616e", border: "#597482", accent: "#abd6e5", inverse: "#233947" }, backdrop: { style: "coast", colors: ["#77b5cb", "#337f9d", "#f1cd81"], intensity: 0.7, motion: "slow" } }
    ];
    const builtin = (mode, id) => id === defaults[mode] || examples.some(theme => theme.mode === mode && theme.id === id);
    const activeTheme = (id) => themes.custom.find(theme => theme.id === id) || examples.find(theme => theme.id === id);
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
      if (Object.keys(value).some((key) => !["id", "name", "mode", "colors", "backdrop"].includes(key)) || Object.keys(value.colors).some((key) => !roles.includes(key))) throw new Error("Unknown theme fields. Use the template color roles.");
      let backdrop;
      if (value.backdrop !== undefined) {
        const b = value.backdrop;
        if (!b || !["synthwave", "aurora", "garden", "coast"].includes(b.style) || !Array.isArray(b.colors) || b.colors.length !== 3 || b.colors.some(color => typeof color !== "string" || !/^#[0-9a-f]{6}$/i.test(color)) || typeof b.intensity !== "number" || !Number.isFinite(b.intensity) || b.intensity < 0 || b.intensity > 1 || !["none", "slow"].includes(b.motion) || Object.keys(b).some(key => !["style", "colors", "intensity", "motion"].includes(key))) throw new Error("Backdrop needs a supported style, three hex colors, intensity from 0 to 1, and motion none or slow.");
        backdrop = { style: b.style, colors: [...b.colors], intensity: b.intensity, motion: b.motion };
      }
      return { id: value.id, name: value.name.trim(), mode: value.mode, colors: Object.fromEntries(roles.map((role) => [role, value.colors[role]])), ...(backdrop ? { backdrop } : {}) };
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
          if (builtin(mode, id) || next.custom.some((theme) => theme.id === id && theme.mode === mode)) next.selected[mode] = id;
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
      const theme = activeTheme(themes.selected[state.mode]);
      root.dataset.backdrop = theme?.backdrop?.style || "none";
      root.dataset.backdropMotion = theme?.backdrop?.motion || "none";
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
      if (theme?.backdrop) {
        properties["--theme-backdrop-image"] = backdropImage(theme.backdrop, theme.colors.canvas);
        properties["--theme-backdrop-opacity"] = String(theme.backdrop.intensity);
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
      return JSON.parse(JSON.stringify({ ...themes, examples, sample, samples: { dark: sample, light: lightSample } }));
    }
    function setTheme(mode, id) {
      if (!["dark", "light"].includes(mode) || !(builtin(mode, id) || themes.custom.some((theme) => theme.id === id && theme.mode === mode))) return false;
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
      if (builtin(mode, id)) return false;
      themes.custom = themes.custom.filter((theme) => theme.id !== id);
      themes.selected[mode] = defaults[mode];
      saveThemes();
      return true;
    }
    function examplePreview(id) {
      const theme = examples.find(item => item.id === id);
      return theme ? `background-color:${theme.colors.canvas};background-image:${backdropImage(theme.backdrop, theme.colors.canvas)}` : "";
    }
    return { getState, setPreference, getThemeState, setTheme, importTheme, removeTheme, examplePreview };
  }

  if (typeof module === "object" && module.exports) module.exports = { createAppearance };
  if (scope.document) scope.TychoAppearance = createAppearance(scope);
})(globalThis);
