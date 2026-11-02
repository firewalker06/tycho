# frozen_string_literal: true

require "open3"

script = <<~'JS'
  const assert = require("node:assert/strict"), fs = require("node:fs"), vm = require("node:vm");
  const app = fs.readFileSync("lib/hq/remote_ui/assets/app.js", "utf8");
  const source = name => app.match(new RegExp(`^(?:async )?function ${name}\\([^]*?^}`, "m"))[0];
  (async () => {
    for (const key of ["agent", "peer/agent"]) for (const current of ["A", "B"]) for (const projection of ["valid", "missing", "wrong-agent", "answered-A"]) {
      let release, reads = 0, refreshes = 0;
      const held = new Promise(resolve => release = resolve);
      const context = {state: {agentDetails: {[key]: {key, latest_inquiry: {id: current}, awaiting_input: true}},
        agents: [], activityAgents: new Map([[key,{key,awaiting_input:false}]]), activityReadyServerKeys: new Set(),
        agentDetailGenerations: new Map(), resourceMutationGeneration: 0,
        pendingPromptAttachments: {}, pendingInquirySubmissionDrafts: new Map()},
        TychoInquirySubmissions: {storage: () => ({}), Answers: function(options) {Object.assign(this,options); this.ready=Promise.resolve();}},
        pendingAttachmentsFor: () => [], safeLocalStorageRemove: () => {}, revokePendingAttachment: () => {},
        render: () => {}, showGrowl: () => {}, setConnection: () => {},
        resourceRequest: () => ({server:{key:"peer"}}),
        scopeApiResponse: data => ({...data, agent: {...data.agent,key}}),
        activityFields: agent => ({awaiting_input:agent.awaiting_input}),
        reconcileOptimisticPromptQueue: () => {},
        apiGet: async () => {reads++; return held;},
        refresh: async () => {refreshes++; await held;}};
      vm.createContext(context); vm.runInContext("let inquiryAnswers;",context);
      for (const name of ["upsertAgent","ensureAgentDetail","agentDetailGeneration","refreshAnsweredInquiry","inquirySubmissionKey","inquiryAnswerStore"]) vm.runInContext(source(name),context);
      const stale = context.ensureAgentDetail(key,true);
      const receipt = {start_result:"not_started"};
      const data = {agent:{key:"agent",latest_inquiry:null,awaiting_input:false,status:"idle"},answer_receipt:receipt};
      if(projection==="missing") delete data.agent;
      if(projection==="wrong-agent") data.agent.key="unrelated";
      if(projection==="answered-A") data.agent.latest_inquiry={id:"A"};
      context.inquiryAnswerStore().accepted({key,inquiryId:"A",payload:{},destination:{agent_key:"agent"}},receipt,data);
      await Promise.resolve();
      assert.equal(context.state.agentDetails[key].latest_inquiry?.id || null,current==="B"?"B":null,"accepted result applied before held display reads");
      assert.equal(context.state.activityAgents.get(key).awaiting_input,current==="B","canonical activity preserves B instead of replaying old A activity");
      assert.equal(reads,1,"no standalone answer detail GET");
      assert.equal(refreshes,1,"one background reconciliation starts without waiting for detail");
      release({agent:{key,latest_inquiry:{id:"A"},awaiting_input:true}}); await stale;
      assert.equal(context.state.agentDetails[key].latest_inquiry?.id || null,current==="B"?"B":null,"older read cannot resurrect A or overwrite B");
    }
    console.log("inquiry display response and held reconciliation: ok");
  })().catch(error=>{console.error(error);process.exitCode=1;});
JS
out, err, status = Open3.capture3("node", "-e", script)
raise "Inquiry display regression failed:\n#{out}#{err}" unless status.success?
puts "remote_ui_inquiry_display_test: ok"
