# frozen_string_literal: true

require "open3"

module RemoteUIInquiryRecoveryTest
  module_function

  def run!
    script = <<~'JS'
      const assert = require("node:assert/strict");
      const fs = require("node:fs");
      const vm = require("node:vm");
      const app = fs.readFileSync("lib/hq/remote_ui/assets/app.js","utf8");
      const source = name => {
        const found = app.match(new RegExp(`^(?:async )?function ${name}\\([^]*?^}`,"m"));
        assert(found,`production function ${name}`); return found[0];
      };
      const original = [{type:"text",value:"OLD answer"},{type:"textarea",value:"OLD feedback"}];
      const corrected = [{type:"text",value:"NEW answer"},{type:"textarea",value:"NEW feedback"}];
      for(const inMemorySnapshot of [false,true]) {
        const controls = original.map(value=>({...value}));
        const form = {dataset:{agentKey:"agent",inquiryId:"A"}};
        let raw = JSON.stringify({controls:Object.fromEntries(corrected.map((value,i)=>[String(i),value]))});
        const context={els:{view:{querySelectorAll:()=>[form]}},
          state:{pendingInquirySubmissionDrafts:new Map(inMemorySnapshot?[["agent:A",original]]:[])},
          safeLocalStorageGet:()=>raw,formDraftStorageKey:()=>"draft-A",formDraftControls:()=>controls,
          elementStateKey:(_control,i)=>String(i),clearFormDraft:()=>{raw=null;},
          inquiryAnswerStore:()=>({entries:new Map([["agent",{inquiryId:"A",controls:original,status:"rejected"}]])})};
        vm.createContext(context);
        for(const name of ["inquirySubmissionKey","restoreInquirySubmissionDraft","restoreFormDrafts"]) vm.runInContext(source(name),context);
        context.restoreFormDrafts();
        assert.deepEqual(controls.map(control=>control.value),["NEW answer","NEW feedback"],"editable correction wins over immutable retry snapshot");
        raw=null;context.restoreFormDrafts();
        assert.deepEqual(controls.map(control=>control.value),["OLD answer","OLD feedback"],"snapshot remains a fallback when no editable draft exists");
        for(const otherForm of [{dataset:{agentKey:"agent"}},{dataset:{}},null]) {
          assert.doesNotThrow(()=>context.restoreInquirySubmissionDraft(otherForm),"non-inquiry forms never use an inquiry snapshot");
          assert.deepEqual(controls.map(control=>control.value),["OLD answer","OLD feedback"],"composer restoration leaves inquiry controls alone");
        }
      }
      (async()=>{
        for(const fail of [false,true]) {
          for(const current of ["A","B"]) {
            const removed=[],revoked=[];
            const context={state:{agentDetails:{agent:{latest_inquiry:{id:current},awaiting_input:true}},
              agentDetailGenerations:new Map(),pendingPromptAttachments:{agent:[{id:"file-A"},{id:"file-B"}]},
              pendingInquirySubmissionDrafts:new Map([["agent:A",original],["agent:B",corrected]])},
              TychoInquirySubmissions:{storage:()=>({}),Answers:function(options){this.ready=Promise.resolve();this.accepted=options.accepted;}},
              pendingAttachmentsFor:()=>context.state.pendingPromptAttachments.agent,
              revokePendingAttachment:file=>revoked.push(file.id),safeLocalStorageRemove:key=>removed.push(key),
              ensureAgentDetail:async()=>{if(fail) throw Error("Synthetic read failure");},
              refresh:async()=>{if(fail) throw Error("Synthetic shell failure");},render:()=>{},setConnection:()=>{},showGrowl:()=>{}};
            vm.createContext(context);
            vm.runInContext("let inquiryAnswers;",context);
            for(const name of ["agentDetailGeneration","refreshAnsweredInquiry","inquirySubmissionKey","inquiryAnswerStore"]) vm.runInContext(source(name),context);
            context.inquiryAnswerStore().accepted({key:"agent",inquiryId:"A",attachmentIds:["file-A"],draftStorageKey:"draft-A"},{start_result:"started"});
            await new Promise(resolve=>setTimeout(resolve,0));
            assert.deepEqual(context.state.pendingPromptAttachments.agent.map(file=>file.id),["file-B"]);
            assert.deepEqual(revoked,["file-A"],"only accepted A file is revoked");
            assert.deepEqual(removed,["draft-A"],"B draft is not removed");
            assert(context.state.pendingInquirySubmissionDrafts.has("agent:B"));
            if(current==="B") {
              assert.equal(context.state.agentDetails.agent.latest_inquiry.id,"B");
              assert.equal(context.state.agentDetails.agent.awaiting_input,true);
            } else if(fail) {
              assert.equal(context.state.agentDetails.agent.latest_inquiry,null,"failed read may clear answered A only");
              assert.equal(context.state.agentDetails.agent.awaiting_input,false);
            }
          }
        }
        console.log("inquiry correction drafts, identity-bound fallback and consumed files: ok");
      })().catch(error=>{console.error(error);process.exitCode=1});
    JS
    out, err, status = Open3.capture3("node", "-e", script, chdir: File.expand_path("..", __dir__))
    raise "Inquiry recovery regression failed:\n#{out}#{err}" unless status.success?

    puts "remote_ui_inquiry_recovery_test: ok"
  end
end

RemoteUIInquiryRecoveryTest.run! if $PROGRAM_NAME == __FILE__
