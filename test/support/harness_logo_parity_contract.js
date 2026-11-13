const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const source = fs.readFileSync(process.argv[2], "utf8");
const fn = name => source.match(new RegExp(`^function ${name}\\([^]*?^}`, "m"))[0];
const names = ["harnessMarkHtml", "harnessLabelHtml", "agentMetaParts", "agentUpdatedAt", "agentListSubtextHtml", "agentSettingsHtml", "renderSkillInstallationRow", "agentHarnessLabel", "agentHeaderLabel"];
const escape = value => String(value ?? "").replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll('"', "&quot;");
const c = { state: { servers: [] }, escapeHtml: escape, escapeAttr: escape,
  agentProjectLabel: () => "Fixture", findProject: () => ({name:"Fixture"}), projectSearchMatch: () => null,
  serverHealthLabel: () => "Ready", relativeTimeHtml: () => "", timeShort: () => "", resourceServer: () => ({}), serverDisplayName: () => "Local",
  responseStyleSourceLabel: () => "Disabled", statusLabel: () => "Idle", agentTemplateLabel: () => "Fixture",
  agentStatusKv: () => "Status", copyableKv: () => "", kv: (label, value, options) => options.valueHtml,
  statusMarkAttributes: () => "", statusIcon: () => "", statusBadge: () => "", iconSvg: () => "" };
vm.createContext(c);
vm.runInContext(source.match(/^const HARNESS_MARKS = {[^]*?^};/m)[0] + "\n" +
  source.match(/^const HARNESS_MARK_LUMINANCE = .*;$/m)[0] + "\n" + names.map(fn).join("\n"), c);
for (const harness of ["codex", "claude", "opencode", "pi", "dsh", "agy"]) {
  c.agent = {key:"fixture", agent:harness, project_key:"fixture"};
  c.skill = {harness, status:"unsupported"};
  for (const expression of ["harnessLabelHtml(agent.agent)", "agentListSubtextHtml(agent)", "agentSettingsHtml(agent)", "renderSkillInstallationRow(skill)"]) {
    const html = vm.runInContext(expression, c);
    assert.equal((html.match(/class="harness-mark"/g) || []).length, 1, `${harness}: ${expression}`);
    assert(html.includes('role="presentation" aria-hidden="true"'));
    assert(html.includes(`<span>${harness}</span>`), "adjacent accessible harness name");
    if (harness === "dsh") assert(html.includes("deepseek-icon.svg"));
    if (harness === "agy") assert(html.includes("antigravity-icon-one-color.svg"));
  }
  assert(!vm.runInContext("agentHeaderLabel(agent)", c).includes("<"), "header stays text for all harnesses");
  assert(!vm.runInContext("agentListSubtextHtml(agent, {summaryMeta:true})", c).includes("harness-mark"));
}
assert.equal(c.harnessLabelHtml("custom<fixture>"), "custom&lt;fixture>");
// Every current shared-label caller must keep using the shared mapping.
for (const name of ["renderHarnessDetails", "renderSkillInstallationRow", "renderAgentArchive", "agentSettingsHtml", "agentListSubtextHtml"]) {
  assert(fn(name).includes("harnessLabelHtml("), name);
}
for (const name of ["renderAgentCard", "renderAgentRow", "renderSelectableAgentRow", "renderSwitcherAgentRow"]) {
  assert(fn(name).includes("agentListSubtextHtml("), name);
}
for (const id of ["agent-harness", "quick-agent-harness", "schedule-harness"]) {
  assert(new RegExp(`<select[^>]*id="${id}"`).test(source), `${id} remains a native text selector`);
}
console.log("Harness logo parity passed: six built-ins, shared labels and callers, accessible names, text-only headers/selectors, custom fallback.");
