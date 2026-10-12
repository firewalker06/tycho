# frozen_string_literal: true

require "open3"
require "tempfile"

module RemoteUIAttachmentCacheRaceTest
  module_function

  ROOT = File.expand_path("..", __dir__)

  def run!
    Tempfile.create(["tycho-attachment-cache-race", ".js"]) do |script|
      script.write(<<~'JS')
        const fs = require("fs");
        const vm = require("vm");
        const assert = require("assert");
        const source = fs.readFileSync("lib/hq/remote_ui/assets/app.js", "utf8");
        const loaders = source.slice(source.indexOf("async function ensureAttachment("), source.indexOf("\nfunction render(options"));
        const preview = source.slice(source.indexOf("function summaryAttachmentPreviewAvailable"), source.indexOf("\nfunction renderSummaryAttachmentList"));
        const clear = source.slice(source.indexOf("function clearAttachmentCache"), source.indexOf("\nfunction deletedAttachmentFallbackRoute"));
        const requests = [];
        const created = [];
        const revoked = [];
        const agent = { key: "agent", run_count: 1, attachments: [{ id: "A" }, { id: "B" }, { id: "image" }] };
        let route = { type: "agentSummary", key: "agent", summaryId: "summary" };
        let visible;
        const state = { attachmentDetails: {}, attachmentRequestGenerations: {}, attachmentImageRequestGenerations: {}, attachmentImageUrls: {}, attachmentImageErrors: {}, openedAttachmentLinks: {} };
        function request(kind, id) { return new Promise((resolve, reject) => requests.push({ kind, id, resolve, reject })); }
        const context = {
          state,
          apiGet: (path) => request("metadata", path.split("/").pop()),
          apiBlob: (path) => request("image", path),
          attachmentBlobPath: (id) => id,
          URL: { createObjectURL: (blob) => { const url = `blob:${blob}`; created.push(url); return url; }, revokeObjectURL: (url) => revoked.push(url) },
          window: { matchMedia: () => ({ matches: true }) },
          document: { querySelector: () => null, querySelectorAll: () => [] },
          parseRoute: () => route,
          findAgent: (key) => key === agent.key ? agent : null,
          agentAttachments: (value) => value.attachments,
          attachmentId: (value) => value.id,
          agentSummaryDetail: () => ({ id: "summary", runNumber: 1, createdAt: "today" }),
          closeSummaryAttachmentMenus: () => {},
          attachmentFormat: (value) => value.format || "text",
          render: () => { const id = state.summaryAttachmentPreview?.id; visible = id ? [state.attachmentDetails[id]?.content, state.attachmentImageUrls[id], state.attachmentImageErrors[id]] : null; },
        };
        vm.runInNewContext(loaders + preview + clear, context);
        const metadata = (request, content, format = "text") => request.resolve({ attachment: { id: request.id, agent_key: "agent", content, format } });
        const tick = () => new Promise((resolve) => setImmediate(resolve));
        async function main() {
          const firstA = context.openSummaryAttachmentPreview("A", "agent");
          const b = context.openSummaryAttachmentPreview("B", "agent");
          metadata(requests[1], "B"); await b;
          const newestA = context.openSummaryAttachmentPreview("A", "agent");
          metadata(requests[2], "CURRENT_A"); await newestA;
          metadata(requests[0], "STALE_A"); await firstA;
          context.render();
          assert.strictEqual(visible[0], "CURRENT_A", "ordinary render used stale repeated-ID metadata");
          assert.strictEqual(state.attachmentDetails.A.content, "CURRENT_A");

          const old404 = context.ensureAttachment("A", true);
          const current = context.ensureAttachment("A", true);
          metadata(requests[4], "CURRENT_AFTER_404"); await current;
          requests[3].reject({ status: 404 }); await old404;
          context.render();
          assert.strictEqual(visible[0], "CURRENT_AFTER_404", "stale 404 erased current metadata");

          const firstImage = context.openSummaryAttachmentPreview("image", "agent");
          metadata(requests[5], "", "image"); await tick();
          assert.strictEqual(requests[6].kind, "image");
          const anotherB = context.openSummaryAttachmentPreview("B", "agent");
          metadata(requests[7], "B"); await anotherB;
          const newestImage = context.openSummaryAttachmentPreview("image", "agent");
          metadata(requests[8], "", "image"); await tick();
          requests[9].resolve("CURRENT_IMAGE"); await newestImage;
          requests[6].resolve("STALE_IMAGE"); await firstImage;
          context.render();
          assert.strictEqual(visible[1], "blob:CURRENT_IMAGE", "ordinary render used stale repeated-ID image");
          assert.deepStrictEqual(created, ["blob:CURRENT_IMAGE"], "stale response allocated a blob URL");

          const staleFailure = context.ensureAttachmentImage("image", true);
          const freshImage = context.ensureAttachmentImage("image", true);
          requests[11].resolve("NEXT_IMAGE"); await freshImage;
          requests[10].reject(new Error("stale image error")); await staleFailure;
          context.render();
          assert.strictEqual(visible[1], "blob:NEXT_IMAGE");
          assert.strictEqual(visible[2], undefined, "stale image error replaced current success");
          assert(revoked.includes("blob:CURRENT_IMAGE"), "replaced blob URL was not revoked");

          const leaving = context.openSummaryAttachmentPreview("image", "agent");
          metadata(requests[12], "", "image"); await tick();
          route = { type: "agent", key: "other" };
          context.reconcileSummaryAttachmentPreview();
          context.revokeAttachmentImageUrls();
          requests[13].resolve("AFTER_LEAVING"); await leaving;
          context.render();
          assert.strictEqual(visible, null, "late image reopened preview after agent change");
          assert.strictEqual(state.attachmentImageUrls.image, undefined, "revocation allowed a pending blob to recreate its URL");
          assert(!created.includes("blob:AFTER_LEAVING"));

          const deleting = context.ensureAttachment("A", true);
          context.clearAttachmentCache("A");
          metadata(requests[14], "AFTER_DELETE"); await deleting;
          assert.strictEqual(state.attachmentDetails.A, undefined, "late metadata recreated a deleted cache entry");
        }
        main().catch((error) => { console.error(error); process.exit(1); });
      JS
      script.flush
      out, err, status = Open3.capture3("node", script.path, chdir: ROOT)
      raise "Attachment cache race regression failed:\n#{out}#{err}" unless status.success?
    end
    puts "remote_ui_attachment_cache_race_test: ok"
  end
end

RemoteUIAttachmentCacheRaceTest.run! if $PROGRAM_NAME == __FILE__
