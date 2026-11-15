# frozen_string_literal: true

require "open3"

module RemoteUINowMascotTest
  def self.run!
    source = File.expand_path("../lib/hq/remote_ui/assets/now_mascot.js", __dir__)
    script = <<~JS
      const assert = require("node:assert/strict");
      const vm = require("node:vm");
      const window = {};
      vm.runInNewContext(require("node:fs").readFileSync(process.argv[1], "utf8"), { window });
      const pending = new Map();
      let id = 0, changes = 0, current;
      let random = 0;
      let allowed = true;
      const model = window.TychoNowMascot.create({ random: () => random,
        canRotate: () => allowed,
        setTimer: (callback, delay) => { assert.equal(delay, 30000); pending.set(++id, callback); return id; },
        clearTimer: id => pending.delete(id), changed: () => { changes++; current = update(); } });
      const update = (options = {}) => model.update({empty: true, shown: true, ...options});
      const tick = () => { assert.equal(pending.size, 1); const [key, fn] = [...pending][0]; pending.delete(key); fn(); };
      current = update();
      assert.equal(current.id, "d");
      assert.equal(current.image, "/now-mascot/d.webp");
      assert.equal(current.text, "All done. Hooray!");
      for (let i = 0; i < 20; i++) assert.strictEqual(update(), current, "polling preserves the record");
      assert.equal(pending.size, 1, "polling does not create or restart timers");
      tick();
      assert.equal(current.id, "e");
      assert.equal(current.text, "Nothing left? Thought so.");
      random = .99;
      tick();
      assert.equal(current.id, "f");
      assert.equal(current.image, "/now-mascot/f.webp");
      assert.equal(current.text, "And… relax. All done.");
      for (let i = 0; i < 12; i++) { const previous = current; tick(); assert.notEqual(current.id, previous.id); }
      update({shown: false});
      assert.equal(pending.size, 0, "hidden stops the timer");
      assert.strictEqual(update({shown: false}), current, "hidden preserves selection");
      update();
      assert.equal(pending.size, 1, "visible starts one fresh cadence");
      update({reduce: true});
      assert.equal(pending.size, 0, "reduced motion is static");
      update();
      assert.equal(pending.size, 1);
      assert.equal(update({empty: false}), null);
      assert.equal(pending.size, 0, "nonempty or route exit stops timer");
      const reentry = update();
      assert.notEqual(reentry.id, current.id, "reentry avoids immediate repeat");
      const before = changes;
      allowed = false;
      tick();
      assert.equal(changes, before, "late media or visibility changes prevent a queued rotation");
      assert.equal(pending.size, 0);
      allowed = true;
      update();
      model.dispose();
      assert.equal(pending.size, 0, "page disposal stops timer");
      assert(changes >= 14);
      assert(window.TychoNowMascot.variants.every(Object.isFrozen));
      console.log("Now mascot pairing, polling, rotation and lifecycle: ok");
    JS
    out, err, status = Open3.capture3("node", "-e", script, source)
    raise "#{out}\n#{err}" unless status.success?

    puts out
  end
end

RemoteUINowMascotTest.run! if $PROGRAM_NAME == __FILE__
