# frozen_string_literal: true

require_relative "inquiry_receipt_test"

module InquiryReceiptRecoveryTest
  extend InquiryReceiptTest
  module_function

  def fixture
    RemoteServerTest.with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      RemoteServerTest.write_project_workspace(workspace)
      registry = RemoteServerTest.registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry:, web_push_notifier: RemoteServerTest::RecordingPushNotifier.new)
      agent = service.create_agent("project_key" => "web", "prompt" => "Synthetic only")
      key = agent[:key]
      id = InquiryReceiptTest.inquiry(service, key)
      attrs = { "response_mode" => "answer_receipt", "intent_created_at" => Time.now.utc.iso8601(6),
                "expected_server_id" => agent.dig(:delegation, :server_id), "client_request_id" => "client-recovery-original", "answer" => "Synthetic reply", "start" => true }
      yield service, key, id, attrs
    end
  end

  def check(value, message)
    InquiryReceiptTest.check(value, message)
  end

  def run!
    # Interrupt after durable acceptance, before the start decision. Later inquiry/stop wins.
    %w[recover newer_inquiry stop].each do |scenario|
      fixture do |service, key, id, attrs|
        store = service.instance_variable_get(:@agent_store)
        original = store.method(:finish_inquiry_start!)
        store.define_singleton_method(:finish_inquiry_start!) { |*_, **_| raise IOError, "Synthetic before start" }
        begin
          service.answer_inquiry(key, id, attrs)
          raise "missing interruption"
        rescue IOError
          nil
        end
        check(service.send(:find_agent!, key).inquiry_receipts[attrs["client_request_id"]], "acceptance survives start interruption")
        newer = InquiryReceiptTest.inquiry(service, key, "Newer question") if scenario == "newer_inquiry"
        store.stop_agent!(key) if scenario == "stop"
        store.define_singleton_method(:finish_inquiry_start!) { |*args, **kwargs| original.call(*args, **kwargs) }
        RemoteServerTest.with_stubbed_agent_start do
          replay = service.answer_inquiry(key, id, attrs)
          check(replay.dig(:answer_receipt, :replayed), "original acceptance replayed")
          target = service.send(:find_agent!, key)
          check(target.run_count == (scenario == "recover" ? 2 : newer ? 2 : 1), "one original start or superseded decision: #{scenario} count=#{target.run_count} receipt=#{replay[:answer_receipt]}")
          check(target.latest_inquiry_id == newer, "newer inquiry unchanged") if newer
        end
      end
    end
    # Simulate the persisted pre-spawn run decision, then an interrupted return.
    fixture do |service, key, id, attrs|
      store = service.instance_variable_get(:@agent_store)
      start = HQ::ManagedAgent.instance_method(:start!)
      launches = 0
      HQ::ManagedAgent.define_method(:start!) do |delegation_stamp: nil, run_metadata: nil, before_spawn: nil, **_|
        launches += 1
        @runs << HQ::ManagedAgent::AgentRun.new(started_at: Time.now, status: "running", log_path: raw_log_path, metadata: run_metadata)
        before_spawn.call(@runs.last)
        raise IOError, "Synthetic after start decision"
      end
      begin
        service.answer_inquiry(key, id, attrs)
      rescue IOError
        nil
      end
      replay = service.answer_inquiry(key, id, attrs)
      check(launches == 1 && replay.dig(:answer_receipt, :start_result) == "attempted", "persisted start decision is never dispatched twice")
    ensure
      HQ::ManagedAgent.define_method(:start!, start) if start
    end

    %w[before_effect after_effect newer_stop newer_inquiry].each do |scenario|
      fixture do |service, key, id, attrs|
        attrs["start"] = false
        File.write(HQ::SCHEDULES_FILE, <<~YAML)
          schedules:
            - key: weekday
              cron: "0 9 * * 1-5"
              target:
                type: agent
                project_key: web
                agent_key: #{key}
                message: "Synthetic schedule"
        YAML
        target = service.send(:find_agent!, key)
        target.associate_schedule!("weekday")
        service.send(:save_agent, target)
        schedules = HQ::ScheduleStore.new
        stop = lambda do
          states = schedules.load
          state = schedules.state_for(states, "weekday")
          state.last_target_key = key
          state.mark_stopped!(reason: "awaiting_input")
          schedules.save(states)
        end
        stop.call
        scheduler = service.send(:scheduler)
        service.define_singleton_method(:scheduler) { scheduler }
        resume = scheduler.method(:resume_after_user_message)
        scheduler.define_singleton_method(:resume_after_user_message) do |*args, **kwargs|
          resume.call(*args, **kwargs) if scenario == "after_effect"
          raise IOError, "Synthetic schedule interruption"
        end
        begin
          service.answer_inquiry(key, id, attrs)
          raise "missing interruption"
        rescue IOError
          nil
        end
        stop.call if %w[after_effect newer_stop].include?(scenario)
        InquiryReceiptTest.inquiry(service, key, "New question") if scenario == "newer_inquiry"
        later = schedules.load.fetch("weekday").to_hash
        scheduler.define_singleton_method(:resume_after_user_message) { |*args, **kwargs| resume.call(*args, **kwargs) }
        replay = service.answer_inquiry(key, id, attrs)
        state = schedules.load.fetch("weekday")
        check(replay.dig(:answer_receipt, :accepted), "effect interruption retains acceptance")
        if scenario == "before_effect"
          check(state.scheduled?, "original schedule effect recovered")
        else
          check(state.stopped_for_awaiting_input? && state.stop_id == later["stop_id"], "new stop/inquiry preserved")
        end
        check(replay[:resumed_schedules].any? == %w[before_effect after_effect].include?(scenario), "original effect result recovered")
        check(service.answer_inquiry(key, id, attrs)[:resumed_schedules] == replay[:resumed_schedules], "effect replay result is durable")
      end
    end
    puts "inquiry_receipt_recovery_test: ok"
  end
end

InquiryReceiptRecoveryTest.run! if $PROGRAM_NAME == __FILE__
