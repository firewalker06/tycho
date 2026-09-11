# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "socket"
require "stringio"
require "tmpdir"
require "thread"
require "timeout"
require "yaml"

# Bind every HQ path before loading the application. These tests create and
# roll over a real Personal Assistant object; the process must never inherit
# the operator's runtime, even when a caller omitted the usual test env.
PHASE2_TEST_HOME = Dir.mktmpdir("tycho-phase2-home")
PHASE2_TEST_TMPDIR = File.join(PHASE2_TEST_HOME, "tmp")
PHASE2_TEST_FIXTURES = File.join(PHASE2_TEST_HOME, "fixtures")
FileUtils.mkdir_p([PHASE2_TEST_TMPDIR, PHASE2_TEST_FIXTURES])
%w[
  TYCHO_CONFIG_PATH TYCHO_SYSTEM_PROMPTS_PATH TYCHO_RESPONSE_STYLE_PATH
  TYCHO_CONFIG_DIR
  TYCHO_LOGS_ROOT TYCHO_SCHEDULES_PATH TYCHO_SCHEDULES_ROOT
  TYCHO_SCHEDULES_STATE_PATH TYCHO_SCHEDULER_DAEMON_PATH
].each { |name| ENV.delete(name) }
ENV["TYCHO_HOME"] = PHASE2_TEST_HOME
ENV["TMPDIR"] = PHASE2_TEST_TMPDIR
ENV["TMP"] = PHASE2_TEST_TMPDIR
ENV["TEMP"] = PHASE2_TEST_TMPDIR
ENV["TYCHO_CODEX_BIN"] = File.join(PHASE2_TEST_HOME, "missing-codex")

require_relative "../lib/hq/remote_server"

class Phase2BarrierAgentStore < HQ::AgentStore
  def initialize(projects, barrier:, release:)
    super(projects)
    @barrier = barrier
    @release = release
    @signaled = false
  end

  def mutate(dispatch_prompt_queues: true)
    super do |agents, events|
      if Thread.current[:phase2_worker_barrier] && !@signaled
        @signaled = true
        @barrier << true
        @release.pop
      end
      yield agents, events
    end
  end
end

class Phase2BarrierRegistry < HQ::Registry
  def initialize(path:, system_prompts_path:, barrier:, release:)
    @barrier = barrier
    @release = release
    @signaled = false
    super(path:, system_prompts_path:)
  end

  private

  def write_yaml(path, data)
    if path == @path && Thread.current[:phase2_worker_barrier] && !@signaled
      @signaled = true
      @barrier << true
      @release.pop
    end
    super
  end
end

class Phase2CountingRemoteService < HQ::RemoteService
  attr_reader :bundle_calls

  def initialize(**kwargs)
    @bundle_calls = 0
    super
  end

  def personal_assistant_bundle
    @bundle_calls += 1
    super
  end
end

class Phase2WorkerSpy
  attr_reader :actions

  def initialize(actions, on_start: nil)
    @actions = actions
    @on_start = on_start
    @started = false
  end

  def start!
    @started = true
    @on_start&.call
    true
  end

  alias start start!

  def started?
    @started
  end

  def shutdown
    true
  end

  def wake!
    true
  end
end

class PersonalAssistantPhase2Test
  def self.run
    assert_internal_isolation
    assert_background_confirmation_is_durable_and_nonblocking
    assert_background_http_status_stays_responsive
    assert_frozen_preview_reconciles_stale_defaults
    assert_frozen_effective_settings_reach_executor
    assert_frozen_create_agent_fields_and_nullable_patch
    assert_unavailable_preview_is_rejected
    assert_schedule_precondition_ignores_derived_next_run
    assert_daemon_starts_worker_after_daemonization
    assert_personal_assistant_snapshot_coalesces_bundle_builds
    assert_timezone_cache_reuses_until_boundary
    assert_current_work_honors_live_visibility
    assert_verification_never_claims_observed_state
    assert_worker_create_preserves_foreground_create
    assert_worker_create_preserves_foreground_update
    assert_start_preserves_concurrent_create
    assert_delegated_create_failure_is_atomic
    assert_worker_project_create_preserves_foreground_update
    assert_worker_project_create_preserves_foreground_settings
    assert_history_exposes_expired_actions_read_only
    assert_history_preserves_truthful_accepted_states
    puts "personal_assistant_phase2_test: OK"
  end

  def self.assert_internal_isolation
    paths = [
      HQ::Registry::DEFAULT_PATH, HQ::USER_CONFIG_DIR, HQ::USER_SCHEDULES_DIR, HQ::USER_LOGS_DIR,
      HQ::AGENTS_FILE, HQ::PERSONAL_ASSISTANT_DIR, HQ::SCHEDULES_FILE, HQ::SCHEDULES_STATE_FILE,
      HQ::AGENT_LOGS_DIR
    ]
    root = "#{File.expand_path(PHASE2_TEST_HOME)}/"
    paths.each do |path|
      expanded = File.expand_path(path)
      assert(expanded.start_with?(root), "expected test runtime path to stay under #{PHASE2_TEST_HOME}: #{expanded}")
    end
    assert(ENV["TYCHO_CONFIG_DIR"].to_s.empty?, "expected TYCHO_CONFIG_DIR to be cleared before HQ load")
    assert(ENV["TYCHO_CODEX_BIN"] == File.join(PHASE2_TEST_HOME, "missing-codex"),
           "expected fixture tests to use a missing Codex executable")
  end

  def self.assert_background_confirmation_is_durable_and_nonblocking
    with_fixture do |fixture|
      started = Queue.new
      release = Queue.new
      service, server, actions, worker = fixture.build(
        executor: ->(*) { started << true; release.pop; { "ok" => true } }
      )
      fixture.open!(service, server)
      target = service.create_agent("project_key" => "web", "name" => "Blocked action target", "prompt" => "Probe")
      proposal = fixture.register(actions, "start_agent", { "agent_key" => target[:key] }, "start-1")
      preview = fixture.route(server, service, "GET", "/personal-assistant/actions/#{proposal["id"]}/preflight", {})
      token = preview.dig(:body, :preflight, "precondition_token")
      confirmed = fixture.route(server, service, "POST", "/personal-assistant/actions/#{proposal["id"]}/confirm", {
        "confirmed" => true, "proposal_digest" => proposal["digest"], "precondition_token" => token
      })
      assert(confirmed[:status] == 202 && confirmed.dig(:body, "accepted") && confirmed.dig(:body, "queued"),
             "expected background confirmation to return an immediate queued receipt")

      worker.start!
      started.pop
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status = fixture.route(server, service, "GET", "/personal-assistant", {})
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      assert(status[:status] == 200 && elapsed < 0.5, "expected status GET to remain responsive during a blocked action (status=#{status[:status].inspect}, elapsed=#{elapsed.round(3)})")

      replay = fixture.route(server, service, "POST", "/personal-assistant/actions/#{proposal["id"]}/confirm", {
        "confirmed" => true, "proposal_digest" => proposal["digest"], "precondition_token" => token
      })
      assert(replay[:status] == 202 && replay.dig(:body, "accepted") && replay.dig(:body, "replayed"),
             "expected duplicate confirmation to replay without waiting for the blocked effect")
      release << true
      wait_until { actions.proposal(proposal["id"])["state"] == "executed" }
      worker.shutdown
    end
  end

  def self.assert_frozen_preview_reconciles_stale_defaults
    with_fixture do |fixture|
      executed = []
      service, server, actions, worker = fixture.build(
        executor: ->(*) { executed << true; { "ok" => true } }
      )
      fixture.open!(service, server)
      proposal = fixture.register(actions, "create_agent", {
        "project_key" => "web", "name" => "Prepared", "prompt" => "Prepare", "agent" => nil, "model" => nil,
        "reasoning_effort" => nil
      }, "create-agent-1")
      preview = fixture.route(server, service, "GET", "/personal-assistant/actions/#{proposal["id"]}/preflight", {})
      original_token = preview.dig(:body, :preflight, "precondition_token")
      original_model = preview.dig(:body, :preflight, "details", "model")
      fixture.registry.update_project!("web", "model" => "changed-after-preview")
      service.send(:reload_projects_from_registry!)
      confirmed = fixture.route(server, service, "POST", "/personal-assistant/actions/#{proposal["id"]}/confirm", {
        "confirmed" => true, "proposal_digest" => proposal["digest"], "precondition_token" => original_token
      })
      assert(confirmed[:status] == 409 && confirmed.dig(:body, :details, "code") == "precondition_changed",
             "expected a changed inherited default to reject confirmation")

      second = fixture.register(actions, "create_agent", {
        "project_key" => "web", "name" => "Prepared Again", "prompt" => "Prepare", "agent" => nil, "model" => nil,
        "reasoning_effort" => nil
      }, "create-agent-2")
      fresh = fixture.route(server, service, "GET", "/personal-assistant/actions/#{second["id"]}/preflight", {})
      fresh_token = fresh.dig(:body, :preflight, "precondition_token")
      fresh_model = fresh.dig(:body, :preflight, "details", "model")
      accepted = fixture.route(server, service, "POST", "/personal-assistant/actions/#{second["id"]}/confirm", {
        "confirmed" => true, "proposal_digest" => second["digest"], "precondition_token" => fresh_token
      })
      assert(accepted[:status] == 202, "expected the fresh preview to be accepted")
      fixture.registry.update_project!("web", "model" => "changed-before-effect")
      service.send(:reload_projects_from_registry!)
      frozen = fixture.route(server, service, "GET", "/personal-assistant/actions/#{second["id"]}/preflight", {})
      assert(frozen.dig(:body, :preflight, "precondition_token") == fresh_token &&
             frozen.dig(:body, :preflight, "details", "model") == fresh_model,
             "expected accepted preview and token to remain frozen")
      worker.start!
      wait_until { actions.proposal(second["id"])["state"] == "failed" }
      failed = actions.proposal(second["id"])
      assert(failed["code"] == "precondition_changed" && executed.empty?,
             "expected worker precondition failure to avoid the external effect")
      worker.shutdown
    end
  end

  def self.assert_background_http_status_stays_responsive
    with_fixture do |fixture|
      started = Queue.new
      release = Queue.new
      service, _direct_server, actions, worker = fixture.build(
        executor: ->(*) { started << true; release.pop; { "ok" => true } }
      )
      fixture.open!(service, _direct_server)
      target = service.create_agent(
        "project_key" => "web", "name" => "HTTP Target", "prompt" => "HTTP target prompt", "agent" => "codex"
      )
      assert(service.instance_variable_get(:@personal_assistant).status[:state] == "active",
             "expected fixture FRED session to remain active before HTTP server startup")
      proposal = fixture.register(actions, "start_agent", { "agent_key" => target[:key] }, "http-start-1")
      port = fixture.free_port
      service.instance_variable_set(:@server_url, "http://127.0.0.1:#{port}")
      server = HQ::RemoteServer.new(
        host: "127.0.0.1", port:, personal_assistant_action_worker: worker,
        registry: fixture.registry,
        clock: -> { Time.utc(2026, 9, 9, 12) }
      )
      thread = Thread.new { server.start }
      begin
        fixture.wait_for_http!(port)
        preflight_status, preflight = fixture.http_request(port, "GET", "/personal-assistant/actions/#{proposal["id"]}/preflight")
        assert(preflight_status == 200, "expected HTTP preflight to succeed: #{preflight.inspect}")
        token = preflight.dig("preflight", "precondition_token")
        confirm_status, confirmed = fixture.http_request(
          port, "POST", "/personal-assistant/actions/#{proposal["id"]}/confirm",
          "confirmed" => true, "proposal_digest" => proposal["digest"], "precondition_token" => token
        )
        assert(confirm_status == 202 && confirmed["queued"], "expected HTTP confirmation to queue")
        take_barrier(started)
        began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        status_code, _status = fixture.http_request(port, "GET", "/personal-assistant")
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - began
        assert(status_code == 200 && elapsed < 0.5,
               "expected a concurrent real HTTP GET to remain responsive (status=#{status_code}, elapsed=#{elapsed.round(3)})")
      ensure
        release << true
        server.shutdown
        thread.join(2)
        thread.kill if thread.alive?
      end
    end
  end

  def self.assert_frozen_effective_settings_reach_executor
    with_fixture do |fixture|
      service = nil
      observed_arguments = Queue.new
      executor = lambda do |type, arguments|
        fixture.registry.update_project!("web", "model" => "changed-between-guard-effect")
        service.send(:reload_projects_from_registry!)
        observed_arguments << arguments
        service.execute_personal_assistant_action(type, arguments)
      end
      service, server, actions, worker = fixture.build(executor:)
      fixture.open!(service, server)
      proposal = fixture.register(actions, "create_agent", {
        "project_key" => "web", "name" => "Frozen Settings", "prompt" => "Use the displayed model",
        "agent" => nil, "model" => nil, "reasoning_effort" => nil
      }, "frozen-settings-1")
      preview = fixture.route(server, service, "GET", "/personal-assistant/actions/#{proposal["id"]}/preflight", {})
      preflight = preview.dig(:body, :preflight)
      confirmed = fixture.route(server, service, "POST", "/personal-assistant/actions/#{proposal["id"]}/confirm", {
        "confirmed" => true, "proposal_digest" => proposal["digest"],
        "precondition_token" => preflight["precondition_token"]
      })
      assert(confirmed[:status] == 202, "expected frozen settings confirmation to queue")

      worker.start!
      wait_until { actions.proposal(proposal["id"])["state"] == "executed" }
      executed_arguments = observed_arguments.pop
      expected_model = preflight.dig("details", "model")
      assert(executed_arguments["model"] == expected_model && executed_arguments["reasoning_effort"] == preflight.dig("details", "reasoning_effort"),
             "expected the executor to receive the frozen effective settings")
      agents = HQ::AgentStore.new(service.instance_variable_get(:@projects)).load
      created = agents.find { |agent| agent.name == "Frozen Settings" }
      assert(created&.model == expected_model, "expected the effect to use the frozen model after a default change")
      worker.shutdown
    end
  end

  def self.assert_frozen_create_agent_fields_and_nullable_patch
    with_fixture do |fixture|
      fixture.registry.update_project!("web", "model" => nil)
      service = nil
      service, server, actions, worker = fixture.build(
        executor: lambda do |type, arguments|
          fixture.registry.update_project!("web", "model" => "changed-after-guard")
          service.send(:reload_projects_from_registry!)
          service.execute_personal_assistant_action(type, arguments)
        end
      )
      fixture.open!(service, server)
      proposal = fixture.register(actions, "create_agent", {
        "project_key" => "web", "name" => "Frozen nil", "prompt" => "Preserve nil", "agent" => nil,
        "model" => nil, "reasoning_effort" => nil
      }, "frozen-nil-1")
      preflight = fixture.route(server, service, "GET", "/personal-assistant/actions/#{proposal["id"]}/preflight", {}).dig(:body, :preflight)
      original_workspace = preflight.dig("details", "project", "path")
      confirmed = fixture.route(server, service, "POST", "/personal-assistant/actions/#{proposal["id"]}/confirm", {
        "confirmed" => true, "proposal_digest" => proposal["digest"], "precondition_token" => preflight["precondition_token"]
      })
      assert(confirmed[:status] == 202, "expected nil effective settings confirmation to queue")
      worker.start!
      wait_until { actions.proposal(proposal["id"])["state"] == "executed" }
      created = HQ::AgentStore.new(service.instance_variable_get(:@projects)).load.find { |agent| agent.name == "Frozen nil" }
      assert(created && created.model.nil? && created.workspace == original_workspace,
             "expected a frozen nil model and workspace to survive changed project defaults")
      worker.shutdown
    end

    with_fixture do |fixture|
      service = nil
      service, server, actions, worker = fixture.build(
        executor: lambda do |type, arguments|
          fixture.registry.update_project!("web", "model" => "concurrent-model")
          service.send(:reload_projects_from_registry!)
          service.execute_personal_assistant_action(type, arguments)
        end
      )
      fixture.open!(service, server)
      proposal = fixture.register(actions, "update_project", {
        "project_key" => "web", "name" => "Renamed only", "group" => nil, "agent" => nil,
        "model" => nil, "reasoning_effort" => nil
      }, "nullable-patch-1")
      preflight = fixture.route(server, service, "GET", "/personal-assistant/actions/#{proposal["id"]}/preflight", {}).dig(:body, :preflight)
      confirmed = fixture.route(server, service, "POST", "/personal-assistant/actions/#{proposal["id"]}/confirm", {
        "confirmed" => true, "proposal_digest" => proposal["digest"], "precondition_token" => preflight["precondition_token"]
      })
      assert(confirmed[:status] == 202, "expected a nullable project patch confirmation to queue")
      worker.start!
      wait_until { actions.proposal(proposal["id"])["state"] == "executed" }
      project = service.registry.projects.find { |candidate| candidate.key == "web" }
      assert(project.name == "Renamed only" && project.model == "concurrent-model",
             "expected a name-only patch not to overwrite a concurrent model change")
      worker.shutdown
    end
  end

  def self.assert_unavailable_preview_is_rejected
    with_fixture do |fixture|
      executed = false
      service, server, actions, worker = fixture.build(executor: ->(*) { executed = true })
      fixture.open!(service, server)
      proposal = fixture.register(actions, "start_agent", { "agent_key" => "missing-agent" }, "unavailable-preview-1")
      preflight = fixture.route(server, service, "GET", "/personal-assistant/actions/#{proposal["id"]}/preflight", {}).dig(:body, :preflight)
      assert(preflight["prepared"] == false && preflight.dig("details", "available") == false,
             "expected a missing target to produce an unavailable preview")
      response = fixture.route(server, service, "POST", "/personal-assistant/actions/#{proposal["id"]}/confirm", {
        "confirmed" => true, "proposal_digest" => proposal["digest"], "precondition_token" => preflight["precondition_token"]
      })
      assert(response[:status] == 409 && response.dig(:body, :details, "code") == "preview_unavailable",
             "expected unavailable previews to be rejected before queue acceptance")
      assert(actions.proposal(proposal["id"])["state"] == "awaiting_confirmation" && !executed,
             "expected an unavailable preview to leave no queued job or effect")
      worker.shutdown
    end
  end

  def self.assert_daemon_starts_worker_after_daemonization
    with_fixture do |fixture|
      actions = HQ::PersonalAssistantActions.new(
        path: File.join(fixture.dir, "daemon-proposals.json"), auto_execute: false,
        executor: ->(*) { {} }
      )
      worker = Phase2WorkerSpy.new(actions)
      server = nil
      observed = Queue.new
      daemonizer = lambda do |_nochdir, _noclose|
        observed << worker.started?
        server.shutdown
      end
      server = HQ::RemoteServer.new(
        host: "127.0.0.1", port: fixture.free_port, daemonize_after_startup: true,
        daemonizer:, daemon_log_path: File.join(fixture.dir, "remote-daemon.log"),
        output: StringIO.new, personal_assistant_action_worker: worker
      )
      thread = Thread.new { server.start }
      thread.join(2)
      assert(!thread.alive? && observed.pop == false && worker.started?,
             "expected the FRED worker to start only in the post-daemon serving process")
    end
  end

  def self.assert_schedule_precondition_ignores_derived_next_run
    with_fixture do |fixture|
      fixture.write_schedules!
      service, server, actions, = fixture.build(executor: ->(*) { { "ok" => true } })
      fixture.open!(service, server)
      proposal = fixture.register(actions, "pause_schedule", { "schedule_key" => "daily" }, "pause-1")
      first = fixture.route(server, service, "GET", "/personal-assistant/actions/#{proposal["id"]}/preflight", {})
      first_preflight = first.dig(:body, :preflight)
      first_token = first_preflight["precondition_token"]
      assert(first_preflight.dig("details", "enabled_before") == true &&
             first_preflight.dig("details", "enabled_after") == false &&
             first_preflight.dig("details", "operation") == "pause",
             "expected pause preflight to expose typed enabled transitions")
      fixture.advance_clock!(60)
      second = fixture.route(server, service, "GET", "/personal-assistant/actions/#{proposal["id"]}/preflight", {})
      assert(second.dig(:body, :preflight, "precondition_token") == first_token,
             "expected clock-only next-run changes not to invalidate schedule intent")
    end
  end

  def self.assert_personal_assistant_snapshot_coalesces_bundle_builds
    with_fixture do |fixture|
      service, server, _actions, = fixture.build(
        executor: ->(*) { { "ok" => true } }, service_class: Phase2CountingRemoteService
      )
      fixture.open!(service, server)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      first = fixture.route(server, service, "GET", "/personal-assistant", {})
      actions = fixture.route(server, service, "GET", "/personal-assistant/actions", {})
      current_work = fixture.route(server, service, "GET", "/personal-assistant/current-work", {})
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)
      assert(first[:status] == 200 && actions[:status] == 200 && current_work[:status] == 200,
             "expected shared personal assistant snapshot routes to succeed")
      assert(service.bundle_calls == 1, "expected consecutive status/actions/current-work reads to share one bundle build")
      puts "personal_assistant_snapshot: #{elapsed_ms}ms across 3 reads, 1 bundle build"
    end
  end

  def self.assert_timezone_cache_reuses_until_boundary
    cache = HQ::PersonalAssistantLifecycle::TimezoneSnapshotCache.new
    original_tz = ENV["TZ"]
    cases = [
      ["spring", Time.utc(2026, 3, 8, 5), "America/New_York", "2026-03-08", "2026-03-09T04:00:00Z"],
      ["fall", Time.utc(2026, 11, 1, 4), "America/New_York", "2026-11-01", "2026-11-02T05:00:00Z"],
      ["backward", Time.utc(2026, 3, 8, 6), "America/New_York", "2026-03-08", "2026-03-09T04:00:00Z"],
      ["tokyo", Time.utc(2026, 9, 9, 12), "Asia/Tokyo", "2026-09-09", "2026-09-09T15:00:00Z"],
      ["utc", Time.utc(2026, 9, 9, 12), "UTC", "2026-09-09", "2026-09-10T00:00:00Z"]
    ]
    cases.each do |name, now, timezone, date, boundary|
      value = cache.fetch(now, timezone)
      assert(value[:date] == date && value[:next_rollover_at] == boundary && value[:next_at] > now.to_f,
             "expected #{name} timezone snapshot to preserve its date and next boundary")
    end

    before_boundary = cache.fetch(Time.utc(2026, 9, 9, 23, 59, 59), "UTC")
    at_boundary = cache.fetch(Time.utc(2026, 9, 10), "UTC")
    assert(before_boundary[:date] == "2026-09-09" && before_boundary[:next_rollover_at] == "2026-09-10T00:00:00Z",
           "expected the exact-boundary probe to start with the prior UTC day")
    assert(at_boundary[:date] == "2026-09-10" && at_boundary[:next_rollover_at] == "2026-09-11T00:00:00Z",
           "expected timezone cache to refresh at the exact derived boundary")
    assert(ENV["TZ"] == original_tz, "expected timezone calculation not to change process TZ")
  end

  def self.assert_current_work_honors_live_visibility
    with_fixture do |fixture|
      service, server, actions, = fixture.build(executor: ->(*) { { "ok" => true } })
      fixture.open!(service, server)
      fixture.write_schedules!
      proposal = fixture.register(actions, "create_project", {
        "key" => "tracked-project", "name" => "Tracked Project", "path" => fixture.dir,
        "group" => nil, "agent" => nil, "model" => nil, "reasoning_effort" => nil
      }, "tracked-project-1")
      schedule_proposal = fixture.register(actions, "create_schedule", {
        "key" => "daily", "name" => "Daily", "cron" => "0 9 * * *", "timezone" => "UTC",
        "project_key" => "web", "agent_name" => "Daily agent", "message" => "Review.", "system_message" => nil
      }, "tracked-schedule-1")
      actions.track!(proposal["id"], "kind" => "project", "key" => "web", "name" => "Web", "proposal_id" => proposal["id"])
      actions.track!(schedule_proposal["id"], "kind" => "schedule", "key" => "daily", "name" => "Daily", "proposal_id" => schedule_proposal["id"])
      visible = fixture.route(server, service, "GET", "/personal-assistant/current-work", {})
      assert(visible[:status] == 200 && visible.dig(:body, :tracked, :projects).any? { |item| item[:key] == "web" },
             "expected a visible tracked project in current work")
      assert(visible.dig(:body, :tracked, :schedules).any? { |item| item[:key] == "daily" },
             "expected a schedule attached to a visible project in current work")
      fixture.registry.update_project_hidden!("web", true)
      service.send(:reload_projects_from_registry!)
      hidden = fixture.route(server, service, "GET", "/personal-assistant/current-work", {})
      assert(hidden[:status] == 200 && hidden.dig(:body, :tracked, :projects).none? { |item| item[:key] == "web" },
             "expected hidden tracked resources to disappear from current work")
      assert(hidden.dig(:body, :tracked, :schedules).none? { |item| item[:key] == "daily" },
             "expected schedules attached to hidden projects to disappear from current work")
    end
  end

  def self.assert_verification_never_claims_observed_state
    with_fixture do |fixture|
      service, server, actions, = fixture.build(executor: ->(*) { raise "uncertain effect" })
      fixture.open!(service, server)
      agent_args = {
        "project_key" => "web", "name" => "Unrelated Matching Agent", "prompt" => "Same prompt",
        "agent" => "codex", "model" => "inherited-model", "reasoning_effort" => "low"
      }
      agent_proposal = fixture.register(actions, "create_agent", agent_args, "verify-agent-1")
      preview = fixture.route(server, service, "GET", "/personal-assistant/actions/#{agent_proposal["id"]}/preflight", {})
      service.create_agent(agent_args)
      verification = service.send(:verify_personal_assistant_action_execution, "create_agent", agent_args,
                                   agent_proposal.merge("preflight" => preview.dig(:body, :preflight)))
      assert(verification["completed"] != true && verification["no_effect"] != true,
             "expected an unrelated matching agent to remain outcome_unknown")

      update_args = {
        "project_key" => "web", "name" => nil, "group" => nil, "agent" => nil,
        "model" => "inherited-model", "reasoning_effort" => nil
      }
      update_proposal = fixture.register(actions, "update_project", update_args, "verify-settings-1")
      update_preview = fixture.route(server, service, "GET", "/personal-assistant/actions/#{update_proposal["id"]}/preflight", {})
      settings_verification = service.send(:verify_personal_assistant_action_execution, "update_project", update_args,
                                           update_proposal.merge("preflight" => update_preview.dig(:body, :preflight)))
      assert(settings_verification["completed"] != true && settings_verification["no_effect"] != true,
             "expected matching settings without a committed receipt to remain outcome_unknown")

      running_target = Object.new
      running_target.define_singleton_method(:running?) { true }
      service.define_singleton_method(:find_agent!) { |_key| running_target }
      running_verification = service.send(
        :verify_personal_assistant_action_execution, "start_agent", { "agent_key" => "independently-running" },
        { "id" => "verify-running-1" }
      )
      assert(running_verification["completed"] != true && running_verification["no_effect"] != true,
             "expected an independently running target to remain outcome_unknown")
    end
  end

  def self.assert_worker_create_preserves_foreground_create
    with_fixture do |fixture|
      barrier = Queue.new
      release = Queue.new
      service = nil
      executor = lambda do |type, arguments|
        Thread.current[:phase2_worker_barrier] = true
        service.execute_personal_assistant_action(type, arguments)
      end
      service, server, actions, worker = fixture.build(executor:)
      fixture.open!(service, server)
      store = replace_agent_store(service, barrier:, release:)
      proposal = fixture.register(actions, "create_agent", {
        "project_key" => "web", "name" => "Worker Created", "prompt" => "Worker prompt",
        "agent" => nil, "model" => nil, "reasoning_effort" => nil
      }, "worker-create-1")
      actions.enqueue!(proposal["id"], confirmed: true, digest: proposal["digest"])

      foreground = nil
      released = false
      begin
        worker.start!
        take_barrier(barrier)
        foreground = Thread.new do
          service.create_agent("project_key" => "web", "name" => "Foreground Created", "prompt" => "Foreground prompt", "agent" => "codex")
        end
        sleep 0.05
        assert(foreground.alive?, "expected foreground create to wait for the worker store transaction")
        release << true
        released = true
        foreground.value
        wait_until { actions.proposal(proposal["id"])["state"] == "executed" }
        names = store.load.map(&:name)
        assert(names.include?("Worker Created") && names.include?("Foreground Created"),
               "expected worker and foreground creates to survive the same store race")
      ensure
        release << true unless released
        foreground&.join(2)
        worker.shutdown
      end
    end
  end

  def self.assert_worker_create_preserves_foreground_update
    with_fixture do |fixture|
      service = nil
      service, server, actions, worker = fixture.build(
        executor: lambda do |type, arguments|
          Thread.current[:phase2_worker_barrier] = true
          service.execute_personal_assistant_action(type, arguments)
        end
      )
      fixture.open!(service, server)
      base = service.create_agent("project_key" => "web", "name" => "Base Agent", "prompt" => "Base prompt", "agent" => "codex")
      barrier = Queue.new
      release = Queue.new
      store = replace_agent_store(service, barrier:, release:)
      proposal = fixture.register(actions, "create_agent", {
        "project_key" => "web", "name" => "Worker Alongside Update", "prompt" => "Worker prompt",
        "agent" => nil, "model" => nil, "reasoning_effort" => nil
      }, "worker-update-1")
      actions.enqueue!(proposal["id"], confirmed: true, digest: proposal["digest"])

      foreground = nil
      released = false
      begin
        worker.start!
        take_barrier(barrier)
        foreground = Thread.new { service.update_agent(base[:key], "name" => "Foreground Updated") }
        sleep 0.05
        assert(foreground.alive?, "expected foreground update to wait for the worker store transaction")
        release << true
        released = true
        foreground.value
        wait_until { actions.proposal(proposal["id"])["state"] == "executed" }
        agents = store.load
        assert(agents.any? { |agent| agent.name == "Foreground Updated" } &&
               agents.any? { |agent| agent.name == "Worker Alongside Update" },
               "expected worker create and foreground update to survive the same store race")
      ensure
        release << true unless released
        foreground&.join(2)
        worker.shutdown
      end
    end
  end

  def self.assert_start_preserves_concurrent_create
    with_fixture do |fixture|
      service, server, actions, worker = fixture.build(executor: ->(*) { {} })
      fixture.open!(service, server)
      target = service.create_agent("project_key" => "web", "name" => "Start target", "prompt" => "Probe")
      other = HQ::RemoteService.new(registry: fixture.registry)
      other.create_agent("project_key" => "web", "name" => "Concurrent create", "prompt" => "Must survive")
      service.define_singleton_method(:save_agent) { raise "start must not save a stale whole agent list" }
      store = service.instance_variable_get(:@agent_store)
      store.define_singleton_method(:start_agent!) { |key, **_options| load.find { |agent| agent.key == key } }
      service.start_agent(target[:key])
      assert(store.load.any? { |agent| agent.name == "Concurrent create" },
             "expected start to avoid a stale whole-store save")
      worker.shutdown
    end
  end

  def self.assert_delegated_create_failure_is_atomic
    with_fixture do |fixture|
      service, server, actions, worker = fixture.build(executor: ->(*) { {} })
      fixture.open!(service, server)
      parent = service.create_agent("project_key" => "web", "name" => "Delegation parent", "prompt" => "Parent")
      coordinator = Class.new(HQ::DelegationCoordinator) do
        def attach!(**)
          raise HQ::DelegationStore::Error, "simulated delegation failure"
        end
      end.new
      store = HQ::AgentStore.new(service.instance_variable_get(:@projects), delegation_coordinator: coordinator)
      service.instance_variable_set(:@agent_store, store)
      begin
        service.create_agent(
          "project_key" => "web", "name" => "Orphan must not remain", "prompt" => "Child",
          "parent_agent_key" => parent[:key]
        )
        raise "expected delegated creation to fail"
      rescue HQ::RemoteServer::Error => e
        assert([403, 409].include?(e.status), "expected delegated creation failure to be reported as a guarded error")
      end
      assert(store.load.none? { |agent| agent.name == "Orphan must not remain" },
             "expected delegated creation failure to roll back the child record")
      worker.shutdown
    end
  end

  def self.assert_history_exposes_expired_actions_read_only
    with_fixture do |fixture|
      service, server, actions, worker = fixture.build(executor: ->(*) { {} })
      fixture.open!(service, server)
      pending = fixture.register(actions, "start_agent", { "agent_key" => "missing-agent" }, "history-pending-1")
      uncertain = fixture.register(actions, "start_agent", { "agent_key" => "uncertain-agent" }, "history-unknown-1")
      actions.enqueue!(uncertain["id"], confirmed: true, digest: uncertain["digest"])
      state = HQ::FileStore.read_json(actions.path, fallback: {})
      stored_uncertain = state.fetch("proposals").find { |proposal| proposal["id"] == uncertain["id"] }
      stored_uncertain.merge!(
        "state" => "failed",
        "code" => "outcome_unknown",
        "recovery" => {
          "state" => "outcome_unknown", "action" => "verify", "reason" => "The effect outcome is not provable."
        }
      )
      HQ::FileStore.write_json(actions.path, state)
      old_key = service.personal_assistant[:active_key]
      restarted = fixture.route(server, service, "POST", "/personal-assistant/restart", { "confirmed" => true })
      assert(restarted[:status] == 200 && restarted.dig(:body, :personal_assistant, :active_key) != old_key,
             "expected restart to create a new FRED generation")
      history = fixture.route(server, service, "GET", "/personal-assistant/history", {})
      history_id = history.dig(:body, :history, 0, "id")
      entry = fixture.route(server, service, "GET", "/personal-assistant/history/#{history_id}", {})
      expired = entry.dig(:body, :history, "expired_actions")&.find { |action| action["id"] == pending["id"] }
      assert(expired && expired["state"] == "expired" && expired["read_only"] == true && expired["historical_state"] == "awaiting_confirmation",
             "expected a rolled-over pending proposal to become a real expired read-only history record")
      assert(entry.dig(:body, :history, "archived_actions")&.any? { |action| action["id"] == pending["id"] },
             "expected expired approvals to remain in the full archived action history")
      assert(expired["precondition_token"].nil? && entry.dig(:body, :history, "archived_conversation", "agent_key") == old_key,
             "expected history to strip acceptance authority while linking the archived conversation")
      archived_unknown = entry.dig(:body, :history, "archived_actions")&.find { |action| action["id"] == uncertain["id"] }
      assert(archived_unknown && archived_unknown["state"] == "failed" &&
             archived_unknown["read_only"] == true && archived_unknown["recovery"]["state"] == "outcome_unknown" &&
             archived_unknown["expired"] != true,
             "expected an accepted uncertain action to retain its truthful read-only outcome")
      assert(fixture.route(server, service, "GET", "/personal-assistant/actions", {}).dig(:body, :proposals).none? { |action| action["id"] == pending["id"] },
             "expected the new active action list to exclude the old proposal")
      worker.shutdown
    end
  end

  def self.assert_history_preserves_truthful_accepted_states
    with_fixture do |fixture|
      service, server, actions, worker = fixture.build(executor: ->(*) { {} })
      fixture.open!(service, server)
      proposals = {
        "queued" => fixture.register(actions, "start_agent", { "agent_key" => "queued-agent" }, "history-queued-1"),
        "executing" => fixture.register(actions, "start_agent", { "agent_key" => "executing-agent" }, "history-executing-1"),
        "verifying" => fixture.register(actions, "start_agent", { "agent_key" => "verifying-agent" }, "history-verifying-1"),
        "failed" => fixture.register(actions, "start_agent", { "agent_key" => "failed-agent" }, "history-failed-1"),
        "executed" => fixture.register(actions, "start_agent", { "agent_key" => "executed-agent" }, "history-executed-1"),
        "rejected" => fixture.register(actions, "start_agent", { "agent_key" => "rejected-agent" }, "history-rejected-1")
      }
      state = HQ::FileStore.read_json(actions.path, fallback: {})
      state.fetch("proposals").each do |proposal|
        original_state = proposals.find { |_state, candidate| candidate["id"] == proposal["id"] }&.first
        next unless original_state

        proposal["state"] = original_state
        proposal["recovery"] = { "state" => "outcome_unknown", "action" => "verify", "reason" => "Unknown." } if original_state == "failed"
      end
      HQ::FileStore.write_json(actions.path, state)
      old_key = service.personal_assistant[:active_key]
      service.instance_variable_get(:@personal_assistant).restart!({ "confirmed" => true })
      history = fixture.route(server, service, "GET", "/personal-assistant/history", {})
      history_id = history.dig(:body, :history, 0, "id")
      entry = fixture.route(server, service, "GET", "/personal-assistant/history/#{history_id}", {})
      archived = entry.dig(:body, :history, "archived_actions")
      assert(entry.dig(:body, :history, "expired_actions").empty?,
             "expected accepted and terminal archived actions not to appear in expired_actions")

      expected_states = %w[queued executing verifying failed executed rejected]
      expected_states.each do |original_state|
        action = archived&.find { |candidate| candidate["id"] == proposals.fetch(original_state)["id"] }
        assert(action && action["state"] == original_state &&
               action["read_only"] == true && action["expired"] != true && action["precondition_token"].nil?,
               "expected #{original_state} history to remain truthful and read-only")
      end
      assert(entry.dig(:body, :history, "archived_conversation", "agent_key") == old_key,
             "expected truthful archived actions to remain attached to the prior conversation")
      worker.shutdown
    end
  end

  def self.assert_worker_project_create_preserves_foreground_update
    with_fixture do |fixture|
      barrier = Queue.new
      release = Queue.new
      barrier_registry = Phase2BarrierRegistry.new(
        path: fixture.registry.path,
        system_prompts_path: fixture.registry.system_prompts_path,
        barrier:, release:
      )
      service = nil
      service, server, actions, worker = fixture.build(
        executor: lambda do |type, arguments|
          Thread.current[:phase2_worker_barrier] = true
          service.execute_personal_assistant_action(type, arguments)
        end
      )
      fixture.open!(service, server)
      service.instance_variable_set(:@registry, barrier_registry)
      worker_path = File.join(fixture.dir, "worker-project")
      FileUtils.mkdir_p(worker_path)
      proposal = fixture.register(actions, "create_project", {
        "key" => "worker-project", "name" => "Worker Project", "path" => worker_path,
        "group" => nil, "agent" => nil, "model" => nil, "reasoning_effort" => nil
      }, "worker-project-1")
      actions.enqueue!(proposal["id"], confirmed: true, digest: proposal["digest"])

      foreground = nil
      released = false
      begin
        worker.start!
        take_barrier(barrier)
        foreground = Thread.new { service.update_project("web", "name" => "Foreground Web") }
        sleep 0.05
        assert(foreground.alive?, "expected foreground project update to wait for the worker config transaction")
        release << true
        released = true
        foreground.value
        wait_until { actions.proposal(proposal["id"])["state"] == "executed" }
        projects = Array(YAML.safe_load(File.read(fixture.registry.path))["projects"])
        worker_project = projects.find { |project| project["key"] == "worker-project" }
        web = projects.find { |project| project["key"] == "web" }
        assert(worker_project && web["name"] == "Foreground Web",
               "expected worker project creation and foreground project update to survive the config race")
      ensure
        release << true unless released
        foreground&.join(2)
        worker.shutdown
      end
    end
  end

  def self.assert_worker_project_create_preserves_foreground_settings
    with_fixture do |fixture|
      barrier = Queue.new
      release = Queue.new
      barrier_registry = Phase2BarrierRegistry.new(
        path: fixture.registry.path,
        system_prompts_path: fixture.registry.system_prompts_path,
        barrier:, release:
      )
      service = nil
      service, server, actions, worker = fixture.build(
        executor: lambda do |type, arguments|
          Thread.current[:phase2_worker_barrier] = true
          service.execute_personal_assistant_action(type, arguments)
        end
      )
      fixture.open!(service, server)
      service.instance_variable_set(:@registry, barrier_registry)
      worker_path = File.join(fixture.dir, "worker-settings-project")
      FileUtils.mkdir_p(worker_path)
      proposal = fixture.register(actions, "create_project", {
        "key" => "worker-settings-project", "name" => "Worker Settings Project", "path" => worker_path,
        "group" => nil, "agent" => nil, "model" => nil, "reasoning_effort" => nil
      }, "worker-settings-project-1")
      actions.enqueue!(proposal["id"], confirmed: true, digest: proposal["digest"])

      foreground = nil
      released = false
      begin
        worker.start!
        take_barrier(barrier)
        foreground = Thread.new do
          barrier_registry.update_personal_assistant!(
            "enabled" => true,
            "model" => "foreground-model",
            "reasoning_effort" => "low",
            "timezone" => "UTC"
          )
        end
        sleep 0.05
        assert(foreground.alive?, "expected FRED settings update to wait for the worker config transaction")
        release << true
        released = true
        foreground.value
        wait_until { actions.proposal(proposal["id"])["state"] == "executed" }
        data = YAML.safe_load(File.read(fixture.registry.path))
        projects = Array(data["projects"])
        settings = data["personal_assistant"]
        assert(projects.any? { |project| project["key"] == "worker-settings-project" } &&
               settings["model"] == "foreground-model" && settings["timezone"] == "UTC",
               "expected worker project creation and foreground FRED settings to survive the config race")
      ensure
        release << true unless released
        foreground&.join(2)
        worker.shutdown
      end
    end
  end

  def self.with_fixture
    Dir.mktmpdir("case-", PHASE2_TEST_FIXTURES) do |dir|
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      config_path = File.join(dir, "hq.yml")
      prompts_path = File.join(dir, "system_prompts.yml")
      File.write(config_path, <<~YAML)
        projects:
          - key: web
            name: Web
            path: #{workspace}
            agent: codex
            model: inherited-model
            reasoning_effort: low
      YAML
      File.write(prompts_path, "custom: Default prompt.\n")
      registry = HQ::Registry.new(path: config_path, system_prompts_path: prompts_path)
      fixture = Fixture.new(dir, registry)
      with_runtime_roots(dir) { yield fixture }
    end
  end

  def self.with_runtime_roots(dir)
    logs = File.join(dir, "logs")
    paths = {
      USER_CONFIG_DIR: File.join(dir, "config"),
      USER_SCHEDULES_DIR: File.join(dir, "schedules"),
      USER_LOGS_DIR: logs,
      USER_WORKSPACES_DIR: File.join(dir, "workspaces"),
      LOGS_DIR: logs,
      AGENTS_FILE: File.join(logs, "managed_agents.json"),
      PERSONAL_ASSISTANT_DIR: File.join(logs, "personal_assistant"),
      DELEGATIONS_FILE: File.join(logs, "agent_delegations.json"),
      SERVER_IDENTITY_FILE: File.join(dir, "config", "server_identity.json"),
      USAGE_METRICS_FILE: File.join(logs, "usage_metrics.json"),
      REMOTE_RESOURCES_FILE: File.join(logs, "remote_resources.json"),
      REMOTE_CONTROL_FILE: File.join(logs, "remote_control.json"),
      SCHEDULES_FILE: File.join(dir, "config", "schedules.yml"),
      SCHEDULES_STATE_FILE: File.join(logs, "schedules.json"),
      SCHEDULER_DAEMON_FILE: File.join(logs, "scheduler_daemon.json"),
      PUSH_SUBSCRIPTIONS_FILE: File.join(logs, "push_subscriptions.json"),
      PUSH_NOTIFICATIONS_FILE: File.join(logs, "push_notifications.json"),
      WEB_PUSH_VAPID_FILE: File.join(logs, "web_push_vapid.json"),
      PROJECT_LOGS_DIR: File.join(logs, "projects"),
      PROJECT_ARCHIVE_DIR: File.join(logs, "projects", "archived"),
      AGENT_LOGS_DIR: File.join(logs, "agents"),
      AGENT_ARCHIVE_DIR: File.join(logs, "agents", "archive"),
      LOG_FILE: File.join(logs, "hq.log"),
      HOOKS_LOG_FILE: File.join(logs, "hooks.log")
    }
    previous = paths.to_h { |name, _path| [name, HQ.const_get(name)] }
    paths.each do |name, path|
      HQ.send(:remove_const, name)
      HQ.const_set(name, path)
    end
    FileUtils.mkdir_p(paths.values_at(:USER_CONFIG_DIR, :USER_SCHEDULES_DIR, :USER_WORKSPACES_DIR,
                                      :PERSONAL_ASSISTANT_DIR, :PROJECT_LOGS_DIR, :PROJECT_ARCHIVE_DIR,
                                      :AGENT_LOGS_DIR, :AGENT_ARCHIVE_DIR))
    HQ.instance_variable_set(:@logger, nil)
    yield
  ensure
    paths&.each_key do |name|
      HQ.send(:remove_const, name) if HQ.const_defined?(name, false)
      HQ.const_set(name, previous.fetch(name)) if previous
    end
    HQ.instance_variable_set(:@logger, nil)
  end

  class Fixture
    attr_reader :dir, :registry

    def initialize(dir, registry)
      @dir = dir
      @registry = registry
      @now = Time.utc(2026, 9, 9, 12)
    end

    def build(executor:, service_class: HQ::RemoteService)
      action_path = File.join(@dir, "proposals.json")
      service = nil
      actions = HQ::PersonalAssistantActions.new(
        path: action_path, auto_execute: false, clock: -> { @now },
        executor: executor,
        verifier: ->(*) { { "completed" => false, "no_effect" => true, "reason" => "No effect" } },
        guard: -> proposal do
          service.ensure_personal_assistant_action_active!(proposal)
          service.revalidate_personal_assistant_action!(proposal)
        end
      )
      worker = HQ::PersonalAssistantActionWorker.new(actions:, worker_id: "fixture-worker", wait: 0.01, lease_seconds: 30)
      service = service_class.new(
        registry: @registry, server_url: "http://127.0.0.1:7399", clock: -> { @now },
        personal_assistant_actions: actions, personal_assistant_action_worker: worker
      )
      server = HQ::RemoteServer.new(personal_assistant_action_worker: worker)
      [service, server, actions, worker]
    end

    def open!(service, server)
      route(server, service, "POST", "/personal-assistant/setup", {
        "confirmed" => true, "model" => "fred-model", "reasoning_effort" => "medium", "timezone" => "UTC"
      })
      route(server, service, "POST", "/personal-assistant/open", {})
    end

    def register(actions, type, arguments, run_id)
      actions.register_finalized!([
        { "type" => type, "description" => "Fixture action", "arguments" => arguments }
      ], active_key: active_key, source_run_id: run_id).first
    end

    def active_key
      agents = HQ::AgentStore.new(@registry.projects.map { |config| HQ::Project.new(config) }).load
      agents.find(&:personal_assistant?)&.key || "personal-assistant-2026-09-09-1"
    end

    def route(server, service, method, path, body)
      server.send(:route, service, method, path, body, nil)
    rescue HQ::RemoteServer::Error => e
      { status: e.status, body: { error: e.message, details: e.details } }
    end

    def write_schedules!
      File.write(HQ::SCHEDULES_FILE, <<~YAML)
        schedules:
          - key: daily
            name: Daily
            cron: "0 9 * * *"
            timezone: UTC
            target:
              type: agent
              project_key: web
              name: Daily agent
              message: Review.
      YAML
    end

    def advance_clock!(seconds)
      @now += seconds
    end

    def free_port
      socket = TCPServer.new("127.0.0.1", 0)
      port = socket.addr[1]
      socket.close
      port
    end

    def wait_for_http!(port)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      loop do
        socket = TCPSocket.new("127.0.0.1", port)
        socket.close
        return true
      rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
        raise "timed out waiting for phase2 HTTP server" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end
    end

    def http_request(port, method, path, body = {})
      uri = URI("http://127.0.0.1:#{port}#{path}")
      request_class = Net::HTTP.const_get(method.capitalize)
      request = request_class.new(uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body) unless body.empty?
      response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
      [response.code.to_i, JSON.parse(response.body)]
    end
  end

  def self.wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out waiting for phase2 worker" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end

  def self.take_barrier(barrier)
    Timeout.timeout(2) { barrier.pop }
  rescue Timeout::Error
    raise "timed out waiting for the worker write barrier"
  end

  def self.replace_agent_store(service, barrier:, release:)
    store = Phase2BarrierAgentStore.new(service.instance_variable_get(:@projects), barrier:, release:)
    service.instance_variable_set(:@agent_store, store)
    store
  end

  def self.assert(value, message)
    raise message unless value
  end
end

PersonalAssistantPhase2Test.run if $PROGRAM_NAME == __FILE__
