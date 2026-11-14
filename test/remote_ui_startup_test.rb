# frozen_string_literal: true

require "open3"

module RemoteUIStartupTest
  module_function

  def run!
    script = <<~'JS'
      const assert = require("node:assert/strict");
      const vm = require("node:vm");
      const fs = require("node:fs");
      const code = fs.readFileSync("lib/hq/remote_ui/assets/startup.js", "utf8");
      function fixture(saved, blocked = false, random = 0) {
        const elements = Object.fromEntries(["shell", "message", "retry"].map(name => ["tycho-boot-" + name, { dataset: {}, setAttribute() {}, classList: { contains: () => false } }]));
        let timeout, cleared = false, reloads = 0;
        const values = new Map([["hq.remote.startup-message", saved]]);
        const window = {
          document: { getElementById: id => elements[id] },
          localStorage: {
            getItem: key => { if (blocked) throw Error("denied"); return values.get(key); },
            setItem: (key, value) => { if (blocked) throw Error("full"); values.set(key, value); },
          },
          setTimeout: (fn, ms) => { assert.equal(ms, 15000); timeout = fn; return 1; },
          clearTimeout: id => { assert.equal(id, 1); cleared = true; },
          location: { reload: () => reloads++ },
        };
        let draws = 0;
        vm.runInNewContext(code, { window, Math: { floor: Math.floor, random: () => { draws++; return random; } } });
        assert.equal(draws, 1, "select exactly once per startup");
        return { window, elements, values, expire: () => timeout(), cleared: () => cleared, reloads: () => reloads };
      }
      for (const value of [undefined, null, "", "   "]) {
        const f = fixture(value);
        assert.equal(f.elements["tycho-boot-message"].textContent, "The factory must grow");
      }
      for (const value of ["The factory must grow…", "Your agent can do what?", '<img src=x onerror="alert(1)">']) {
        const f = fixture(value);
        assert.equal(f.elements["tycho-boot-message"].textContent, value, "saved text is applied synchronously as text");
        assert.equal(f.elements["tycho-boot-message"].innerHTML, undefined);
        f.window.TychoStartup.setMessage("  changed  ");
        assert.equal(f.values.get("hq.remote.startup-message"), "  changed  ");
        f.window.TychoStartup.setMessage("x".repeat(9000));
        assert.equal(f.values.get("hq.remote.startup-message").length, 8000);
      }
      for (const [random, expected] of [[0, "First"], [0.49, "First"], [0.5, "Second"], [0.999, "Second"]]) {
        const f = fixture(" \n First \r\n \nSecond\n", false, random);
        assert.equal(f.elements["tycho-boot-message"].textContent, expected);
        f.window.TychoStartup.setMessage("new list");
        assert.equal(f.elements["tycho-boot-message"].textContent, expected, "settings do not rotate current startup");
      }
      assert.equal(fixture(" \n\r\n", false, .99).elements["tycho-boot-message"].textContent, "Orchestrating the orchestrator");
      assert.equal(fixture("x".repeat(300)).elements["tycho-boot-message"].textContent.length, 240);
      const blocked = fixture("saved", true);
      assert.equal(blocked.elements["tycho-boot-message"].textContent, "The factory must grow");
      blocked.window.TychoStartup.setMessage("next");
      assert.equal(blocked.window.TychoStartup.getState().persistent, false);
      const failed = fixture("custom");
      failed.expire();
      assert.equal(failed.elements["tycho-boot-shell"].dataset.state, "failed");
      assert.equal(failed.elements["tycho-boot-retry"].hidden, false);
      assert(failed.elements["tycho-boot-message"].textContent.includes("Check your connection"));
      failed.elements["tycho-boot-retry"].onclick();
      assert.equal(failed.reloads(), 1);
      const ready = fixture("custom");
      ready.elements["tycho-boot-shell"].hidden = true;
      ready.expire();
      assert.equal(ready.elements["tycho-boot-message"].textContent, "custom");
      let retries = 0;
      ready.window.TychoStartup.handoff(() => retries++);
      assert(ready.cleared());
      ready.elements["tycho-boot-retry"].onclick();
      assert.equal(retries, 1, "app owns retry after handoff");
    JS
    output, error, status = Open3.capture3("node", "-e", script, chdir: File.expand_path("..", __dir__))
    raise "Startup behavior failed:\n#{output}#{error}" unless status.success?

    puts "remote_ui_startup_test: ok"
  end
end

RemoteUIStartupTest.run! if $PROGRAM_NAME == __FILE__
