const fs = require("node:fs");
const vm = require("node:vm");
const assert = require("node:assert/strict");
const [appPath, helpersPath, mode] = process.argv.slice(2);
const source = fs.readFileSync(appPath, "utf8");
const parent = { key: "parent", name: "Coordinator", delegation: { children: [] } };
const child = { key: "child", name: "Needle child", updated_at: "2026-11-01T05:00:01Z", delegation: { parent: { key: "parent" } } };
let agents = [parent, child];
let opened;
const handlers = {};
const list = { innerHTML: "" };
const panel = { querySelector: selector => selector === ".unread-panel-list" ? list : null, addEventListener: (name, handler) => { handlers[name] = handler; } };
const state = { unreadPanelQuery: "", unreadPanelSelectedIndex: 0, unreadPanelSelectedKey: "", switcherDelegationExpanded: false, switcherDelegationOverrides: new Map() };
const context = { window: {}, document: { activeElement: null }, URL, URLSearchParams, Map, Set, state,
  quickSwitchPanelAgents: () => agents, quickSwitchPanelAgent: () => null, findProject: () => null,
  closeUnreadPanel: () => {}, navigate: route => { opened = route.key; },
  scrollSelectedSwitcherAgentIntoView: () => {},
  escapeAttr: value => String(value), iconSvg: () => "", emptyState: () => "empty",
  agentListStatusIcon: () => "", agentStatusBadge: () => "", agentIdentityIcon: () => "", linkedAgentReferences: () => [],
  agentNameHtml: agent => agent.name, agentListSubtextHtml: () => "",
  els: { unreadPanel: panel },
};
vm.createContext(context);
vm.runInContext(fs.readFileSync(helpersPath, "utf8"), context);
context.REMOTE_HELPERS = context.window.TychoRemoteHelpers;
function install(name) {
 const start = source.indexOf(`function ${name}(`);
 assert(start >= 0, `missing production function ${name}`);
 vm.runInContext(source.slice(start, source.indexOf("\nfunction ", start + 1)), context);
}
for (const name of ["compareQuickSwitchAgents", "navigateSwitcherAgent", "rankMatchingAgents", "switcherDelegationEntries", "filterQuickSwitchAgents", "selectBestSwitcherSearchMatch", "syncUnreadPanelSelection", "renderSwitcherAgentRow", "renderUnreadPanelResults", "moveUnreadPanelSelection", "openSelectedSwitcherAgent"]) install(name);
const start = source.indexOf('els.unreadPanel.addEventListener("input",');
vm.runInContext(source.slice(start, source.indexOf("\n});", start) + 4), context);
const input = { value: "Needle child" };
const query = value => { input.value = value; handlers.input({ target: { closest: () => input } }); };
const snapshot = stage => {
 context.openSelectedSwitcherAgent();
 return { stage, visible: context.filterQuickSwitchAgents().map(agent => agent.key), selectedIndex: state.unreadPanelSelectedIndex, selectedKey: state.unreadPanelSelectedKey, opened, html: list.innerHTML };
};
query("Needle child");
const initial = snapshot("query-render");
const sibling = { key: "new-sibling", name: "Other worker", updated_at: "2026-11-01T05:00:02Z", delegation: { parent: { key: "parent" } } };
agents.push(sibling);
context.renderUnreadPanelResults();
const arriving = snapshot("refresh-render");
console.log(JSON.stringify({ initial, arriving }));
if (mode === "--assert") {
 assert.equal(initial.opened, "child"); assert.equal(arriving.opened, "child");
 assert.notEqual(initial.html, arriving.html, "the production renderer must rebuild changed results");
 assert.equal(arriving.selectedIndex, 2);
 // Arrow selection may deliberately choose a nonmatching context row.
 context.moveUnreadPanelSelection(-1);
 sibling.updated_at = "2026-11-01T04:00:00Z";
 context.renderUnreadPanelResults(); assert.equal(snapshot("arrow-intent").opened, "new-sibling");
 // Disappearance falls back to the remaining highest-ranked visible match.
 agents = agents.filter(agent => agent !== sibling);
 context.renderUnreadPanelResults(); assert.equal(snapshot("disappeared-context").opened, "child");
 const peer = { ...child, key: "peer::child", name: "Needle peer", updated_at: "2026-11-01T06:00:00Z" };
 agents.push(peer, { ...peer });
 query("Needle peer");
 child.updated_at = "2026-11-01T07:00:00Z";
 context.renderUnreadPanelResults(); assert.equal(snapshot("peer-key").opened, "peer::child");
 assert.equal(context.filterQuickSwitchAgents().filter(agent => agent.key === peer.key).length, 1);
 // Remove the selected matching key, retain another match; never use its old index.
 query("Needle");
 const selected = snapshot("before-removal").opened;
 agents = agents.filter(agent => agent.key !== selected);
 context.renderUnreadPanelResults();
 assert.equal(snapshot("remaining-match").opened, selected === child.key ? peer.key : child.key);
 // No remaining match clears selection and Enter does nothing.
 agents = [parent]; opened = null;
 context.renderUnreadPanelResults(); context.openSelectedSwitcherAgent();
 assert.equal(opened, null); assert.equal(state.unreadPanelSelectedKey, "");
 // Expansion and collapse reconcile the same key if it is still visible.
 agents = [parent, child]; query(""); state.switcherDelegationExpanded = true;
 context.renderUnreadPanelResults(); context.moveUnreadPanelSelection(1);
 context.renderUnreadPanelResults(); assert.equal(snapshot("expanded-selection").opened, child.key);
 state.switcherDelegationExpanded = false; context.renderUnreadPanelResults();
 assert.equal(snapshot("collapsed-fallback").opened, parent.key);
 console.log("switcher selection rebuild regressions: ok");
}
