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
      const { validateReceipt, Outbox: RealOutbox, createReconciler } = context.TychoPromptSubmissions;
      // In-memory adapters implement the same atomic storage decisions as IndexedDB.
      function Outbox(options) {
        const storage = options.storage;
        const stopped = new Set();
        return new RealOutbox({...options,storage:{...storage,
          put: async entry => {
            if(stopped.has(entry.id)) return false;
            await storage.put(entry); return true;
          },
          cancel: async id => {await storage.put({id,status:"cancelled"});stopped.add(id);},
          isCancelled: async id => stopped.has(id),
          remove: async id => {if(stopped.has(id))return false;await storage.remove(id);return true;},
          start: async (id,send) => stopped.has(id) ? {started:false} : {started:true,result:send()},
        }});
      }
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
      const boundProofs=[];
      const proofContext={
        promptSubmissionOutbox:()=>({intentFor:id=>id==="client-one"?{destination:{url:"https://peer.example.test"}}:null,reconcile:(key,proofs)=>boundProofs.push({key,proofs})}),
        resourceServer:()=>({url:"https://peer.example.test"}),resourceRawKey:agent=>agent.resource_key,
      };
      vm.createContext(proofContext);
      vm.runInContext(app.match(/^function reconcilePromptSubmissions\([^]*?^}/m)[0],proofContext);
      proofContext.reconcilePromptSubmissions({key:"peer/agent",resource_key:"agent",delegation:{server_id:"server"},prompt_acceptances:[valid]});
      assert.equal(boundProofs[0].proofs.length,1,"Controller passes proof for an owned in-flight intent after its retry was cancelled");
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
        const proofDisk = new Map(), proofAccepted = [], proofCancelled = [];
        const proofStorage = {all:async()=>[...proofDisk.values()],put:async entry=>proofDisk.set(entry.id,structuredClone(entry)),remove:async id=>proofDisk.delete(id)};
        let late;
        const proving = new Outbox({storage:proofStorage,send:()=>new Promise(resolve=>{late=resolve}),onAccepted:entry=>proofAccepted.push(entry.id),onCancelled:entry=>proofCancelled.push(entry.id)});
        await proving.ready;
        await proving.add({id:"client-one",key:"peer/agent",destination,payload:{prompt:"same text"}});
        await tick();
        await proving.reconcile("other/agent",[valid]);
        assert.equal(proving.entries.size,1,"Other routed destination cannot acknowledge an intent");
        await proving.reconcile("peer/agent",[{...valid,receipt:{...receipt,server_id:"wrong"}}]);
        assert.equal(proving.entries.size,1,"Wrong server proof cannot acknowledge an intent");
        await proving.reconcile("peer/agent",[valid]);
        assert.equal(proving.entries.size,0,"A stable server proof clears a sending intent before its response");
        late(valid); await tick();
        assert.deepEqual(proofAccepted,["client-one"],"Late response cannot apply acceptance twice");
        await proving.add({id:"client-two",key:"peer/agent",destination,payload:{prompt:"same text"}});
        await tick();
        await proving.reconcile("peer/agent",[valid]);
        assert.equal(proving.entries.size,1,"Equal text with a distinct ID stays distinct");
        await proving.cancel("client-two");
        late({...valid,receipt:{...receipt,client_request_id:"client-two"}}); await tick();
        assert.equal(proving.entries.size,0,"Cancellation survives late acceptance");
        assert.deepEqual(proofCancelled,["client-two"]);
        assert.deepEqual(proofAccepted,["client-one"]);
        const reloadProof = new Outbox({storage:proofStorage,send:()=>{throw Error("No replay after cancel")}});
        await reloadProof.ready;
        assert.equal(reloadProof.entries.size,0,"Cancellation persists through reload");
        await proving.add({id:"client-three",key:"peer/agent",destination,payload:{prompt:"late malformed"}});
        await tick();
        await proving.cancel("client-three");
        late({}); await tick();
        assert.equal(proving.entries.size,0,"Late malformed reply cannot restore cancelled error UI");
        const failedCancel = new Outbox({storage:{all:async()=>[],put:async entry=>{if(entry.status==="cancelled")throw Error("disk unavailable");},remove:async()=>{}},send:async()=>{throw Error("uncertain")}});
        await failedCancel.ready;
        await failedCancel.add({id:"client-failed-cancel",key:"peer/agent",destination,payload:{prompt:"keep exact ID"}});
        await tick();
        await assert.rejects(()=>failedCancel.cancel("client-failed-cancel"));
        assert.equal(failedCancel.entries.get("client-failed-cancel").status,"uncertain","Failed cancellation keeps a truthful recoverable intent");
        for (const lateMode of ["success","error","invalid"]) {
          const laneSent=[], laneAccepted=[], laneErrors=[], replies={};
          const laneBox = new Outbox({storage:{all:async()=>[],put:async()=>{},remove:async()=>{}},
            send:entry=>{laneSent.push(entry.id);return new Promise((resolve,reject)=>{replies[entry.id]={resolve,reject};});},
            onAccepted:entry=>laneAccepted.push(entry.id),onError:entry=>laneErrors.push(entry.id)});
          await laneBox.add({id:"client-one",key:"agent",destination,payload:{prompt:"one"}});
          await tick();
          await laneBox.add({id:"client-two",key:"agent",destination,payload:{prompt:"two"}});
          await laneBox.reconcile("agent",[valid]);
          await tick();
          assert.deepEqual(laneSent,["client-one","client-two"],"Proof releases A without its HTTP response");
          await laneBox.add({id:"client-three",key:"agent",destination,payload:{prompt:"three"}});
          if(lateMode==="error")replies["client-one"].reject(Error("late"));
          else replies["client-one"].resolve(lateMode==="invalid"?{}:valid);
          await tick();
          assert.deepEqual(laneSent,["client-one","client-two"],"Old A cannot unlock B's lane");
          replies["client-two"].resolve({...valid,receipt:{...receipt,client_request_id:"client-two"}});
          await tick();await tick();
          assert.deepEqual(laneSent,["client-one","client-two","client-three"]);
          replies["client-three"].resolve({...valid,receipt:{...receipt,client_request_id:"client-three"}});
          await tick();await tick();
          assert.deepEqual(laneAccepted,laneSent);
          assert.deepEqual(laneErrors,[]);
          assert.equal(laneBox.lanes.size,0);
        }
        const readonlyError=new Error("Synthetic file read error");
        Object.defineProperty(readonlyError,"message",{value:"Synthetic file read error",writable:false});
        const readonlyBox=new Outbox({storage:{all:async()=>[],put:async()=>{},remove:async()=>{}},send:async()=>{throw readonlyError;}});
        await readonlyBox.ready;
        await readonlyBox.add({id:"client-readonly",key:"agent",destination,payload:{prompt:"keep exact intent"}});
        await tick();await tick();
        assert.equal(readonlyBox.entries.get("client-readonly").status,"uncertain","Read-only error properties must not break uncertain recovery");
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
