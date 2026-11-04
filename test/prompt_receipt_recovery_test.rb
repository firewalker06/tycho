# frozen_string_literal: true

require_relative "prompt_receipt_test"

module PromptReceiptRecoveryTest
  module_function

  def fixture
    RemoteServerTest.with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      RemoteServerTest.write_project_workspace(workspace)
      registry = RemoteServerTest.registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry:, web_push_notifier: RemoteServerTest::RecordingPushNotifier.new)
      agent = service.create_agent("project_key" => "web", "prompt" => "Synthetic recovery fixture")
      attrs = { "response_mode" => "receipt", "expected_server_id" => agent.dig(:delegation, :server_id),
                "client_request_id" => "client-recovery-original", "prompt" => "Synthetic reply", "start" => false }
      yield dir, registry, service, agent[:key], attrs
    end
  end

  def schedule
    fixture do |_dir, _registry, service, key, attrs|
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
      target = service.send(:find_agent_reference!, key)
      target.associate_schedule!("weekday")
      service.send(:save_agent, target)
      store = HQ::ScheduleStore.new
      stop = lambda do
        states = store.load
        state = store.state_for(states, "weekday")
        state.last_target_key = key
        state.mark_stopped!(reason: "awaiting_input")
        store.save(states)
      end
      stop.call
      # The initial service reference can predate schedule adoption. Acceptance must use current state.
      find_reference = service.method(:find_agent_reference!)
      stale_once = true
      service.define_singleton_method(:find_agent_reference!) do |*args|
        reference = find_reference.call(*args)
        if stale_once
          stale_once = false
          reference.define_singleton_method(:scheduled?) { false }
        end
        reference
      end
      first = service.submit_prompt(key, attrs)
      check(first.dig(:resumed_schedules, 0, :key) == "weekday", "original resume result")
      check(store.load.fetch("weekday").scheduled?, "original stop resumed durably")
      receipt_record = service.send(:find_agent_reference!, key).prompt_receipts.fetch("prompt-arrival:#{attrs["client_request_id"]}")
      check(receipt_record["schedule_resume_complete"] && receipt_record["schedule_resume_result"].first["key"] == "weekday", "completion and original result persist with receipt")
      check(receipt_record["schedule_resume_targets"].first["stop_id"], "original stop identity persists with acceptance")
      stop.call
      later = store.load.fetch("weekday").to_hash
      replay = service.submit_prompt(key, attrs)
      check(store.load.fetch("weekday").to_hash == later, "old replay must preserve newer stop")
      check(replay[:resumed_schedules] == first[:resumed_schedules], "completed effect result is replayed")

      scheduler = service.send(:scheduler)
      service.define_singleton_method(:scheduler) { scheduler }
      original = scheduler.method(:resume_after_user_message)
      failed = false
      scheduler.define_singleton_method(:resume_after_user_message) do |*args, **kwargs|
        unless failed
          failed = true
          raise IOError, "Synthetic interrupted resume"
        end
        original.call(*args, **kwargs)
      end
      recovery = attrs.merge("client_request_id" => "client-recovery-interrupted")
      begin
        service.submit_prompt(key, recovery)
        raise "expected interrupted effect"
      rescue IOError => e
        check(e.message == "Synthetic interrupted resume", "injected effect failure")
      end
      check(service.send(:find_agent_reference!, key).prompt_receipts.key?("prompt-arrival:client-recovery-interrupted"), "acceptance committed before effect failure")
      check(store.load.fetch("weekday").stopped_for_awaiting_input?, "failed effect leaves original stop")
      proofs = service.agent(key).fetch(:prompt_acceptances)
      check(proofs.none? { |proof| proof.dig(:receipt, :client_request_id) == recovery["client_request_id"] }, "read proof cannot skip an incomplete original schedule effect")
      result = service.submit_prompt(key, recovery)
      check(result.dig(:receipt, :replayed) && store.load.fetch("weekday").scheduled?, "retry recovers original effect")
      stop.call
      later = store.load.fetch("weekday").to_hash
      check(service.submit_prompt(key, recovery)[:resumed_schedules] == result[:resumed_schedules], "recovered result durable")
      check(store.load.fetch("weekday").to_hash == later, "recovered replay preserves later stop")

      # A crash after the schedule commit must recover its saved result, even after another stop.
      agent_store = service.instance_variable_get(:@agent_store)
      complete = agent_store.method(:complete_prompt_receipt_effect!)
      interrupted = false
      agent_store.define_singleton_method(:complete_prompt_receipt_effect!) do |*args, **kwargs|
        unless interrupted
          interrupted = true
          raise IOError, "Synthetic completion interruption"
        end
        complete.call(*args, **kwargs)
      end
      after_commit = attrs.merge("client_request_id" => "client-recovery-schedule-committed")
      begin
        service.submit_prompt(key, after_commit)
        raise "expected completion interruption"
      rescue IOError => e
        check(e.message == "Synthetic completion interruption", "injected completion failure")
      end
      check(store.load.fetch("weekday").scheduled?, "schedule effect committed before completion failure")
      stop.call
      later = store.load.fetch("weekday").to_hash
      recovered = service.submit_prompt(key, after_commit)
      check(recovered.dig(:resumed_schedules, 0, :key) == "weekday", "committed original result recovered")
      check(store.load.fetch("weekday").to_hash == later, "recovery after schedule commit preserves later stop")

      # A failed original effect is superseded if a different stop arrives before recovery.
      scheduler.define_singleton_method(:resume_after_user_message) { |*_, **_| raise IOError, "Synthetic pending effect" }
      superseded = attrs.merge("client_request_id" => "client-recovery-superseded")
      begin
        service.submit_prompt(key, superseded)
        raise "expected pending effect interruption"
      rescue IOError => e
        check(e.message == "Synthetic pending effect", "injected pending effect failure")
      end
      stop.call
      later = store.load.fetch("weekday").to_hash
      scheduler.define_singleton_method(:resume_after_user_message) { |*args, **kwargs| original.call(*args, **kwargs) }
      check(service.submit_prompt(key, superseded)[:resumed_schedules].empty?, "superseded stop is not resumed")
      current = store.load.fetch("weekday").to_hash
      check(current.reject { |name, _| name == "user_message_resumptions" } == later.reject { |name, _| name == "user_message_resumptions" }, "failed effect recovery does not touch later stop")
    end
  end

  def context
    fixture do |dir, _registry, service, key, attrs|
      raw = { "pull_request_id" => "github:example/web:123", "snapshot_id" => "old", "lines" => [] }
      rejected = service.submit_prompt(key, attrs.merge("pull_request_contexts" => [raw]))
      check(rejected.dig(:rejection, :client_request_id) == attrs["client_request_id"], "removed PR returns bound rejection")
      check(service.submit_prompt(key, attrs.merge("pull_request_contexts" => [raw])) == rejected, "rejected ID is fenced")
      check(service.send(:find_agent_reference!, key).prompt_receipts.values.first["rejected"], "rejection persists")
      corrected = attrs.merge("client_request_id" => "client-recovery-corrected")
      check(service.submit_prompt(key, corrected).dig(:receipt, :accepted), "new corrected intent accepted")
      check(service.submit_prompt(key, attrs.merge("client_request_id" => "client-recovery-next")).dig(:receipt, :accepted), "next intent accepted")

      reference = HQ::PullRequestDiff.reference_from_url("https://github.com/example/web/pull/123")
      target = service.send(:find_agent_reference!, key)
      HQ::AgentMemory.new(target).append_attachment!({ "kind" => "link", "title" => "PR", "url" => reference.url })
      service.send(:save_agent, target)
      diff_store = HQ::PullRequestDiff::Store.new(File.join(dir, "recovery-diffs.json"))
      service.instance_variable_set(:@pull_request_diff_store, diff_store)
      snapshot = { "id" => reference.id, "snapshot_id" => "current", "provider" => "github", "repository" => "example/web", "number" => 123,
                   "base_sha" => "base", "head_sha" => "head", "diff_format" => HQ::PullRequestDiff::DIFF_FORMAT,
                   "files" => [{ "path" => "sample.rb", "hunks" => [{ "lines" => [{ "kind" => "added", "new_number" => 1, "content" => "synthetic" }] }] }] }
      diff_store.save(snapshot.merge("snapshot_id" => "old"))
      raw = { "pull_request_id" => reference.id, "snapshot_id" => "old", "lines" => [{ "path" => "sample.rb", "hunk_index" => 0, "line_index" => 0 }] }
      stale = attrs.merge("client_request_id" => "client-recovery-stale", "pull_request_contexts" => [raw])
      diff_store.save(snapshot)
      check(service.submit_prompt(key, stale)[:rejection], "replaced snapshot returns bound rejection")
      diff_store.save(snapshot.merge("snapshot_id" => "old"))
      check(service.submit_prompt(key, stale)[:rejection], "old ID cannot accept after context becomes valid")
      accepted = stale.merge("client_request_id" => "client-recovery-valid")
      check(service.submit_prompt(key, accepted).dig(:receipt, :accepted), "valid context accepted")
      service.remove_agent_pull_request(key, reference.id, "catalog_revision" => service.agent_pull_request_listing(key)[:catalog_revision])
      check(service.submit_prompt(key, accepted).dig(:receipt, :replayed), "lost accepted reply replays after context removal")
    end
  end

  def check(value, message)
    raise message unless value
  end
end

if $PROGRAM_NAME == __FILE__
  axis = ENV["RECEIPT_RECOVERY_AXIS"]
  PromptReceiptRecoveryTest.schedule if axis.nil? || axis == "schedule"
  PromptReceiptRecoveryTest.context if axis.nil? || axis == "context"
  puts "prompt_receipt_recovery_test: ok"
end
