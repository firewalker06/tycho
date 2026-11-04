# frozen_string_literal: true

require_relative "remote_server_test"

module InquiryReceiptTest
  module_function

  def inquiry(service, key, message = "Synthetic question")
    store = service.instance_variable_get(:@agent_store)
    target = service.send(:find_agent!, key)
    run = HQ::ManagedAgent::AgentRun.new(started_at: Time.now - 2, finished_at: Time.now - 1, status: "input_required", log_path: target.raw_log_path)
    target.runs << run
    question = { "message" => message, "fields" => [] }
    target.structured_result = { "status" => "input_required", "summary" => "Synthetic", "inquiry" => question }
    id = target.send(:inquiry_identity, question, run:)
    HQ::AgentMemory.new(target).append_inquiry_request!(question, created_at: run.finished_at, inquiry_id: id)
    agents = store.load
    agents.map! { |candidate| candidate.key == key ? target : candidate }
    store.save(agents)
    id
  end

  def check(value, message)
    raise message unless value
  end

  def conflict(service, key, id, attrs, status)
    service.answer_inquiry(key, id, attrs)
    raise "expected conflict #{status}"
  rescue HQ::RemoteService::Error => e
    check(e.status == status, "expected #{status}, got #{e.status}")
  end

  def run!
    RemoteServerTest.with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      RemoteServerTest.write_project_workspace(workspace)
      registry = RemoteServerTest.registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry:, web_push_notifier: RemoteServerTest::RecordingPushNotifier.new)
      agent = service.create_agent("project_key" => "web", "prompt" => "Synthetic only")
      key = agent.fetch(:key)
      id = inquiry(service, key)
      attrs = { "response_mode" => "answer_receipt", "intent_created_at" => Time.now.utc.iso8601(6), "expected_server_id" => agent.dig(:delegation, :server_id),
                "client_request_id" => "client-inquiry-original", "answer" => "Synthetic answer", "feedback" => "Synthetic feedback", "start" => false }
      # The response can fail after acceptance. Retry must resolve that same answer.
      projection = service.method(:agent_payload)
      service.define_singleton_method(:agent_payload) { |*args, **kwargs| raise IOError, "Synthetic lost display" }
      begin
        service.answer_inquiry(key, id, attrs)
      rescue IOError
        nil
      end
      service.define_singleton_method(:agent_payload) { |*args, **kwargs| projection.call(*args, **kwargs) }
      replay = service.answer_inquiry(key, id, attrs)
      check(replay.dig(:answer_receipt, :accepted) == true, "exact retry must return bound acceptance")
      check(replay.dig(:answer_receipt, :inquiry_id) == id, "inquiry bound")
      target = service.send(:find_agent!, key)
      check(HQ::AgentMemory.new(target).events.count { |event| event["type"] == "inquiry_response" } == 1, "one durable answer")
      newer = inquiry(service, key, "New question")
      check(service.answer_inquiry(key, id, attrs).dig(:answer_receipt, :accepted), "old acceptance survives newer question")
      check(service.send(:find_agent!, key).latest_inquiry_id == newer, "new inquiry preserved")
      conflict(service, key, id, attrs.merge("answer" => "Changed answer"), 409)
      conflict(service, key, newer, attrs, 409)
      conflict(service, key, id, attrs.merge("expected_server_id" => "another-server"), 409)
      begin
        service.answer_inquiry(key, id, attrs, actor: HQ::DelegationActor.parent_actor("some-parent"))
        raise "parent answered"
      rescue HQ::RemoteService::Error => e
        check(e.status == 403, "user-only authority")
      end
      stale = attrs.merge("client_request_id" => "client-inquiry-stale")
      rejection = service.answer_inquiry(key, id, stale)
      check(rejection.dig(:answer_rejection, :inquiry_id) == id, "stale answer has durable bound rejection")
      check(service.answer_inquiry(key, id, stale) == rejection, "rejected ID fenced")
      conflict(service, key, newer, stale, 409)
      suspended = attrs.merge("client_request_id" => "client-inquiry-suspended")
      stored = File.binread(HQ::AGENTS_FILE)
      service.dismiss_inquiry(key, newer)
      check(File.binread(HQ::AGENTS_FILE) == stored, "dismiss appends memory only and leaves the agent store untouched")
      check(service.answer_inquiry(key, newer, suspended)[:answer_rejection], "suspended inquiry rejected")
      service.restore_inquiry(key, newer)
      check(service.answer_inquiry(key, newer, suspended)[:answer_rejection], "restored inquiry cannot reuse rejected intent")
      corrected = suspended.merge("client_request_id" => "client-inquiry-corrected")
      check(service.answer_inquiry(key, newer, corrected).dig(:answer_receipt, :accepted), "corrected new intent accepted")
      conflict(service, key, newer, attrs.merge("client_request_id" => "client-inquiry-expired", "intent_created_at" => (Time.now - HQ::AgentStore::INQUIRY_RECEIPT_TTL - 1).utc.iso8601), 409)
      # Revalidate visibility under the write lock after the initial reference was read.
      race = inquiry(service, key, "Visibility race")
      original = service.method(:find_agent!)
      service.define_singleton_method(:find_agent!) do |*args|
        reference = original.call(*args)
        agents = @agent_store.load
        agents.find { |candidate| candidate.key == key }.instance_variable_set(:@role, HQ::Visibility::RETIRED_AGENT_ROLE)
        @agent_store.save(agents)
        reference
      end
      conflict(service, key, race, attrs.merge("client_request_id" => "client-hidden-race"), 404)
      service.define_singleton_method(:find_agent!) { |*args| original.call(*args) }
      agents = service.instance_variable_get(:@agent_store).load
      agents.find { |candidate| candidate.key == key }.instance_variable_set(:@role, nil)
      service.instance_variable_get(:@agent_store).save(agents)
      # A real archive between reference lookup and acceptance cannot receive an answer.
      service.define_singleton_method(:find_agent!) do |*args|
        reference = original.call(*args)
        @agent_store.archive_agent!(key)
        reference
      end
      conflict(service, key, race, attrs.merge("client_request_id" => "client-archive-race"), 404)
      puts "inquiry_receipt_test: ok"
    end
  end
end

InquiryReceiptTest.run! if $PROGRAM_NAME == __FILE__
