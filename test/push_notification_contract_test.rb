# frozen_string_literal: true

require "time"

require_relative "../lib/hq/remote_server"

module PushNotificationContractTest
  module_function

  Agent = Struct.new(:key, :status, :display_name, :last_summary, :personal, keyword_init: true) do
    def personal_assistant?
      personal
    end

    def no_action_needed?
      false
    end

    def last_run_from_prompt_queue?
      false
    end
  end

  Schedule = Struct.new(:key, :name, keyword_init: true)
  ScheduleState = Struct.new(:last_target_key, :last_finished_at, :last_error, :next_due_at, :failure_started_at,
                             keyword_init: true)
  ScheduleAgent = Struct.new(:key, :last_summary, keyword_init: true)

  def run!
    assert_agent_payload_contract
    assert_schedule_payload_contract
    assert_test_payload_contract
    puts "push_notification_contract_test: ok"
  end

  def assert_agent_payload_contract
    service = HQ::RemoteService.allocate
    expected_titles = {
      "awaiting-input" => "Input needed",
      "succeeded" => "Done",
      "failed" => "Failed",
      "stopped" => "Stopped",
      "blocked" => "Blocked"
    }

    expected_titles.each do |status, title|
      payload = service.send(:agent_push_payload, Agent.new(
                               key: "release-check", status:, display_name: "Release check",
                               last_summary: "Confirm the rollout.", personal: false
                             ), unread_count: 2).fetch(:payload)
      assert(payload == {
               title:,
               body: "Release check: Confirm the rollout. (2 unread agents)",
               tag: "hq:agents",
               renotify: status == "awaiting-input",
               silent: status != "awaiting-input",
               badge_count: 2,
               url: "/#agent/release-check"
             }, "expected concise generic #{status} notification contract")
    end

    fred_payload = service.send(:agent_push_payload, Agent.new(
                                     key: "fred-today", status: "awaiting-input", display_name: "ignored",
                                     last_summary: "Choose a release path.", personal: true
                                   ), unread_count: 1).fetch(:payload)
    assert(fred_payload == {
             title: "Input needed",
             body: "FRED: Choose a release path.",
             tag: "hq:agents",
             renotify: true,
             silent: false,
             badge_count: 1,
             url: "/#personal-assistant"
           }, "expected FRED notification to retain its identity and route in the concise contract")
  end

  def assert_schedule_payload_contract
    notifier = RecordingNotifier.new
    scheduler = HQ::Scheduler.allocate
    scheduler.instance_variable_set(:@push_notification_store, RecordingPushStore.new)
    scheduler.instance_variable_set(:@web_push_notifier, notifier)
    schedule = Schedule.new(key: "daily-memory", name: "Daily Memory")
    state = ScheduleState.new(
      last_target_key: "memory-agent", last_finished_at: Time.utc(2026, 9, 13, 12, 0, 0),
      last_error: "Archive quota reached.", next_due_at: Time.utc(2026, 9, 14, 9, 30, 0),
      failure_started_at: Time.utc(2026, 9, 13, 11, 0, 0)
    )
    agent = ScheduleAgent.new(key: "memory-agent", last_summary: "Confirm archive retention.")

    scheduler.send(:notify_schedule_failure, schedule, state, now: Time.utc(2026, 9, 13, 12, 0, 0), agent: agent)
    scheduler.send(:notify_schedule_input_required, schedule, state, agent, now: Time.utc(2026, 9, 13, 12, 0, 0))
    scheduler.send(:notify_schedule_first_success, schedule, state, agent, now: Time.utc(2026, 9, 13, 12, 0, 0))
    scheduler.send(:notify_schedule_recovery, schedule, state, agent, now: Time.utc(2026, 9, 13, 12, 0, 0))

    assert(notifier.payloads == [
      [{ title: "Failed", body: "Daily Memory: Confirm archive retention. Schedule stopped.",
         tag: "hq:schedule:daily-memory:failure", url: "/#agent/memory-agent" }, { urgency: "high", ttl: 3600 }],
      [{ title: "Input needed", body: "Daily Memory: Confirm archive retention. Schedule stopped.",
         tag: "hq:schedule:daily-memory:input-required", url: "/#agent/memory-agent" }, { urgency: "high", ttl: 3600 }],
      [{ title: "Done", body: "Daily Memory: first run succeeded. Next run: 2026-09-14 09:30.",
         tag: "hq:schedule:daily-memory:first-success", url: "/#agent/memory-agent" }, { urgency: "normal", ttl: 900 }],
      [{ title: "Recovered", body: "Daily Memory: succeeded after failure. Next run: 2026-09-14 09:30.",
         tag: "hq:schedule:daily-memory:recovery", url: "/#agent/memory-agent" }, { urgency: "normal", ttl: 900 }]
    ], "expected concise schedule notification title and body contracts")
  end

  def assert_test_payload_contract
    notifier = TestNotifier.new
    notifier.send_test!(endpoint: "https://push.example.test/test")
    assert(notifier.payload == [
      { title: "Test notification", body: "Push notifications are working.", tag: "hq:test", url: "/#setup" },
      { endpoint: "https://push.example.test/test", urgency: "normal", ttl: 120 }
    ], "expected concise test notification contract")
  end

  def assert(condition, message)
    raise message unless condition
  end

  class RecordingPushStore
    def record!(*, **)
      true
    end
  end

  class RecordingNotifier
    attr_reader :payloads

    def initialize
      @payloads = []
    end

    def send_payload!(payload, **options)
      @payloads << [payload, options]
    end
  end

  class TestNotifier < HQ::WebPushNotifier
    attr_reader :payload

    def config
      { configured: true, subscription_count: 1 }
    end

    def send_payload!(payload, **options)
      @payload = [payload, options]
    end
  end
end

PushNotificationContractTest.run! if $PROGRAM_NAME == __FILE__
