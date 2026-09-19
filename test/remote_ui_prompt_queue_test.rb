# frozen_string_literal: true

require "open3"

module RemoteUIPromptQueueTest
  module_function

  ROOT = File.expand_path("..", __dir__)
  APP_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.js")

  def run!
    script = <<~'JAVASCRIPT'
      const fs = require("fs");
      const vm = require("vm");
      const source = fs.readFileSync(process.argv[1], "utf8");

      function extractFunction(name) {
        const start = source.indexOf(`function ${name}`);
        if (start < 0) throw new Error(`missing ${name}`);
        const opening = source.indexOf("{", source.indexOf(")", start));
        let depth = 0;
        let quote = "";
        let escaped = false;
        for (let index = opening; index < source.length; index += 1) {
          const char = source[index];
          if (quote) {
            if (escaped) escaped = false;
            else if (char === "\\") escaped = true;
            else if (char === quote) quote = "";
            continue;
          }
          if (["'", '"', "`"].includes(char)) {
            quote = char;
            continue;
          }
          if (char === "{") depth += 1;
          if (char === "}" && --depth === 0) return source.slice(start, index + 1);
        }
        throw new Error(`unterminated ${name}`);
      }

      const context = {
        escapeAttr: (value) => String(value),
        escapeHtml: (value) => String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;"),
        personalAssistantControlError: () => null,
        renderMarkdown: (value) => `<markdown>${value}</markdown>`,
        statusBadge: (label) => `<badge>${label}</badge>`,
        titleFromKey: (value) => String(value),
        URL,
      };
      vm.createContext(context);
      vm.runInContext(`${extractFunction("renderPromptQueueEntry")}\n${extractFunction("parseDelegatedAgentReply")}\n${extractFunction("delegatedAgentReportPayload")}\n${extractFunction("renderDelegatedAgentReply")}\n${extractFunction("renderDelegatedAgentReport")}\n${extractFunction("renderDelegatedAgentReportInquiry")}\n${extractFunction("renderDelegatedAgentReportInquiryField")}\n${extractFunction("delegatedAgentReportStatusLabel")}\n${extractFunction("delegatedAgentReportAttachments")}\n${extractFunction("renderDelegatedAgentReportAttachment")}\n${extractFunction("blockStateToken")}\n${extractFunction("queueReadConversationBlock")}\n${extractFunction("renderQueueReadConversationBlock")}\nthis.renderPromptQueueEntry = renderPromptQueueEntry;\nthis.parseDelegatedAgentReply = parseDelegatedAgentReply;\nthis.renderQueueReadConversationBlock = renderQueueReadConversationBlock;`, context);

      const agent = { key: "queue-agent" };
      const legacy = context.renderPromptQueueEntry(agent, { id: "legacy", prompt: "Queued before state" }, 0);
      if (!legacy.includes("Queued</small>") || legacy.includes('data-edit-queued-prompt="legacy" data-agent-key="queue-agent" disabled') ||
          legacy.includes('data-delete-queued-prompt="legacy" data-agent-key="queue-agent" disabled')) {
        throw new Error("state-less queued entries must keep enabled edit and delete controls");
      }

      const claimed = context.renderPromptQueueEntry(agent, { id: "claimed", prompt: "Already claimed", state: "dispatching" }, 0);
      if (!claimed.includes("Dispatching</small>") || !claimed.includes('data-edit-queued-prompt="claimed" data-agent-key="queue-agent" disabled') ||
          !claimed.includes('data-delete-queued-prompt="claimed" data-agent-key="queue-agent" disabled')) {
        throw new Error("claimed queue entries must keep edit and delete controls disabled");
      }

      const callback = context.renderPromptQueueEntry(agent, {
        id: "callback", prompt: "Delegated report", state: "queued", source: "delegation_callback",
        authority: { owner: "parent", generation: 3 }
      }, 0);
      if (!callback.includes("Delegated reply · Queued · parent authority v3") ||
          callback.includes("Edit") || callback.includes("Delete")) {
        throw new Error("delegated replies must expose captured authority without edit or delete controls");
      }

      const delegatedPayload = `Delegated agent reports:\n${JSON.stringify({ type: "delegated_agent_reports", reports: [
        { agent: { name: "Success child" }, status: "success", summary: "## Finished\n\n[Build](https://example.test/build)", attachments: [{ type: "file", title: "Build", url: "https://example.test/build", description: "Verified output", mime_type: "text/html" }] },
        { agent: { agent_key: "needs-input" }, status: "input_required", summary: "Waiting.", inquiry: { message: "Choose a release target.", fields: [{ key: "target", label: "Target <script>", description: "Where to deploy", input_type: "select", options: ["Staging", "<Production>"] }] }, attachments: [{ title: "Unsafe", url: "javascript:alert(1)" }, { title: "Credentials", url: "https://user:secret@example.test/private" }] },
        { agent: { name: "Partial child" }, status: "partial", summary: "Partial result." },
        { agent: { name: "Failed child" }, status: "failed", summary: "Failed result." },
        { agent: { name: "Blocked child" }, status: "blocked", summary: "Blocked result." },
        { agent: { name: "Stopped child" }, status: "stopped", summary: "Stopped result." },
        { agent: { name: "Quiet child" }, status: "no_action_needed", summary: "No action." },
      ] })}`;
      const renderedDelegated = context.renderPromptQueueEntry(agent, {
        id: "delegated", prompt: delegatedPayload, state: "queued", source: "delegation_callback"
      }, 0);
      if (!renderedDelegated.includes("Success child") || !renderedDelegated.includes("Input required") ||
          !renderedDelegated.includes("Choose a release target.") || !renderedDelegated.includes("Partial") ||
          !renderedDelegated.includes("Failed") || !renderedDelegated.includes("Blocked") ||
          !renderedDelegated.includes("Stopped") || !renderedDelegated.includes("No action needed") ||
          !renderedDelegated.includes("Target &lt;script&gt;") || !renderedDelegated.includes("&lt;Production&gt;") ||
          !renderedDelegated.includes("File · text/html") || !renderedDelegated.includes("Verified output") ||
          renderedDelegated.includes("javascript:alert") || renderedDelegated.includes("user:secret") ||
          renderedDelegated.includes("Edit") || renderedDelegated.includes("Delete")) {
        throw new Error("delegated report payload was not safely rendered as readable content");
      }

      const legacyPayload = `Delegated agent report:\n${JSON.stringify({ type: "delegated_agent_report", agent: { name: "Legacy child" }, status: "succeeded", summary: "Legacy result." })}`;
      if (!context.renderPromptQueueEntry(agent, { id: "legacy-report", prompt: legacyPayload, source: "delegation_callback" }, 0).includes("Legacy child")) {
        throw new Error("legacy delegated report shape was not parsed");
      }
      const malformed = context.renderPromptQueueEntry(agent, { id: "malformed", prompt: "{not json", source: "delegation_callback" }, 0);
      if (!malformed.includes("{not json") || malformed.includes("<markdown>")) {
        throw new Error("malformed delegated payload did not retain the safe raw fallback");
      }
      const unrecognizedPrompt = JSON.stringify({ type: "other_callback", reports: [{ status: "success", summary: "Do not parse" }] });
      const unrecognized = context.renderPromptQueueEntry(agent, { id: "unknown", prompt: unrecognizedPrompt, source: "delegation_callback" }, 0);
      if (!unrecognized.includes("other_callback") || unrecognized.includes("<markdown>")) {
        throw new Error("unrecognized delegated payload did not retain the safe raw fallback");
      }
      const malformedReportPrompt = JSON.stringify({ type: "delegated_agent_reports", reports: [{ summary: "Missing status" }] });
      if (context.parseDelegatedAgentReply({ prompt: malformedReportPrompt, source: "delegation_callback" }) !== null) {
        throw new Error("malformed recognized reports must use the raw fallback");
      }
      const ordinary = context.renderPromptQueueEntry(agent, { id: "ordinary", prompt: delegatedPayload, source: "user" }, 0);
      if (!ordinary.includes("Delegated agent reports:") || ordinary.includes("Success child</strong><badge>")) {
        throw new Error("ordinary messages must not be interpreted as delegated reports");
      }

      const readQueueHtml = context.renderQueueReadConversationBlock({
        id: "queue-read-1", kind: "message", role: "user", content: `Review the failing test\n\n---\n\n${delegatedPayload}`,
        metadata: {
          queue_read: true, read_label: "Read queue", prompt_queue_entry_count: 2,
          prompt_queue_entries: [
            { id: "user-entry", prompt: "Review the failing test", source: "user", state: "read", attachments: [] },
            { id: "delegated-entry", prompt: delegatedPayload, source: "delegation_callback", state: "read", attachments: [] },
          ],
        },
      }, 0, { agent });
      if (!readQueueHtml.includes("data-queue-read-block") ||
          !readQueueHtml.includes('aria-label="Read queue, 2 entries read"') ||
          (readQueueHtml.match(/data-prompt-queue-entry=/g) || []).length !== 2 ||
          !readQueueHtml.includes("Review the failing test") || !readQueueHtml.includes("Success child") ||
          readQueueHtml.includes("---") || readQueueHtml.includes("Edit") || readQueueHtml.includes("Delete")) {
        throw new Error("Read queue must render as a concise expandable block with structured read-only entries");
      }

      const requestContext = {
        personalAssistantAgent: () => false,
        findAgent: () => null,
        personalAssistantSessionContext: () => null,
      };
      vm.createContext(requestContext);
      vm.runInContext(`${extractFunction("personalAssistantEndpointAdapter")}\nthis.personalAssistantEndpointAdapter = personalAssistantEndpointAdapter;`, requestContext);
      const clientRequestId = "client-queue-reconciliation";
      const adapter = requestContext.personalAssistantEndpointAdapter("queue-agent", { personalAssistant: false });
      const requestBody = adapter.writeBody({ prompt: "One queued prompt", start: true }, clientRequestId);
      if (requestBody.client_request_id !== clientRequestId) {
        throw new Error("generic queued submissions must send their optimistic ID for server reconciliation");
      }

      const queueContext = {
        escapeAttr: (value) => String(value),
        escapeHtml: (value) => String(value),
        iconSvg: () => "",
        personalAssistantControlError: () => null,
        optimisticPromptQueueEntries: () => [{
          id: clientRequestId, prompt: "One queued prompt", state: "queued", attachments: []
        }],
      };
      vm.createContext(queueContext);
      vm.runInContext(`${extractFunction("renderPromptQueueEntry")}\n${extractFunction("parseDelegatedAgentReply")}\n${extractFunction("delegatedAgentReportPayload")}\n${extractFunction("renderPromptQueue")}\nthis.renderPromptQueue = renderPromptQueue;`, queueContext);
      const queueHtml = queueContext.renderPromptQueue({
        key: "queue-agent",
        prompt_queue: { entries: [{
          id: requestBody.client_request_id, prompt: requestBody.prompt, state: "queued", source: "user"
        }] },
      });
      if ((queueHtml.match(/data-prompt-queue-entry=/g) || []).length !== 1 || !queueHtml.includes("1 queued")) {
        throw new Error("one accepted queued submission must reconcile to one rendered queue row");
      }
    JAVASCRIPT

    output, status = Open3.capture2e("node", "-e", script, APP_PATH)
    raise output unless status.success?

    puts "remote_ui_prompt_queue_test: ok"
  end
end

RemoteUIPromptQueueTest.run! if $PROGRAM_NAME == __FILE__
