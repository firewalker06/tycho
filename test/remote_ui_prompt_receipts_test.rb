# frozen_string_literal: true

require "open3"

module RemoteUIPromptReceiptsTest
  module_function

  def run!
    script = <<~'JS'
      const assert = require("node:assert/strict");
      const fs = require("node:fs");
      const vm = require("node:vm");
      const context = { console, setTimeout, clearTimeout, structuredClone };
      vm.createContext(context);
      vm.runInContext(fs.readFileSync("lib/hq/remote_ui/assets/prompt_submissions.js", "utf8"), context);
      const { validateReceipt, Outbox, createReconciler } = context.TychoPromptSubmissions;
      const destination = { agent_key: "agent", server_id: "server" };
      const receipt = { version: 1, accepted: true, client_request_id: "client-one", agent_key: "agent", server_id: "server", outcome: "accepted", replayed: false, accepted_at: "2026-01-01T00:00:00Z", revision: "1", running: false, source: "user", authority: null, queue_entry: null };
      const valid = { accepted: true, queued: false, receipt };
      validateReceipt(valid, { id: "client-one", destination });
      for (const change of [{ accepted: false }, { receipt: null }, { receipt: {...receipt, server_id: "other"} }, { receipt: {...receipt, agent_key: "other"} }, { receipt: {...receipt, client_request_id: "client-two"} }, { receipt: {...receipt, outcome: "completed"} }, { receipt: {...receipt, revision: "bad"} }, { receipt: {...receipt, accepted_at: "bad"} }, { receipt: {...receipt, accepted_at: "1"} }, { receipt: {...receipt, outcome: "replayed", replayed: false} }, { receipt: {...receipt, authority: { owner: "parent", generation: -1 }} }]) {
        assert.throws(() => validateReceipt({...valid, ...change}, { id: "client-one", destination }));
      }
      const app = fs.readFileSync("lib/hq/remote_ui/assets/app.js", "utf8");
      let localRows = [{id:"client-consumed",state:"queued",receipt_revision:"2",local_pending:true}];
      const reconcileContext = {state:{},arrayValue:value=>Array.isArray(value)?value:[],optimisticPromptQueueEntries:()=>localRows,persistOptimisticPromptQueue:(_key,rows)=>{localRows=rows;}};
      vm.createContext(reconcileContext);
      vm.runInContext(app.match(/^function reconcileOptimisticPromptQueue\([^]*?^}/m)[0],reconcileContext);
      reconcileContext.reconcileOptimisticPromptQueue({key:"agent",revision:"1",prompt_queue:{entries:[]}},{confirmedRead:true});
      assert.equal(localRows.length,1,"A stale read cannot erase an accepted receipt row");
      reconcileContext.reconcileOptimisticPromptQueue({key:"agent",revision:"2",prompt_queue:{entries:[]}},{confirmedRead:true});
      assert.equal(localRows.length,0,"Current empty queue confirms that accepted work has left the queue");
      const queued = [];
      const callContext = {
        crypto: { randomUUID: () => "00000000-0000-4000-8000-000000000001" },
        state: {pendingComposerKeys:new Set(),pendingPullRequestCommentKeys:new Set(),pendingConversationMessages:{},promptSubmissionOptions:new Map(),composerDraftRevisions:{}},
        findAgent: () => ({key:"peer/agent",resource_key:"agent",prompt_receipt_version:1,delegation:{server_id:"server"}}),
        agentIsRunning: () => false,
        promptSubmissionFor: () => null,
        selectedPullRequestCommentContext: () => ({id:"selection",comment:"Synthetic PR comment",pull_request_id:"pr",snapshot_id:"snapshot",lines:[]}),
        pendingPromptMessageBlock: () => ({id:"pending",metadata:{}}),
        addPendingConversationMessage: () => "pending", syncPullRequestDiffSelection: () => {}, render:()=>{},
        resourceRequest: () => ({path:"/servers/peer/agents/agent/messages",server:{key:"peer",url:"https://peer.example.test",token:"PRIVATE_TEST_CREDENTIAL"}}),
        resourceRawKey: agent => agent.resource_key,
        promptPullRequestContextPayload: value => ({pull_request_id:value.pull_request_id,snapshot_id:value.snapshot_id,lines:[]}),
        promptSubmissionOutbox: () => ({add: entry => {queued.push(entry);return Promise.resolve();}}),
      };
      vm.createContext(callContext);
      for(const name of ["enqueueComposerSubmission","sendSelectedPullRequestComment"]) {
        const code = app.match(new RegExp(`^function ${name}\\([^]*?^}`,"m"))[0];
        vm.runInContext(code,callContext);
      }
      callContext.sendSelectedPullRequestComment("peer/agent","pr");
      assert.equal(queued.length,1,"PR line comments use the same ordered send lane");
      assert(queued[0].payload.client_request_id,"PR context sends have a stable ID");
      assert.equal(queued[0].destination.agent_key,"agent");
      assert.equal(queued[0].destination.server_id,"server");
      assert.equal(queued[0].destination.path,"/servers/peer/agents/agent/messages");
      assert.equal(queued[0].payload.pull_request_contexts[0].snapshot_id,"snapshot");
      assert(!JSON.stringify(queued[0]).includes("PRIVATE_TEST_CREDENTIAL"),"Pending records never retain credentials");
      callContext.crypto = undefined;
      callContext.enqueueComposerSubmission({key:"peer/agent",prompt:"Plain HTTP idle send",queueing:false,submittedAttachments:[],submittedPullRequestContexts:[]});
      assert.match(queued[1].payload.client_request_id,/^client-[a-zA-Z0-9-]+$/,"Non-secure HTTP does not require crypto.randomUUID");
      const tick = () => new Promise(resolve => setTimeout(resolve, 0));
      (async () => {
        const disk = new Map();
        const storage = { all: async () => [...disk.values()], put: async entry => disk.set(entry.id, structuredClone(entry)), remove: async id => disk.delete(id) };
        const sent = [], accepted = [], errors = [];
        let fail = true, release;
        const heldRead = new Promise(resolve => {release = resolve});
        const outbox = new Outbox({ storage, send: async entry => {
          sent.push(entry.id);
          if (entry.id === "client-one" && fail) throw Error("Lost response after commit");
          return {...valid, receipt: {...receipt, client_request_id: entry.id, outcome: entry.id === "client-one" ? "replayed" : "accepted", replayed: entry.id === "client-one"}};
        }, onAccepted: entry => {accepted.push(entry.id); return heldRead;}, onError: entry => errors.push(entry.id) });
        await outbox.ready;
        await outbox.add({ id: "client-one", key: "peer/agent", destination, payload: {prompt: "one"} });
        await outbox.add({ id: "client-two", key: "peer/agent", destination, payload: {prompt: "two"} });
        await tick();
        assert.equal(sent.join(","), "client-one", "Uncertain first write holds later writes");
        assert(disk.has("client-one"), "Lost response retains exact intent");
        assert.equal(errors.join(","), "client-one");
        fail = false;
        await outbox.retry("client-one");
        await tick(); await tick();
        assert.equal(sent.join(","), "client-one,client-one,client-two", "Exact retry then ordered next write");
        assert.equal(accepted.join(","), "client-one,client-two", "Held read does not hold write lane");
        release();
        await tick();
        assert.equal(disk.size, 0, "Accepted payloads leave storage");
        disk.set("client-restored", {id:"client-restored",key:"peer/agent",destination,payload:{prompt:"saved"}});
        const restored = new Outbox({storage,send:()=>{throw Error("must not auto-send on reload")}});
        await restored.ready;
        assert.equal(restored.entries.get("client-restored").status, "uncertain");
        disk.clear();
        const rejected = [];
        const negative = new Outbox({storage, send: async entry => {
          const error = new Error("Inquiry changed");
          error.status = 409;
          error.data = {rejection:{version:1,client_request_id:entry.id,agent_key:"agent",server_id:"server"}};
          throw error;
        },onError:(entry,error)=>rejected.push(error.rejected)});
        await negative.ready;
        await negative.add({id:"client-rejected",key:"peer/agent",destination,payload:{prompt:"invalid"}});
        await tick(); await tick();
        assert.equal(negative.entries.size,0,"Bound durable rejection releases correction");
        assert.deepEqual(rejected,[true]);
        assert.equal(disk.size,0,"Rejected payload leaves browser storage");
        for (const status of [404,409]) {
          for (const unbound of [null,{version:1,client_request_id:"client-other",agent_key:"agent",server_id:"server"}]) {
            const retained = new Map(), attempts = [], flags = [];
            const uncertain = new Outbox({storage:{all:async()=>[],put:async entry=>retained.set(entry.id,entry),remove:async id=>retained.delete(id)},
              send:async entry=>{attempts.push(entry.id);const error=new Error("Unbound context error");error.status=status;error.data={rejection:unbound};throw error;},
              onError:(_entry,error)=>flags.push(error.rejected)});
            await uncertain.ready;
            await uncertain.add({id:"client-unbound",key:"peer/agent",destination,payload:{prompt:"retain exact context"}});
            await uncertain.add({id:"client-after-unbound",key:"peer/agent",destination,payload:{prompt:"next"}});
            await tick();await tick();
            assert.equal(uncertain.entries.get("client-unbound").status,"uncertain");
            assert.deepEqual(attempts,["client-unbound"],"Plain or mismatched 404/409 must not release later writes");
            assert(retained.has("client-unbound"));
            assert(flags.every(flag=>flag!==true));
          }
        }
        let reads = 0, readRelease;
        const reconciler = createReconciler(async () => { reads++; if(reads===1) await new Promise(resolve=>{readRelease=resolve}); else throw Error("read failed after accepted write"); });
        reconciler.request(); await tick();
        reconciler.request(); reconciler.request();
        assert.equal(reads, 1);
        readRelease(); await tick(); await tick();
        assert.equal(reads, 2, "Burst during a held read coalesces into one later read");
        console.log("prompt receipts, exact retry, ordered writes, and coalesced reads: ok");
      })().catch(error => {console.error(error);process.exitCode=1});
    JS
    out, err, status = Open3.capture3("node", "-e", script, chdir: File.expand_path("..", __dir__))
    raise "Prompt submission regression failed:\n#{out}#{err}" unless status.success?

    puts "remote_ui_prompt_receipts_test: ok"
  end
end

RemoteUIPromptReceiptsTest.run! if $PROGRAM_NAME == __FILE__
