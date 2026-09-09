# frozen_string_literal: true

require "fileutils"
require "tmpdir"
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
  TYCHO_LOGS_ROOT TYCHO_SCHEDULES_PATH TYCHO_SCHEDULES_ROOT
  TYCHO_SCHEDULES_STATE_PATH TYCHO_SCHEDULER_DAEMON_PATH
].each { |name| ENV.delete(name) }
ENV["TYCHO_HOME"] = PHASE2_TEST_HOME
ENV["TMPDIR"] = PHASE2_TEST_TMPDIR
ENV["TMP"] = PHASE2_TEST_TMPDIR
ENV["TEMP"] = PHASE2_TEST_TMPDIR
ENV["TYCHO_CODEX_BIN"] = File.join(PHASE2_TEST_HOME, "missing-codex")

require_relative "../lib/hq/remote_server"

class PersonalAssistantPhase2Test
  def self.run
    assert_background_confirmation_is_durable_and_nonblocking
    assert_frozen_preview_reconciles_stale_defaults
    assert_schedule_precondition_ignores_derived_next_run
    puts "personal_assistant_phase2_test: OK"
  end

  def self.assert_background_confirmation_is_durable_and_nonblocking
    with_fixture do |fixture|
      started = Queue.new
      release = Queue.new
      service, server, actions, worker = fixture.build(
        executor: ->(*) { started << true; release.pop; { "ok" => true } }
      )
      fixture.open!(service, server)
      proposal = fixture.register(actions, "start_agent", { "agent_key" => "missing-agent" }, "start-1")
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
    attr_reader :registry

    def initialize(dir, registry)
      @dir = dir
      @registry = registry
      @now = Time.utc(2026, 9, 9, 12)
    end

    def build(executor:)
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
      service = HQ::RemoteService.new(
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
  end

  def self.wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out waiting for phase2 worker" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end

  def self.assert(value, message)
    raise message unless value
  end
end

PersonalAssistantPhase2Test.run if $PROGRAM_NAME == __FILE__
