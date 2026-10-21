const fs = require("fs");
const vm = require("vm");
const assert = require("assert");
const fixture = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const source = fs.readFileSync("lib/hq/remote_ui/assets/app.js", "utf8");
const names = ["agentSummaryDetail", "runSummaryBlocks", "latestRunSummaryFromAgent", "usableRunSummaryContent", "fallbackRunSummaryContent", "lastSafeRunError", "summaryBlockErrorForRun", "summaryErrorText", "lastSafeAssistantMessage", "safeAssistantContextText", "boundedSummaryFallbackContext", "redactSummaryFallbackContext", "markdownQuote", "normalizedSummarySections", "runSummaryNumber", "runSummaryDetailContent", "safeRunStopContext"];
const functions = names.map(name => {
  const start = source.indexOf(`function ${name}(`);
  if (start < 0) return "";
  return source.slice(start, source.indexOf("\nfunction ", start + 1));
}).join("\n");
const context = {state: {conversations: {[fixture.key]: {blocks: fixture.blocks}}}, runSummaryId: b => b.metadata.summary_id};
vm.createContext(context);
vm.runInContext(functions, context);
context.agent = fixture;
const marker = "Tycho stopped this run after no structured agent output stayed idle for 300 seconds.";
const block = fixture.blocks.find(b => b.kind === "run_summary");
const select = () => vm.runInContext("agentSummaryDetail(agent)", context);
const safe = detail => { assert(!detail.content.includes("SYNTHETIC_")); assert(!detail.content.includes("example.test")); };
assert(select().content.includes(marker), "new run lost the explicit idle-stop reason");
safe(select());
const savedContent = block.content;
block.content = "## Summary unavailable";
assert(select().content.includes(marker), "explicit metadata depends on raw marker text");
block.content = savedContent;

// Existing persisted summaries have no explicit reason metadata.
delete block.metadata.operator_stop_reason;
assert(select().content.includes(marker), "legacy saved run lost the exact known marker");
block.content += "\nhttps://example.test/sso?callback=SYNTHETIC_CALLBACK_SECRET\ntoken=SYNTHETIC_LOGIN_SECRET";
assert(select().content.includes(marker));
safe(select());

// Only the complete known marker is accepted, with no trailing text or variable duration.
for (const content of [`> ${marker} SYNTHETIC_LOGIN_SECRET`, `> ${marker.replace("300", "301")}`, `raw wrapper ${marker}`, `> https://example.test/sso?callback=SYNTHETIC_CALLBACK_SECRET`]) {
  block.content = content;
  assert(!select().content.includes(marker), "arbitrary raw fallback acquired an idle reason");
  safe(select());
}
block.content = "Manual stop: no usable assistant message.";
block.metadata.operator_stop_reason = "SYNTHETIC_LOGIN_SECRET";
assert(!select().content.includes(marker), "unknown reason was trusted");
safe(select());

// An earlier run must not supply a reason, error, or assistant context.
const prior = {kind: "run_summary", content: `> ${marker}`, metadata: {run_id: "earlier-run", status: "stopped", summary_fallback: true, operator_stop_reason: "no_structured_output_idle"}};
fixture.blocks.unshift({kind: "summary", content: "(error: SYNTHETIC_PRIOR_ERROR)", metadata: {run_id: "earlier-run", summary_entry_type: "error"}}, {kind: "message", role: "assistant", content: "SYNTHETIC_PRIOR_ASSISTANT", metadata: {run_id: "earlier-run"}}, prior);
assert(!select().content.includes(marker), "manual stop inherited an earlier idle reason");
safe(select());
block.metadata.operator_stop_reason = "no_structured_output_idle";
block.metadata.status = "failed";
assert(!select().content.includes(marker), "non-stopped run acquired idle-stop context");
block.metadata.status = "stopped";
const runId = block.metadata.run_id;
delete block.metadata.run_id;
assert(!select().content.includes(marker), "context without a run identity was trusted");
block.metadata.run_id = runId;

// Card293 errors keep priority; usable summaries and rich sections keep their content.
fixture.blocks.splice(fixture.blocks.indexOf(block), 0, {kind: "summary", content: "(error: Same-run structured error)", metadata: {run_id: runId, summary_entry_type: "error"}});
assert(select().content.includes("Same-run structured error"));
assert(!select().content.includes(marker), "idle reason replaced same-run error priority");
block.metadata.summary_fallback = false;
block.content = "Usable structured summary";
block.metadata.summary_sections = [{type: "text", text: "Rich summary detail"}];
assert.strictEqual(select().content, block.content);
assert.strictEqual(select().sections[0].text, "Rich summary detail");
console.log("summary idle-stop selection: ok");
