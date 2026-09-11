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
        escapeHtml: (value) => String(value),
        personalAssistantControlError: () => null,
      };
      vm.createContext(context);
      vm.runInContext(`${extractFunction("renderPromptQueueEntry")}\nthis.renderPromptQueueEntry = renderPromptQueueEntry;`, context);

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
          !callback.includes('data-edit-queued-prompt="callback" data-agent-key="queue-agent" disabled') ||
          !callback.includes('data-delete-queued-prompt="callback" data-agent-key="queue-agent" disabled')) {
        throw new Error("delegated replies must expose captured authority and immutable controls");
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
      vm.runInContext(`${extractFunction("renderPromptQueueEntry")}\n${extractFunction("renderPromptQueue")}\nthis.renderPromptQueue = renderPromptQueue;`, queueContext);
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
