# frozen_string_literal: true

require "open3"

module RemoteUIInquiryReceiptsTest
  module_function

  def run!
    script = <<~'JS'
      const assert = require("node:assert/strict");
      const fs = require("node:fs");
      const vm = require("node:vm");
      const context = {AbortController};
      vm.createContext(context);
      vm.runInContext(fs.readFileSync("lib/hq/remote_ui/assets/inquiry_submissions.js","utf8"),context);
      const {Answers,validate} = context.TychoInquirySubmissions;
      const entry={id:"intent",key:"peer/agent",inquiryId:"old-inquiry",destination:{agent_key:"agent",server_id:"server"},payload:{answer:"Synthetic",feedback:"Feedback",attachments:[{filename:"synthetic.txt",content_base64:"eA=="}]}};
      const receipt={version:1,client_request_id:"intent",agent_key:"agent",server_id:"server",inquiry_id:"old-inquiry",accepted:true,replayed:false,accepted_at:"2026-11-02T11:00:00Z",start_result:"not_requested",authority:null};
      validate({answer_receipt:receipt},entry);
      for(const patch of [{version:2},{server_id:"other"},{agent_key:"other"},{inquiry_id:"new-inquiry"},{client_request_id:"other"},{accepted:false},{accepted_at:"bad"},{start_result:"anything"},{replayed:null},{authority:{owner:"parent",generation:2}}]) assert.throws(()=>validate({answer_receipt:{...receipt,...patch}},entry));
      (async()=>{
        for(const response of [null,{}, {answer_receipt:{}}, "invalid", {answer_rejection:{...receipt,inquiry_id:"new-inquiry"}}]) {
          const disk=new Map();let writes=0,accepted=0;
          const store={all:async()=>[...disk.values()],put:async value=>disk.set(value.key,structuredClone(value)),remove:async key=>disk.delete(key)};
          const answers=new Answers({store,send:async()=>{writes++;return response},accepted:()=>accepted++});
          await answers.add(structuredClone(entry));
          assert.equal(answers.entries.get(entry.key).status,"uncertain");
          assert.deepEqual(disk.get(entry.key).payload,entry.payload);
          const restored=new Answers({store,send:async value=>{writes++;assert.deepEqual(value.payload,entry.payload);return {answer_receipt:{...receipt,replayed:true}}},accepted:()=>accepted++});
          await restored.ready;
          assert.equal(writes,1,"reload never sends automatically");
          await restored.retry(entry.key);
          assert.equal(writes,2);assert.equal(accepted,1);assert.equal(disk.size,0);
        }
        for(const status of [401,404,409,500]) {
          const store={all:async()=>[],put:async()=>{},remove:async()=>{throw Error("must retain")}};
          const answers=new Answers({store,send:async()=>{const error=Error("Unbound error");error.status=status;throw error;}});
          await answers.add(structuredClone(entry));
          assert.equal(answers.entries.get(entry.key).status,"uncertain");
          await assert.rejects(answers.add({...entry,id:"fresh"}));
        }
        const disk=new Map();const store={all:async()=>[],put:async value=>disk.set(value.key,structuredClone(value)),remove:async key=>disk.delete(key)};
        const answers=new Answers({store,send:async()=>({answer_rejection:{...receipt},error:"Invalid answer"})});
        await answers.add(structuredClone(entry));
        assert.equal(answers.entries.get(entry.key).status,"rejected");
        assert.deepEqual(disk.get(entry.key).payload,entry.payload,"bound rejection keeps correction inputs");
        let writes=0;
        const unavailable=new Answers({store:{all:async()=>[],put:async()=>{throw Error("storage unavailable")}},send:async()=>writes++});
        await assert.rejects(unavailable.add(structuredClone(entry)));
        assert.equal(writes,0,"storage failure prevents the first write");
        console.log("inquiry answer validation, exact retry, reload, rejection and storage: ok");
      })().catch(error=>{console.error(error);process.exitCode=1});
    JS
    out, err, status = Open3.capture3("node", "-e", script, chdir: File.expand_path("..", __dir__))
    raise "Inquiry browser contract failed:\n#{out}#{err}" unless status.success?

    puts "remote_ui_inquiry_receipts_test: ok"
  end
end

RemoteUIInquiryReceiptsTest.run! if $PROGRAM_NAME == __FILE__
