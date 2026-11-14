# frozen_string_literal: true

require "open3"
require "tempfile"

module RemoteUIAppearanceTest
  module_function

  def run!
    Tempfile.create(["tycho-appearance", ".js"]) do |script|
      script.write(<<~'JS')
        const assert = require("node:assert/strict");
        const { createAppearance } = require(process.cwd() + "/lib/hq/remote_ui/assets/appearance.js");
        function fixture(saved, options = {}) {
          const values = new Map(saved === undefined ? [] : [["hq.remote.appearance", saved]]);
          if (options.savedThemes) values.set("hq.remote.themes.v1", options.savedThemes);
          const handlers = {};
          const changes = [];
          const media = { matches: Boolean(options.darkOS), addEventListener: (_, handler) => { media.change = handler; } };
          const meta = {};
          const window = {
            localStorage: {
              getItem: (key) => { if (options.blockRead) throw Error("denied"); return values.get(key) ?? null; },
              setItem: (key, value) => { if (options.blockWrite) throw Error("full"); values.set(key, value); },
            },
            matchMedia: () => { if (options.noMedia) throw Error("unavailable"); return media; },
            addEventListener: (type, handler) => { handlers[type] = handler; },
            CustomEvent: class { constructor(type, init) { this.type = type; this.detail = init.detail; } },
            document: {
              documentElement: { dataset: {}, style: { setProperty(name, value) { this[name] = value; }, removeProperty(name) { delete this[name]; } } },
              querySelector: () => meta,
              dispatchEvent: (event) => changes.push(event.detail),
            },
          };
          const appearance = createAppearance(window);
          return { appearance, window, media, values, meta, changes, storage: (value, area = window.localStorage, key = "hq.remote.appearance") => handlers.storage({ key, newValue: value, storageArea: area }) };
        }
        for (const saved of [undefined, "invalid", "", "null"]) {
          const f = fixture(saved);
          assert.equal(f.appearance.getState().mode, "dark", "missing/corrupt settings preserve dark even on a light OS");
          assert.equal(f.window.document.documentElement.style.colorScheme, "dark");
        }
        const light = fixture("light", { darkOS: true });
        assert.equal(light.window.document.documentElement.dataset.appearance, "light", "saved mode applies synchronously before app startup");
        assert.equal(light.meta.content, "#e5e9f0", "browser chrome follows saved mode");
        light.media.matches = false;
        light.media.change();
        assert.equal(light.appearance.getState().mode, "light", "explicit choices ignore OS changes");
        assert.equal(light.appearance.setPreference("system"), true);
        assert.equal(light.values.get("hq.remote.appearance"), "system");
        light.media.matches = true;
        light.media.change();
        assert.equal(light.appearance.getState().mode, "dark", "System responds to OS changes");
        assert.equal(light.meta.content, "#282a36");
        assert.equal(light.appearance.setPreference("invalid"), false);
        assert.equal(light.appearance.getState().preference, "system", "invalid API input cannot erase a choice");
        light.storage("light");
        assert.equal(light.appearance.getState().mode, "light", "another tab's choice applies");
        light.storage("dark", {});
        assert.equal(light.appearance.getState().mode, "light", "other storage areas are ignored");
        light.storage("dark", light.window.localStorage, "hq.remote.token");
        assert.equal(light.appearance.getState().mode, "light", "unrelated keys are ignored");
        light.storage(null, light.window.localStorage, null);
        assert.equal(light.appearance.getState().preference, "dark", "clearing storage restores the default");
        const denied = fixture("light", { blockRead: true, blockWrite: true });
        assert.equal(denied.appearance.getState().mode, "dark");
        denied.appearance.setPreference("light");
        assert.deepEqual(denied.appearance.getState(), { preference: "light", mode: "light", persistent: false }, "unavailable storage retains a usable in-memory choice");
        const full = fixture("dark", { blockWrite: true });
        full.appearance.setPreference("light");
        assert.equal(full.appearance.getState().persistent, false, "a quota failure is disclosed");
        assert.equal(fixture("system", { noMedia: true }).appearance.getState().mode, "dark", "unavailable OS API has a safe default");
        const custom = fixture("dark");
        const theme = custom.appearance.getThemeState().sample;
        custom.appearance.importTheme(JSON.stringify(theme));
        assert.equal(custom.window.document.documentElement.dataset.theme, "midnight");
        assert.equal(custom.meta.content, theme.colors.canvas);
        assert.equal(custom.window.document.documentElement.style["--ds-action-brand"], theme.colors.accent);
        const savedThemes = custom.values.get("hq.remote.themes.v1");
        const cold = fixture("dark", { savedThemes });
        assert.equal(cold.window.document.documentElement.dataset.theme, "midnight", "saved palette applies synchronously on cold load");
        assert.equal(cold.window.document.documentElement.style["--boot-bg"], theme.colors.canvas);
        const reloaded = fixture("dark");
        reloaded.storage(savedThemes, reloaded.window.localStorage, "hq.remote.themes.v1");
        assert.equal(reloaded.window.document.documentElement.dataset.theme, "midnight", "theme changes sync between tabs");
        custom.appearance.setPreference("light");
        assert.equal(custom.window.document.documentElement.dataset.theme, "nord", "light selection is independent");
        assert.equal(custom.window.document.documentElement.style["--ds-action-brand"], undefined, "custom overrides are removed for built-ins");
        custom.appearance.setPreference("dark");
        assert.equal(custom.window.document.documentElement.dataset.theme, "midnight");
        for (const value of ["invalid", JSON.stringify({ bad: true }), JSON.stringify({ ...theme, colors: { ...theme.colors, accent: ["#ffffff"] } }), JSON.stringify({ ...theme, id: "dracula" }), JSON.stringify({ ...theme, colors: { ...theme.colors, accent: "url(https://example.com)" } }), JSON.stringify({ ...theme, colors: { ...theme.colors, unknown: "#ffffff" } })]) {
          assert.throws(() => custom.appearance.importTheme(value));
          assert.equal(custom.window.document.documentElement.dataset.theme, "midnight", "invalid themes preserve the current palette");
        }
        assert.equal(custom.appearance.setTheme("light", "midnight"), false);
        assert.equal(custom.appearance.setTheme("bad", "midnight"), false);
        assert.throws(() => custom.appearance.importTheme(JSON.stringify({ ...theme, mode: "light" })), /different id/);
        custom.appearance.importTheme(JSON.stringify({ ...theme, name: "Midnight edited" }));
        assert.equal(custom.appearance.getThemeState().custom.length, 1, "editing updates one theme");
        assert.equal(custom.appearance.getThemeState().custom[0].name, "Midnight edited");
        custom.appearance.removeTheme("dark");
        assert.equal(custom.window.document.documentElement.dataset.theme, "dracula");
        assert.equal(custom.appearance.getThemeState().custom.length, 0);
        reloaded.storage("corrupt", reloaded.window.localStorage, "hq.remote.themes.v1");
        assert.equal(reloaded.window.document.documentElement.dataset.theme, "dracula");
        denied.appearance.importTheme(JSON.stringify(theme));
        assert.equal(denied.appearance.getState().persistent, false);
        const scenes = fixture("dark");
        const examples = scenes.appearance.getThemeState().examples;
        assert.equal(examples.length, 4);
        assert.equal(examples.filter(theme => theme.mode === "dark").length, 2);
        assert.equal(examples.filter(theme => theme.mode === "light").length, 2);
        for (const example of examples) {
          assert(scenes.appearance.setTheme(example.mode, example.id));
          scenes.appearance.setPreference(example.mode);
          assert.equal(scenes.window.document.documentElement.dataset.backdrop, example.backdrop.style);
          assert.match(scenes.window.document.documentElement.style["--theme-backdrop-image"], /^url/);
          assert.equal(scenes.appearance.removeTheme(example.mode), false, "example scenes cannot be removed");
          const restored = fixture(example.mode, { savedThemes: scenes.values.get("hq.remote.themes.v1") });
          assert.equal(restored.window.document.documentElement.dataset.theme, example.id, "built-in scene choices survive a cold load");
        }
        const backdrop = { ...examples[0].backdrop };
        for (const invalid of [{ ...backdrop, colors: ["url(https://example.com)", "#ffffff", "#ffffff"] }, { ...backdrop, style: "unknown" }, { ...backdrop, intensity: 2 }, { ...backdrop, motion: "fast" }, { ...backdrop, extra: "#ffffff" }]) {
          assert.throws(() => scenes.appearance.importTheme(JSON.stringify({ ...theme, backdrop: invalid })), /Backdrop/);
        }
        scenes.appearance.importTheme(JSON.stringify({ ...theme, backdrop }));
        scenes.appearance.setPreference("dark");
        assert.equal(scenes.window.document.documentElement.dataset.backdrop, "synthwave");
        scenes.appearance.importTheme(JSON.stringify(theme));
        assert.equal(scenes.window.document.documentElement.dataset.backdrop, "none", "old palette-only JSON stays valid and removes scene overrides");
        assert.equal(scenes.window.document.documentElement.style["--theme-backdrop-image"], undefined);
        assert(light.changes.length > 1, "the UI is notified without rebuilding forms");
      JS
      script.flush
      output, error, status = Open3.capture3("node", script.path, chdir: File.expand_path("..", __dir__))
      raise "Appearance behavior failed:\n#{output}#{error}" unless status.success?
    end
    puts "remote_ui_appearance_test: ok"
  end
end

RemoteUIAppearanceTest.run!
