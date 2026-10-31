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
              documentElement: { dataset: {}, style: {} },
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
