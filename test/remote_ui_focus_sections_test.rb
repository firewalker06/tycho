# frozen_string_literal: true

require "open3"
require "tempfile"

module RemoteUIFocusSectionsTest
  module_function

  ROOT = File.expand_path("..", __dir__)

  def run!
    Tempfile.create(["tycho-focus-sections", ".js"]) do |script|
      script.write(<<~'JS')
        const fs = require("node:fs");
        const vm = require("node:vm");
        const assert = require("node:assert/strict");
        const source = fs.readFileSync("lib/hq/remote_ui/assets/app.js", "utf8");
        const snapshots = source.slice(source.indexOf("function displayedAgentFocus("), source.indexOf("async function refreshAgentFocus("));
        const helpers = source.slice(source.indexOf("function agentFocusSectionEntries("), source.indexOf("function renderAgentFocusSection("));
        const section = title => ({ title, items: [{ title: "Task" }] });
        const agents = { a: { key: "a", focus: { sections: [section("Work"), section("Notes"), section("Notes")] } }, b: { key: "b", focus: { sections: [section("Work")] } }, c: { key: "c", focus: { sections: [{ title: "Done", completed: true, items: [{ title: "Finished", completed: true }] }] } } };
        let renders = 0;
        const context = { state: { agentFocusCollapsedSections: new Map(), agentFocusExpandedCompletedSections: new Map(), agentFocusSnapshots: new Map() }, findAgent: key => agents[key], render: () => { renders += 1; } };
        vm.runInNewContext(snapshots + helpers, context);
        const entries = key => Array.from(context.agentFocusSectionEntries(agents[key]));
        const closed = key => entries(key).map(entry => entry.collapsed);
        const toggle = (key, sectionKey) => context.toggleAgentFocusSections(key, sectionKey);
        const original = entries("a");
        assert.notEqual(original[1].key, original[2].key, "duplicate titles need separate choices");
        toggle("a", original[1].key);
        assert.deepEqual(closed("a"), [false, true, false]);
        assert.deepEqual(closed("b"), [false], "another agent must keep its own choices");
        const completed = entries("c")[0];
        assert.equal(completed.completed, true);
        assert.equal(completed.collapsed, true, "completed groups start collapsed");
        toggle("c", completed.key);
        assert.equal(entries("c")[0].collapsed, false, "users can expand completed groups");
        toggle("c", completed.key);
        assert.equal(entries("c")[0].collapsed, true, "users can collapse completed groups again");
        agents.a.focus.sections = [section("Notes"), section("New"), section("Work"), section("Notes")];
        agents.a.focus.sections[0].items.push({ title: "A new item from polling" });
        assert.deepEqual(closed("a"), [false, true, false], "background edits must not change displayed Focus");
        context.acceptAgentFocusData("a", agents.a.focus);
        assert.deepEqual(closed("a"), [true, false, false, false], "manual refresh preserves choices; new sections start open");
        toggle("a");
        assert.deepEqual(closed("a"), [true, true, true, true], "mixed bulk action collapses every section");
        toggle("a");
        assert.deepEqual(closed("a"), [false, false, false, false], "all-collapsed bulk action expands every section");
        toggle("a", entries("a")[0].key);
        agents.a.focus.sections = [section("Renamed")];
        context.acceptAgentFocusData("a", agents.a.focus);
        assert.deepEqual(closed("a"), [false], "renamed sections start open");
        const before = renders;
        toggle("a", original[0].key);
        assert.equal(renders, before, "stale section controls must not change the current document");
      JS
      script.flush
      out, err, status = Open3.capture3("node", script.path, chdir: ROOT)
      raise "Focus section state regression failed:\n#{out}#{err}" unless status.success?
    end
    puts "remote_ui_focus_sections_test: ok"
  end
end

RemoteUIFocusSectionsTest.run! if $PROGRAM_NAME == __FILE__
