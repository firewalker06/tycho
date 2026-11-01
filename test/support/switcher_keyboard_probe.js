const fs = require("node:fs");
const vm = require("node:vm");
const assert = require("node:assert/strict");
const [appPath, helpersPath, mode] = process.argv.slice(2);
const source = fs.readFileSync(appPath, "utf8");
const handlers = {};
const parent = { key: "parent", name: "Coordinator", delegation: { children: [{ key: "child" }] } };
const child = { key: "child", name: "Needle child", delegation: { parent: { key: "parent" } } };
const state = { unreadPanelOpen: true, unreadPanelQuery: "", unreadPanelSelectedIndex: 0, switcherDelegationExpanded: false, switcherDelegationOverrides: new Map() };
let opened = null;
let linked = null;
const context = { window: {}, URL, URLSearchParams, Map, Set, state,
  quickSwitchPanelAgents: () => [parent, child], quickSwitchPanelAgent: () => null,
  findProject: () => null, compareQuickSwitchAgents: (a, b) => a.key.localeCompare(b.key),
  linkedAgentReferences: agent => agent.delegation.children || [],
  closeUnreadPanel: () => {}, navigate: route => { opened = route.key; },
  renderUnreadPanelResults: () => {}, scrollSelectedSwitcherAgentIntoView: () => {},
  showLinkedAgentsInSwitcher: key => { linked = key; },
  els: { unreadPanel: { addEventListener: (name, handler) => { handlers[name] = handler; } } },
};
vm.createContext(context);
vm.runInContext(fs.readFileSync(helpersPath, "utf8"), context);
context.REMOTE_HELPERS = context.window.TychoRemoteHelpers;
function install(name) {
 const start = source.indexOf(`function ${name}(`);
 assert(start >= 0, `missing production function ${name}`);
 const end = source.indexOf("\nfunction ", start + 1);
 vm.runInContext(source.slice(start, end), context);
}
for (const name of ["compareQuickSwitchAgents", "navigateSwitcherAgent", "rankMatchingAgents", "switcherDelegationEntries", "filterQuickSwitchAgents", "syncUnreadPanelSelection", "moveUnreadPanelSelection", "openSelectedSwitcherAgent", "handleUnreadPanelKeydown"]) install(name);
if (source.includes("function selectBestSwitcherSearchMatch(")) install("selectBestSwitcherSearchMatch");
const inputStart = source.indexOf('els.unreadPanel.addEventListener("input",');
vm.runInContext(source.slice(inputStart, source.indexOf("\n});", inputStart) + 4), context);
const input = { value: "Needle child" };
handlers.input({ target: { closest: () => input } });
const visible = context.filterQuickSwitchAgents();
context.openSelectedSwitcherAgent();
const selection = { rankedMatches: context.rankMatchingAgents([parent, child], input.value, context.compareQuickSwitchAgents).map(agent => agent.key), displayOrder: visible.map(agent => agent.key), enterOpens: opened };
state.unreadPanelQuery = ""; state.unreadPanelSelectedIndex = 0; state.unreadPanelSelectedKey = "";
const keyProbe = (key, shiftKey = false, altKey = false) => {
 let prevented = false; linked = null;
 const handled = context.handleUnreadPanelKeydown({ key, shiftKey, altKey, target: { closest: () => null }, preventDefault: () => { prevented = true; } });
 return { key: `${shiftKey ? "Shift+" : altKey ? "Alt+" : ""}${key}`, handled, prevented, linked };
};
const tab = keyProbe("Tab"); const shiftTab = keyProbe("Tab", true); const linkedShortcut = keyProbe("ArrowRight", false, true);
console.log(JSON.stringify({ selection, tab, shiftTab, linkedShortcut }));
if (mode === "--assert") {
 assert.equal(selection.enterOpens, "child");
 assert.equal(tab.prevented, false); assert.equal(shiftTab.prevented, false);
 assert.equal(linkedShortcut.linked, "parent");
 // Keyboard movement stays on visible context rows instead of reselecting the match.
 handlers.input({ target: { closest: () => input } });
 context.moveUnreadPanelSelection(-1); context.openSelectedSwitcherAgent(); assert.equal(opened, "parent");
 // A server-qualified key remains distinct from a same-title local agent.
 child.key = "peer::child"; parent.delegation.children[0].key = child.key;
 handlers.input({ target: { closest: () => input } }); context.openSelectedSwitcherAgent(); assert.equal(opened, "peer::child");
 state.switcherDelegationOverrides.set("parent", true);
 input.value = ""; handlers.input({ target: { closest: () => input } });
 assert.equal(state.unreadPanelSelectedIndex, 0); assert.equal(state.switcherDelegationExpanded, false);
 assert.equal(state.switcherDelegationOverrides.get("parent"), true);
 assert.equal(context.filterQuickSwitchAgents().length, 2);
}
