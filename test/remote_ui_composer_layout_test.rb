# frozen_string_literal: true

require "open3"

script = <<~'JS'
  const assert = require("node:assert/strict");
  const fs = require("node:fs");
  const vm = require("node:vm");
  const source = fs.readFileSync(process.argv[1], "utf8");
  const frames = [], listeners = new Map(), measured = [], modal = [];
  const viewport = { height: 672, offsetTop: 0, addEventListener: (type, callback) => listeners.set(type, callback) };
  let resizeObserver;
  const context = {
    window: { visualViewport: viewport, requestAnimationFrame: callback => frames.push(callback) },
    ResizeObserver: class { constructor(callback) { resizeObserver = callback; } },
    syncAgentDockLayout: () => measured.push(viewport.height),
    syncFullScreenComposerViewport: () => modal.push([viewport.height, viewport.offsetTop]),
    render: () => { throw Error("Viewport settling must not render the editor"); },
  };
  vm.createContext(context);
  function include(start, end, target = context) {
    const a = source.indexOf(start), b = source.indexOf(end, a);
    assert(a >= 0 && b > a, start);
    vm.runInContext(source.slice(a, b), target);
  }
  include("let observedAgentDock = null;", "let observedAgentActions = null;");
  include("function syncComposerVisibleViewport()", '\ndocument.addEventListener("visibilitychange", syncNowMascot)');

  // Safari chrome can finish settling after its viewport event's synchronous measurement.
  listeners.get("resize")();
  assert.equal(measured.at(-1), 672, "keep the immediate viewport update");
  viewport.height = 628;
  assert.equal(frames.length, 1, "invalidate the measurement for the next layout frame");
  resizeObserver();
  resizeObserver();
  assert.equal(frames.length, 1, "dock and viewport notifications share one pending frame");
  frames.shift()();
  assert.equal(measured.at(-1), 628, "read the settled viewport without another event");
  assert.deepEqual(modal.at(-1), [628, 0]);
  assert.equal(frames.length, 0, "the measurement does not schedule itself forever");

  listeners.get("scroll")();
  viewport.height = 340;
  viewport.offsetTop = 88;
  frames.shift()();
  assert.equal(measured.at(-1), 340);
  assert.deepEqual(modal.at(-1), [340, 88], "expanded editors also get the settled viewport");

  listeners.get("resize")();
  viewport.height = 628;
  viewport.offsetTop = 0;
  frames.shift()();
  assert.equal(measured.at(-1), 628, "a later transition can invalidate again");

  // Summary's final Paused subtitle wraps after the workspace was measured.
  const headerFrames = [], clearance = new Map([["--detail-header-height", "67px"]]);
  let headerHeight = 80.22;
  const root = { style: { height: "593px", setProperty() {} }, dataset: {},
    getBoundingClientRect() { const top = parseFloat(clearance.get("--detail-header-height")) + 12; return { top, bottom: top + parseFloat(this.style.height) }; } };
  const headerContext = {
    window: { visualViewport: { height: 672 }, requestAnimationFrame: callback => headerFrames.push(callback) },
    document: { documentElement: { style: { setProperty() {} } } },
    els: {
      header: { getBoundingClientRect: () => ({ height: headerHeight }), classList: { contains: () => true } },
      view: { querySelector: () => root, style: { getPropertyValue: key => clearance.get(key), setProperty: (key, value) => clearance.set(key, value) } },
    },
    agentPanelSlotCount: () => 1,
    syncAgentDockLayout: () => headerContext.syncAgentWorkspaceSlots(),
  };
  vm.createContext(headerContext);
  vm.runInContext("let detailHeaderLayoutScheduled = false;", headerContext);
  include("function agentVisibleViewport()", "\nfunction syncInlineComposerBudget(", headerContext);
  include("function syncDetailHeaderLayout()", "\nfunction showNav()", headerContext);
  headerContext.syncDetailHeaderLayout();
  assert.equal(root.getBoundingClientRect().bottom, 672, "header clearance and workspace height must agree before the next frame");
  assert.equal(headerFrames.length, 1, "retain the scheduled settling measurement");
  for (const nextHeight of [66.31, 80.22]) {
    headerHeight = nextHeight;
    headerContext.syncDetailHeaderLayout();
    assert.equal(root.getBoundingClientRect().bottom, 672, "another subtitle update must repair clearance while the frame is still pending");
    assert.equal(headerFrames.length, 1, "subtitle updates share the pending settling frame");
  }
  headerFrames.shift()();
  assert.equal(root.getBoundingClientRect().bottom, 672);
  console.log("composer viewport settling: ok");
JS

path = File.expand_path("../lib/hq/remote_ui/assets/app.js", __dir__)
output, status = Open3.capture2e("node", "-e", script, path)
abort output unless status.success?
puts output
