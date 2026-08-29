# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "rbconfig"
require "base64"
require "open3"
require "yaml"

require_relative "../lib/hq/remote_server"
require_relative "../lib/hq/serve_command"

module RemoteServerTest
  module_function

  def run!
    assert_remote_agent_lifecycle
    assert_remote_agent_delegation_lifecycle
    assert_remote_agent_response_style_selection_is_independent
    assert_remote_archive_reconciles_scheduled_agent_state
    assert_remote_agent_bulk_archive
    assert_remote_agent_clone_archives_source_with_editable_name
    assert_remote_agent_payload_has_revision
    assert_remote_agent_payload_distinguishes_running_history_from_never_run
    assert_remote_agent_activity_snapshot
    assert_remote_agent_payload_has_cost_snapshot
    assert_remote_memory_handoffs
    assert_remote_metrics_query_and_backfill_routes
    assert_remote_inquiry_payload_has_stable_id_and_guarded_answer
    assert_remote_inquiry_dismiss_restore_and_retirement_lifecycle
    assert_remote_agent_payload_includes_attachments
    assert_remote_agent_pull_request_diff_payload
    assert_agent_pull_request_listing_avoids_eager_metadata_requests
    assert_concurrent_pull_request_diff_refreshes_are_coalesced
    assert_pull_request_review_refresh_reuses_metadata
    assert_pull_request_feature_gate_and_global_inbox
    assert_pull_request_line_handoff_uses_snapshot_context
    assert_remote_prompt_accepts_pull_request_context
    assert_github_app_auth_routes
    assert_pull_request_posting_is_confirmed_stale_safe_and_idempotent
    assert_remote_prompt_accepts_uploaded_attachments
    assert_remote_prompt_start_accepts_dash_prefixed_message
    assert_remote_agent_conversation_includes_run_summary
    assert_remote_agent_debug_endpoints
    assert_remote_project_payloads_include_status_and_detail
    assert_remote_project_git_diff_payload
    assert_remote_project_workspace_routes
    assert_remote_project_update_route_edits_metadata
    assert_remote_agent_model_and_effort_payloads
    assert_remote_hidden_settings_filter_projects_and_agents
    assert_remote_response_style_settings
    assert_remote_session_loop_settings
    assert_remote_skill_installation_requires_confirmation
    assert_remote_schedule_routes
    assert_remote_setup_payload_includes_readiness
    assert_remote_harness_catalogs_are_configurable
    assert_remote_setup_refreshes_harness_catalogs
    assert_remote_setup_uses_shared_executable_resolution
    assert_remote_setup_handles_utf8_harness_output_under_ascii_external
    assert_remote_welcome_onboarding_creates_project
    assert_remote_welcome_onboarding_exposes_agent_cli_guides
    assert_remote_setup_warns_when_public_url_has_no_token
    assert_remote_server_restart_route_schedules_restart
    assert_remote_broker_lists_configured_servers
    assert_remote_resource_catalog_combines_and_retains_peer_resources
    assert_remote_broker_proxies_configured_server_requests
    assert_remote_broker_logs_recoverable_activity_5xx
    assert_remote_broker_proxies_loopback_peer_requests
    assert_remote_server_persists_added_servers
    assert_remote_server_allows_tailnet_ad_hoc_servers
    assert_server_detects_unauthenticated_non_loopback_bind
    assert_serve_command_accepts_daemon_mode
    assert_remote_push_subscription_lifecycle
    assert_remote_agent_push_notifications
    assert_remote_search_index_includes_agents_and_projects
    assert_remote_skills_payload_uses_discovery
    assert_remote_ui_routes_load_without_auth
    assert_write_http_keeps_keyword_body_compatibility
    assert_server_prints_public_url
    assert_server_prints_startup_messages
    assert_server_prints_public_url_qr
    assert_server_daemonizes_after_startup_to_log
    assert_server_prints_request_logs
    puts "remote_server_test: ok"
  end

  def assert_remote_agent_delegation_lifecycle
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)
      parent = service.create_agent(
        "project_key" => "web", "name" => "Parent <script>", "prompt" => "Coordinate", "agent" => "codex"
      )
      child = service.create_agent(
        "project_key" => "web", "name" => "Child", "prompt" => "Work", "agent" => "codex",
        "parent_agent_key" => parent[:key]
      )

      assert(child.dig(:delegation, :parent, :agent_key) == parent[:key], "expected child started-by reference")
      assert(child.dig(:delegation, :parent, :connected), "expected delegation callbacks to start connected")
      assert(child.dig(:delegation, :parent, :owner) == "parent" &&
             child.dig(:delegation, :parent, :ownership_generation) == 1,
             "expected an explicit parent key to create delegated ownership")
      parent_payload = service.agent(parent[:key])
      assert(parent_payload.dig(:delegation, :children, 0, :agent_key) == child[:key],
             "expected parent delegated-agents reference")

      disconnected = HQ::RemoteServer.new.send(
        :route, service, "PATCH", "/agents/#{child[:key]}/delegation", { "connected" => false }, nil
      )
      assert(disconnected.dig(:body, :agent, :delegation, :parent, :connected) == false,
             "expected child detail to expose a soft-disconnected parent")
      disconnected_parent = service.agent(parent[:key])
      assert(disconnected_parent.dig(:delegation, :children, 0, :connected) == false,
             "expected parent detail to expose the disconnected child")
      reconnected = service.update_agent_delegation(child[:key], "connected" => true)
      assert(reconnected.dig(:agent, :delegation, :parent, :connected),
             "expected soft-disconnected delegation to reconnect")
      conversation = service.conversation(parent[:key])
      event = conversation.find { |block| block[:kind] == "delegation_event" }
      assert(event && event.dig(:metadata, "agent_reference", "agent_key") == child[:key],
             "expected explicit typed creation event")

      repeated = service.submit_prompt(child[:key], "prompt" => "Continue", "parent_agent_key" => parent[:key])
      assert(repeated[:agent].dig(:delegation, :parent, :agent_key) == parent[:key],
             "expected idempotent message attachment")
      assert(repeated[:agent].dig(:delegation, :parent, :owner) == "parent" &&
             repeated[:agent].dig(:delegation, :parent, :ownership_generation) == 1,
             "expected a repeated parent declaration to preserve delegation")
      signed_prompt = repeated[:conversation].find { |block| block[:content] == "Continue" }
      assert(signed_prompt&.dig(:metadata, "message_author", "type") == "agent" &&
             signed_prompt.dig(:metadata, "message_author", "agent_key") == parent[:key] &&
             signed_prompt.dig(:metadata, "message_author", "name") == "Parent <script>",
             "expected a parent-declared prompt to persist its agent signature")

      taken_over = service.submit_prompt(child[:key], "prompt" => "I will handle this directly")
      assert(taken_over[:agent].dig(:delegation, :parent, :owner) == "user" &&
             taken_over[:agent].dig(:delegation, :parent, :ownership_generation) == 2,
             "expected a direct user prompt to take over the delegated child")
      direct_prompt = taken_over[:conversation].find { |block| block[:content] == "I will handle this directly" }
      assert(!direct_prompt&.dig(:metadata, "message_author"),
             "expected a direct user prompt to remain unsigned")

      reclaimed = service.submit_prompt(
        child[:key], "prompt" => "Resume delegated work", "parent_agent_key" => parent[:key]
      )
      assert(reclaimed[:agent].dig(:delegation, :parent, :owner) == "parent" &&
             reclaimed[:agent].dig(:delegation, :parent, :ownership_generation) == 3,
             "expected a later parent prompt to restore delegation")

      child_actor = HQ::DelegationActor.parent_actor(child[:key])
      begin
        service.submit_prompt(parent[:key], { "prompt" => "Upward prompt" }, actor: child_actor)
        raise "expected upward prompt rejection"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 403, "expected ancestor prompts to be forbidden")
      end
      begin
        service.submit_prompt(parent[:key], "prompt" => "No", "parent_agent_key" => parent[:key])
        raise "expected self-parent rejection"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 409, "expected self-parent conflict")
      end

      archived = service.archive_agent(child[:key])
      archived_payload = service.agent(child[:key])
      assert(archived[:archived] && archived_payload[:archived], "expected archived child detail navigation")
      assert(!archived_payload[:archived_at].to_s.empty?, "expected immutable archive time in detail")
      assert(archived_payload.dig(:delegation, :parent, :agent_key) == parent[:key],
             "expected archived child to retain parent link")

      archive_index = service.archived_agents("page" => "1", "per_page" => "1", "q" => "Child")
      assert(archive_index.dig(:pagination, :total) == 1 && archive_index.dig(:pagination, :page) == 1,
             "expected paginated archived-agent discovery")
      project_archive_index = service.archived_agents("q" => "Web")
      assert(project_archive_index.dig(:pagination, :total) == 1,
             "expected archive query to search project display names")
      indexed = archive_index.fetch(:agents).fetch(0)
      assert(indexed[:key] == child[:key] && indexed[:archived] && indexed[:archived_at],
             "expected read-only archived identity in the archive index")
      assert(indexed.dig(:delegation, :parent, :agent_key) == parent[:key],
             "expected archive discovery to preserve delegation context")

      request = Struct.new(:query_params).new({ "page" => "1", "per_page" => "100" })
      routed = HQ::RemoteServer.new.send(:route, service, "GET", "/agents/archived", {}, request)
      assert(routed.dig(:body, :agents, 0, :key) == child[:key], "expected archived-agent API route")

      begin
        service.start_agent(child[:key])
        raise "expected archived mutation rejection"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 409 && e.message.include?("read-only"),
               "expected archived mutations to report an explicit read-only conflict")
      end

      begin
        service.archived_agents("per_page" => "101")
        raise "expected archive page limit rejection"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 400, "expected invalid archive pagination to return 400")
      end
      begin
        service.archived_agents("page" => "9" * 100)
        raise "expected huge archive page rejection"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 400, "expected huge archive pages to return 400")
      end

      service.archive_agent(parent[:key])
      first_page = service.archived_agents("page" => "1", "per_page" => "1")
      second_page = service.archived_agents("page" => "2", "per_page" => "1")
      assert(first_page.dig(:pagination, :total) == 2 && first_page.dig(:pagination, :next_page) == 2 &&
             second_page.dig(:pagination, :next_page).nil? &&
             first_page.dig(:agents, 0, :key) != second_page.dig(:agents, 0, :key),
             "expected stable multi-page archive ordering")
    end
  end

  def assert_remote_memory_handoffs
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      File.write(registry.path, File.read(registry.path).sub("group: Core", "group: Personal"))
      registry.load!
      service = HQ::RemoteService.new(registry: registry)
      created = service.create_agent("project_key" => "web", "name" => "Memory", "prompt" => "Capture", "agent" => "codex")
      store = HQ::AgentStore.new(registry.projects.map { |config| HQ::Project.new(config) })
      agent = store.load.find { |item| item.key == created[:key] }
      agent.runs << HQ::ManagedAgent::AgentRun.new(
        run_id: "run-memory-1", status: "success", finished_at: Time.parse("2026-08-26 10:00:00 UTC"),
        metadata: {
          "memory_handoff" => {
            "outcome" => "Captured handoff", "decisions" => [], "continuing_context" => "", "references" => []
          }
        }
      )
      store.save([agent])

      payload = service.memory_handoffs
      assert(payload[:projects] == { "web" => "Personal" }, "expected live eligible group provenance")
      assert(payload[:runs].first.dig(:metadata, :memory_handoff, "outcome") == "Captured handoff",
             "expected successful persisted handoff in source feed")
      response = HQ::RemoteServer.new.send(:route, service, "GET", "/memory-handoffs", {}, nil)
      assert(response.dig(:body, :runs, 0, :run_id) == "run-memory-1", "expected API handoff retrieval")
    end
  end

  def assert_remote_agent_activity_snapshot
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      snapshot = HQ::AgentActivitySnapshot.new
      service = HQ::RemoteService.new(registry: registry, agent_activity_snapshot: snapshot)
      agent = service.create_agent(
        "project_key" => "web", "name" => "Activity agent", "prompt" => "Observe", "agent" => "codex"
      )
      child = service.create_agent(
        "project_key" => "web", "name" => "Activity child", "prompt" => "Delegate", "agent" => "codex",
        "parent_agent_key" => agent[:key]
      )
      stored_agents = HQ::AgentStore.new([]).load
      stored = stored_agents.find { |candidate| candidate.key == agent[:key] }
      stored.mark_unread!
      HQ::AgentStore.new([]).save(stored_agents)
      service.agents

      server = HQ::RemoteServer.new(agent_activity_snapshot: snapshot)
      response = server.send(:route, service, "GET", "/servers/activity", {}, nil)
      activity = response.fetch(:body)
      local = activity.fetch(:servers).find { |entry| entry[:key] == "local" }
      parent_activity = local.fetch(:agents).find { |entry| entry[:key] == agent[:key] }
      child_activity = local.fetch(:agents).find { |entry| entry[:key] == child[:key] }
      assert(activity[:unread_count] == 1, "expected aggregate activity unread count")
      assert(local[:ready] && parent_activity[:name] == "Activity agent",
             "expected the activity endpoint to expose the shared local snapshot")
      assert(parent_activity[:unread], "expected activity to include unread state")
      assert(parent_activity.dig(:delegation, :children, 0, :agent_key) == child[:key] &&
             child_activity.dig(:delegation, :parent, :agent_key) == agent[:key],
             "expected activity to include compact delegation topology")
      assert(!parent_activity.key?(:prompt), "expected activity to omit full agent detail")
    end
  end

  def assert_remote_agent_payload_has_cost_snapshot
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)
      agent = HQ::ManagedAgent.new(
        key: "cost-payload-agent",
        name: "Cost payload",
        project_key: "demo",
        template_key: "custom",
        workspace: workspace,
        prompt: "Prompt",
        agent: "claude",
        cost_snapshot: {
          "currency" => "USD",
          "amount_usd" => 2.5,
          "coverage" => "complete",
          "session_id" => "cost-session"
        }
      )

      payload = service.send(:agent_payload, agent)
      assert(payload.dig(:cost_snapshot, "amount_usd") == 2.5,
             "expected remote agent payloads to expose the persisted cost snapshot")
    end
  end

  def assert_remote_metrics_query_and_backfill_routes
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      store = HQ::UsageMetrics::Store.new(path: HQ::USAGE_METRICS_FILE)
      store.upsert(
        "run_id" => "remote-metric-run",
        "agent_key" => "demo-agent-1",
        "project_key" => "demo",
        "group" => "work",
        "harness" => "claude",
        "harness_adapter" => "claude",
        "configured_model" => "configured-model",
        "observed_models" => ["observed-model"],
        "native_session_id" => "remote-session",
        "session_key" => "claude:remote-session",
        "started_at" => Time.utc(2026, 7, 6, 10).iso8601,
        "status" => "succeeded",
        "tokens" => { "input_tokens" => 10, "cached_input_tokens" => 0, "output_tokens" => 2 },
        "estimated_cost" => {
          "amount_usd" => 1.25,
          "currency" => "USD",
          "semantics" => "estimate_not_invoice",
          "source" => "claude_reported_estimate"
        },
        "completeness" => { "overall" => "complete", "unknown_reasons" => [] },
        "provenance" => { "source" => "fixture", "event_count" => 0 }
      )
      service = HQ::RemoteService.new(registry: registry)
      server = HQ::RemoteServer.new

      query = server.send(:route, service, "GET", "/metrics", {}, nil)
      assert(query.dig(:body, "summary", "run_starts") == 1, "expected Remote API metrics query")
      assert(query.dig(:body, "summary", "known_estimated_cost_usd") == 1.25,
             "expected Remote API cost summary")
      backfill = server.send(:route, service, "POST", "/metrics/backfill", { "durable_only" => true }, nil)
      assert(backfill.dig(:body, "status") == "success", "expected Remote API backfill route")
    end
  end

  def assert_remote_session_loop_settings
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)
      server = HQ::RemoteServer.new

      fetched = server.send(:route, service, "GET", "/settings/session-loops", {}, nil)
      assert(fetched.dig(:body, :session_loops, :interval_minutes) == 10,
             "expected session loop settings route to expose defaults")

      updated = server.send(:route, service, "PATCH", "/settings/session-loops", {
                              "interval_minutes" => 12,
                              "end_time" => "19:45",
                              "prompt_templates" => [
                                {
                                  "key" => "review-watch",
                                  "name" => "Review watch",
                                  "prompt" => "Check for actionable PR feedback."
                                },
                                {
                                  "key" => "release-watch",
                                  "name" => "Release watch",
                                  "prompt" => "Check release readiness.\nReport blockers only."
                                }
                              ]
                            }, nil)
      assert(updated.dig(:body, :session_loops, :interval_minutes) == 12,
             "expected session loop settings update route")
      assert(service.setup.dig(:config, :session_loop_settings, :end_time) == "19:45",
             "expected setup payload to expose saved session loop settings")
      persisted = YAML.safe_load_file(registry.path)
      assert(persisted.dig("session_loops", "prompt_templates", 0, "prompt") ==
             "Check for actionable PR feedback.",
             "expected session loop settings to persist in hq.yml")
      assert(persisted.dig("session_loops", "prompt_templates", 1, "prompt") ==
             "Check release readiness.\nReport blockers only.",
             "expected session loop settings to persist each template prompt independently")
    end
  end

  def assert_remote_skill_installation_requires_confirmation
    with_remote_temp_store do |dir|
      home = File.join(dir, "home")
      source = File.join(dir, "source")
      skill_dir = File.join(source, "tycho")
      manifest = File.join(dir, "skill-assets.json")
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p([home, skill_dir])
      File.write(File.join(skill_dir, "SKILL.md"), "---\nname: tycho\ndescription: Test Tycho\n---\n")
      checksum = Digest::SHA256.file(File.join(skill_dir, "SKILL.md")).hexdigest
      File.write(manifest, JSON.generate({
        source: "https://example.test/tycho-skills",
        version: "test-1",
        verification: "Invoke tycho",
        skills: [{ name: "tycho", files: { "SKILL.md" => checksum } }]
      }))
      write_project_workspace(workspace)
      installer = HQ::SkillInstaller.new(home: home, source_root: source, manifest_path: manifest)
      service = HQ::RemoteService.new(registry: registry_for_project(dir, workspace), skill_installer: installer)
      server = HQ::RemoteServer.new

      previous_skills_home = ENV["TYCHO_SKILLS_HOME"]
      ENV["TYCHO_SKILLS_HOME"] = home
      begin
        environment_service = HQ::RemoteService.new(registry: registry_for_project(dir, workspace))
        environment_target = environment_service.skill_installation.dig(:harnesses, 0, :target_path)
        assert(environment_target == File.join(home, ".agents", "skills"),
               "expected TYCHO_SKILLS_HOME to isolate default skill installation")
      ensure
        ENV["TYCHO_SKILLS_HOME"] = previous_skills_home
      end

      fetched = server.send(:route, service, "GET", "/skills", {}, nil)
      harnesses = fetched.dig(:body, :skill_installation, :harnesses)
      assert(harnesses.map { |item| item[:harness] } == %w[codex claude opencode pi],
             "expected Remote skills status for every supported harness")
      assert(harnesses.all? { |item| item[:status] == "missing" }, "expected isolated homes to start missing")

      begin
        server.send(:route, service, "POST", "/skills/codex/install", {}, nil)
        raise "expected skill mutation without confirmation to fail"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 400 && e.message.include?("Confirm"), "expected explicit mutation intent")
      end

      installed = server.send(:route, service, "POST", "/skills/codex/install", { "confirmed" => true }, nil)
      result = installed.dig(:body, :result)
      assert(result[:changed_skills] == ["tycho"], "expected Remote skill action to report exact changes")
      assert(result.dig(:harness, :target_path) == File.join(home, ".agents", "skills"),
             "expected Remote Codex install to use the isolated official path")
      assert(service.setup.dig(:skill_installation, :harnesses, 0, :status) == "installed",
             "expected setup to expose current skill status")
    end
  end

  def assert_remote_agent_lifecycle
    Dir.mktmpdir("hq-remote-test") do |dir|
      old_agents_file = replace_constant(HQ, :AGENTS_FILE, File.join(dir, "managed_agents.json"))
      old_delegations_file = replace_constant(HQ, :DELEGATIONS_FILE, File.join(dir, "agent_delegations.json"))
      old_server_identity_file = replace_constant(HQ, :SERVER_IDENTITY_FILE, File.join(dir, "server_identity.json"))
      old_usage_metrics_file = replace_constant(HQ, :USAGE_METRICS_FILE, File.join(dir, "usage_metrics.json"))
      old_logs_dir = replace_constant(HQ, :AGENT_LOGS_DIR, File.join(dir, "agents"))
      old_archive_dir = replace_constant(HQ, :AGENT_ARCHIVE_DIR, File.join(dir, "agents", "archive"))

      FileUtils.mkdir_p(HQ::AGENT_LOGS_DIR)
      FileUtils.mkdir_p(HQ::AGENT_ARCHIVE_DIR)
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      registry = registry_for(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)

      created = service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Remote Agent",
        "prompt" => "Work remotely.",
        "agent" => "codex"
      )
      assert(created[:key].match?(/\Aweb-agent-\d{8}-\d{6}-\d{6}(?:-[0-9a-f]{6})?\z/),
             "expected created agent key to use a collision-resistant timestamp")
      assert(created[:name] == "Remote Agent", "expected custom agent name")
      assert(created[:status] == "idle", "expected new agent to be idle")

      submitted = service.submit_prompt(created[:key], "prompt" => "Read the code first.")
      assert(submitted[:conversation].any? { |message| message[:role] == "user" && message[:content] == "Read the code first." },
             "expected submitted prompt to appear in conversation")

      updated = service.update_agent(created[:key], "name" => "Remote Agent Edited", "prompt" => "Updated prompt.")
      assert(updated[:name] == "Remote Agent Edited", "expected update to change name")
      assert(updated[:prompt] == "Updated prompt.", "expected update to change prompt")

      archived = service.archive_agent(created[:key])
      assert(archived[:archived], "expected archive response")
      assert(service.agents.empty?, "expected archived agent to be removed from active list")
    ensure
      replace_constant(HQ, :AGENTS_FILE, old_agents_file) if old_agents_file
      replace_constant(HQ, :DELEGATIONS_FILE, old_delegations_file) if old_delegations_file
      replace_constant(HQ, :SERVER_IDENTITY_FILE, old_server_identity_file) if old_server_identity_file
      replace_constant(HQ, :USAGE_METRICS_FILE, old_usage_metrics_file) if old_usage_metrics_file
      replace_constant(HQ, :AGENT_LOGS_DIR, old_logs_dir) if old_logs_dir
      replace_constant(HQ, :AGENT_ARCHIVE_DIR, old_archive_dir) if old_archive_dir
    end
  end

  def assert_remote_agent_response_style_selection_is_independent
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      response_style_path = File.join(dir, "config", "response_style.md")
      FileUtils.mkdir_p(File.dirname(response_style_path))
      File.write(response_style_path, "Use the global response style.\n")

      with_env_values("TYCHO_RESPONSE_STYLE_PATH" => response_style_path) do
        service = HQ::RemoteService.new(registry: registry_for_project(dir, workspace))
        created = service.create_agent(
          "project_key" => "web",
          "template_key" => "custom",
          "response_style_mode" => "disabled",
          "name" => "Independent Style Agent",
          "prompt" => "Use the custom prompt template.",
          "agent" => "codex"
        )
        assert(created[:template_key] == "custom", "expected the prompt template to remain custom")
        assert(created[:response_style] == false && created[:response_style_source] == "disabled",
               "expected response style selection to be independent from the custom prompt template")

        updated = service.update_agent(created[:key], "response_style_mode" => "global")
        assert(updated[:response_style].nil? && updated[:response_style_source] == "global",
               "expected a style-only edit to switch the agent back to the global response style")
      end
    end
  end

  def assert_remote_archive_reconciles_scheduled_agent_state
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      File.write(HQ::SCHEDULES_FILE, <<~YAML)
        schedules:
          - key: weekday
            cron: "0 9 * * 1-5"
            target:
              type: agent
              project_key: web
              message: "Run maintenance."
      YAML
      service = HQ::RemoteService.new(registry: registry)
      archive_reconciles_status = lambda do |agent_key:, status:, enabled:, paused_at: nil, expected_system_message: nil|
        state = HQ::ScheduleState.new(
          key: "weekday",
          status: status,
          enabled: enabled,
          paused_at: paused_at,
          last_status: "skipped",
          last_error: "interactive",
          last_target_kind: "agent",
          last_target_key: agent_key,
          next_due_at: Time.now + 3600,
          run_count: 1,
          skip_count: 1
        )
        HQ::ScheduleStore.new.save("weekday" => state)

        archived = service.archive_agent(agent_key)
        assert(archived[:schedule_reconciled], "expected Remote archive to reconcile schedule state")
        updated = HQ::ScheduleStore.new.load.fetch("weekday")
        assert(updated.scheduled?, "expected Remote archive to re-schedule the schedule from #{status.inspect}")
        assert(updated.enabled == true, "expected Remote archive to re-enable schedule")
        assert(updated.paused_at.nil?, "expected Remote archive to clear paused schedule state")
        assert(updated.last_error == "interactive", "expected Remote archive to preserve stop reason")
        assert(updated.last_target_key.nil?, "expected Remote archive to clear stale target")
        assert(updated.previous_target_key == agent_key, "expected Remote archive to keep previous target")
        if expected_system_message
          config = YAML.safe_load_file(HQ::SCHEDULES_FILE)
          system_message = config.dig("schedules", 0, "target", "system_message")
          assert(system_message == expected_system_message,
                 "expected Remote archive to persist the scheduled session system message")
        end
      end

      stopped_agent = service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Scheduled Stopped Agent",
        "prompt" => "Work remotely.",
        "agent" => "codex"
      )
      archive_reconciles_status.call(
        agent_key: stopped_agent[:key],
        status: "stopped",
        enabled: true,
        expected_system_message: "Work remotely."
      )

      paused_agent = service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Scheduled Paused Agent",
        "prompt" => "Work remotely.",
        "agent" => "codex"
      )
      archive_reconciles_status.call(
        agent_key: paused_agent[:key],
        status: "paused",
        enabled: false,
        paused_at: Time.now
      )
    end
  end

  def assert_remote_agent_bulk_archive
    running_pid = nil
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      registry = registry_for(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)
      server = HQ::RemoteServer.new

      archive_one = service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Archive One",
        "prompt" => "Archive this.",
        "agent" => "codex"
      )
      archive_two = service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Archive Two",
        "prompt" => "Archive this too.",
        "agent" => "codex"
      )
      running = service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Running Agent",
        "prompt" => "Keep running.",
        "agent" => "codex"
      )
      [archive_one, archive_two, running].each { |agent| File.write(agent[:log_path], "#{agent[:name]}\n") }

      running_pid = Process.spawn(RbConfig.ruby, "-e", "sleep 30", pgroup: true, out: File::NULL, err: File::NULL)
      stored = JSON.parse(File.read(HQ::AGENTS_FILE))
      stored.each do |agent|
        next unless agent["key"] == running[:key]

        agent["pid"] = running_pid
        agent["started_at"] = Time.now.iso8601
      end
      File.write(HQ::AGENTS_FILE, JSON.pretty_generate(stored))

      response = server.send(
        :route,
        service,
        "POST",
        "/agents/archive",
        { "keys" => [archive_one[:key], running[:key], "missing-agent", archive_two[:key], archive_one[:key]] },
        nil
      )

      archived_keys = response.dig(:body, :archived).map { |item| item[:agent_key] }
      assert(archived_keys == [archive_one[:key], archive_two[:key]], "expected bulk archive to archive unique idle agents")
      assert(response.dig(:body, :skipped).map { |item| item[:agent_key] } == [running[:key]],
             "expected bulk archive to skip running agents")
      assert(response.dig(:body, :failed).map { |item| item[:agent_key] } == ["missing-agent"],
             "expected bulk archive to report missing agents")
      assert(service.agents.map { |agent| agent[:key] } == [running[:key]],
             "expected only running agent to remain active")
      assert(response.dig(:body, :archived).all? { |item| item[:archive_path].nil? || Dir.exist?(item[:archive_path]) },
             "expected archived agents to report archive destinations when logs existed")
    ensure
      if running_pid
        begin
          Process.kill("TERM", -running_pid)
          Process.wait(running_pid)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end
      end
    end
  end

  def assert_remote_agent_clone_archives_source_with_editable_name
    Dir.mktmpdir("hq-remote-test") do |dir|
      old_agents_file = replace_constant(HQ, :AGENTS_FILE, File.join(dir, "managed_agents.json"))
      old_logs_dir = replace_constant(HQ, :AGENT_LOGS_DIR, File.join(dir, "agents"))
      old_archive_dir = replace_constant(HQ, :AGENT_ARCHIVE_DIR, File.join(dir, "agents", "archive"))

      FileUtils.mkdir_p(HQ::AGENT_LOGS_DIR)
      FileUtils.mkdir_p(HQ::AGENT_ARCHIVE_DIR)
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      registry = registry_for(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)

      source = service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Remote Agent",
        "prompt" => "Work remotely.",
        "agent" => "codex"
      )
      File.write(source[:log_path], "source log\n")

      default_clone = service.clone_agent(source[:key], {})
      assert(default_clone[:agent][:name] == source[:name], "expected default clone name to match source without copy suffix")
      service.archive_agent(default_clone[:agent][:key])

      cloned = service.clone_agent(
        source[:key],
        "name" => "Replacement Agent",
        "archive_source" => true
      )

      assert(cloned[:archived], "expected clone flow to archive the source agent")
      assert(cloned[:source_agent_key] == source[:key], "expected clone response to identify source")
      assert(cloned[:agent][:key] != source[:key], "expected cloned agent to have a fresh key")
      assert(cloned[:agent][:name] == "Replacement Agent", "expected clone form name override")
      assert(service.agents.map { |agent| agent[:key] } == [cloned[:agent][:key]],
             "expected source to be removed after clone-and-archive")
      assert(Dir.exist?(cloned[:archive_path]), "expected source logs to be archived")
    ensure
      replace_constant(HQ, :AGENTS_FILE, old_agents_file) if old_agents_file
      replace_constant(HQ, :AGENT_LOGS_DIR, old_logs_dir) if old_logs_dir
      replace_constant(HQ, :AGENT_ARCHIVE_DIR, old_archive_dir) if old_archive_dir
    end
  end

  def assert_remote_agent_payload_has_revision
    Dir.mktmpdir("hq-remote-test") do |dir|
      old_agents_file = replace_constant(HQ, :AGENTS_FILE, File.join(dir, "managed_agents.json"))
      old_logs_dir = replace_constant(HQ, :AGENT_LOGS_DIR, File.join(dir, "agents"))
      old_archive_dir = replace_constant(HQ, :AGENT_ARCHIVE_DIR, File.join(dir, "agents", "archive"))

      FileUtils.mkdir_p(HQ::AGENT_LOGS_DIR)
      FileUtils.mkdir_p(HQ::AGENT_ARCHIVE_DIR)
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      registry = registry_for(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)

      created = service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Remote Agent",
        "prompt" => "Work remotely.",
        "agent" => "codex"
      )

      assert(created.key?(:revision), "expected agent payload to include revision")
      assert(!created[:revision].to_s.empty?, "expected agent revision to be non-empty")
    ensure
      replace_constant(HQ, :AGENTS_FILE, old_agents_file) if old_agents_file
      replace_constant(HQ, :AGENT_LOGS_DIR, old_logs_dir) if old_logs_dir
      replace_constant(HQ, :AGENT_ARCHIVE_DIR, old_archive_dir) if old_archive_dir
    end
  end

  def assert_remote_agent_payload_distinguishes_running_history_from_never_run
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)
      running = HQ::ManagedAgent.new(
        key: "running-history-payload",
        name: "Running history payload",
        project_key: "demo",
        template_key: "custom",
        workspace: workspace,
        prompt: "Prompt",
        total_run_count: 2,
        runs: [HQ::ManagedAgent::AgentRun.new(status: "running")]
      )
      running.define_singleton_method(:running?) { true }
      never_run = HQ::ManagedAgent.new(
        key: "never-run-payload",
        name: "Never run payload",
        project_key: "demo",
        template_key: "custom",
        workspace: workspace,
        prompt: "Prompt"
      )

      assert(service.send(:agent_payload, running)[:summary] == "Run in progress",
             "expected Remote UI payload to show a running summary for recorded history")
      assert(service.send(:agent_payload, never_run)[:summary] == "No runs yet",
             "expected Remote UI payload to preserve the never-run empty state")
    end
  end

  def assert_remote_inquiry_payload_has_stable_id_and_guarded_answer
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)
      created = service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Remote Agent",
        "prompt" => "Work remotely.",
        "agent" => "codex"
      )
      agent = HQ::AgentStore.new(registry.projects).load.find { |item| item.key == created[:key] }
      started_at = Time.parse("2026-05-13 21:00:00 +0700")
      finished_at = started_at + 30
      inquiry = {
        "message" => "What should the agent do next?",
        "fields" => [
          {
            "key" => "next_step",
            "label" => "Next step",
            "description" => "Short instruction for the agent.",
            "input_type" => "textarea",
            "required" => true,
            "options" => nil
          }
        ]
      }
      run = HQ::ManagedAgent::AgentRun.new(
        started_at: started_at,
        finished_at: finished_at,
        status: "input_required",
        log_path: agent.raw_log_path
      )
      agent.runs << run
      agent.structured_result = {
        "status" => "input_required",
        "summary" => "Needs an answer.",
        "inquiry" => inquiry
      }
      inquiry_id = agent.send(:inquiry_identity, inquiry, run: run)
      HQ::AgentMemory.new(agent).append_inquiry_request!(inquiry, created_at: finished_at, inquiry_id: inquiry_id)
      HQ::AgentStore.new(registry.projects).save([agent])

      payload = service.agent(created[:key])
      exposed = payload[:latest_inquiry]
      assert(exposed["id"] == inquiry_id, "expected Remote inquiry payload to expose the current inquiry id")
      assert(exposed["run_count"] == 1, "expected inquiry payload to include run context")

      begin
        service.answer_inquiry(created[:key], "stale-inquiry", "answer" => "{\"next_step\":\"ship\"}")
        raise "expected stale inquiry answer to fail"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 409, "expected stale inquiry answer to return conflict")
      end

      result = service.answer_inquiry(
        created[:key],
        inquiry_id,
        "answer" => JSON.pretty_generate("next_step" => "Continue with the current session."),
        "feedback" => "Prefer the smallest safe change.",
        "start" => false
      )
      assert(result[:conversation].any? { |message| message[:role] == "user" && message[:content].include?("current session") },
             "expected accepted inquiry answer to be recorded as a user message")
      inquiry_reply = result[:conversation].find do |message|
        message[:role] == "user" && message.dig(:metadata, "inquiry_response")
      end
      assert(inquiry_reply, "expected accepted inquiry answer to be marked as an inquiry response")
      parsed_inquiry_reply = JSON.parse(inquiry_reply[:content])
      assert(parsed_inquiry_reply["user_feedback"] == "Prefer the smallest safe change.",
             "expected inquiry feedback to be embedded in the structured conversation answer")
      feedback_reply = result[:conversation].find do |message|
        message[:role] == "user" && message.dig(:metadata, "inquiry_feedback")
      end
      assert(feedback_reply.nil?, "expected embedded inquiry feedback not to create a duplicate conversation message")
      assert(result[:agent][:latest_inquiry].nil?, "expected accepted inquiry answer to clear the pending inquiry")
      response = HQ::AgentMemory.new(agent).events.reverse.find { |event| event["type"] == "inquiry_response" }
      assert(response.dig("metadata", "inquiry_id") == inquiry_id,
             "expected inquiry response memory to retain the answered inquiry id")
    end
  end

  def assert_remote_inquiry_dismiss_restore_and_retirement_lifecycle
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      client_a = HQ::RemoteService.new(registry: registry)
      client_b = HQ::RemoteService.new(registry: registry)
      created = client_a.create_agent(
        "project_key" => "web", "template_key" => "custom", "name" => "Inquiry Agent",
        "prompt" => "Ask before advancing.", "agent" => "codex"
      )
      agent = HQ::AgentStore.new(registry.projects).load.find { |item| item.key == created[:key] }
      inquiry = {
        "message" => "Choose the next step",
        "fields" => [{ "key" => "next_step", "label" => "Next step", "input_type" => "text", "required" => true }]
      }
      run = HQ::ManagedAgent::AgentRun.new(
        started_at: Time.utc(2026, 8, 29, 1), finished_at: Time.utc(2026, 8, 29, 1, 1),
        status: "input_required", log_path: agent.raw_log_path
      )
      agent.runs << run
      agent.structured_result = { "status" => "input_required", "summary" => "Needs input", "inquiry" => inquiry }
      inquiry_id = agent.send(:inquiry_identity, inquiry, run: run)
      memory = HQ::AgentMemory.new(agent)
      memory.append_assistant_message!("I need one decision before continuing.")
      memory.append_inquiry_request!(inquiry, created_at: run.finished_at, inquiry_id: inquiry_id)
      HQ::AgentStore.new(registry.projects).save([agent])

      active = HQ::AgentStore.new(registry.projects).load.find { |item| item.key == created[:key] }
      active.enqueue_prompt!(prompt: "Queued while inquiry is active")
      assert(!active.prompt_queue_dispatchable?, "expected an active inquiry to block queued prompt dispatch")
      history_before = client_a.conversation(created[:key])

      race_results = Queue.new
      [client_a, client_b].map do |client|
        Thread.new do
          begin
            client.dismiss_inquiry(created[:key], inquiry_id)
            race_results << :dismissed
          rescue HQ::RemoteServer::Error => e
            race_results << [e.status, e.message]
          end
        end
      end.each(&:join)
      outcomes = 2.times.map { race_results.pop }
      assert(outcomes.count(:dismissed) == 1 && outcomes.count { |outcome| outcome.is_a?(Array) && outcome.first == 409 } == 1,
             "expected concurrent dismissals to accept exactly one current-state transition: #{outcomes.inspect}")

      reloaded = client_b.agent(created[:key])
      assert(reloaded[:latest_inquiry].nil?, "expected dismissal to hide the active inquiry")
      assert(reloaded.dig(:suspended_inquiry, "id") == inquiry_id,
             "expected another client to reload the same restorable inquiry")
      suspended = HQ::AgentStore.new(registry.projects).load.find { |item| item.key == created[:key] }
      suspended.enqueue_prompt!(prompt: "Queued while inquiry is suspended")
      assert(!suspended.prompt_queue_dispatchable?, "expected a suspended inquiry to block queued prompt dispatch")
      assert(client_b.conversation(created[:key]) == history_before,
             "expected dismissal to preserve conversation history exactly")

      restored_route = HQ::RemoteServer.new.send(
        :route, client_b, "POST", "/agents/#{created[:key]}/inquiries/#{inquiry_id}/restore", {}, nil
      )
      assert(restored_route.dig(:body, :agent, :latest_inquiry, "id") == inquiry_id,
             "expected the restore API route to reactivate the same inquiry")
      assert(restored_route.dig(:body, :agent, :suspended_inquiry).nil?,
             "expected restore to clear the restorable payload")

      dismissed_route = HQ::RemoteServer.new.send(
        :route, client_a, "POST", "/agents/#{created[:key]}/inquiries/#{inquiry_id}/dismiss", {}, nil
      )
      assert(dismissed_route.dig(:body, :agent, :suspended_inquiry, "id") == inquiry_id,
             "expected the dismiss API route to persist restorable state")

      [nil, "another-inquiry"].each do |retire_id|
        begin
          attrs = { "prompt" => "Advance without answering", "start" => false }
          attrs["retire_inquiry_id"] = retire_id if retire_id
          client_b.submit_prompt(created[:key], attrs)
          raise "expected an unintended suspended inquiry retirement to fail"
        rescue HQ::RemoteServer::Error => e
          assert(e.status == 409, "expected stale ordinary prompt context to return conflict")
        end
      end

      retired = client_b.submit_prompt(
        created[:key],
        "prompt" => "Advance with the ordinary prompt",
        "retire_inquiry_id" => inquiry_id,
        "start" => false
      )
      assert(retired[:agent][:latest_inquiry].nil? && retired[:agent][:suspended_inquiry].nil?,
             "expected the intended ordinary prompt to retire the suspended inquiry")
      assert(retired[:conversation].first(history_before.length) == history_before,
             "expected retirement to preserve existing conversation history")
      assert(retired[:conversation].last[:content] == "Advance with the ordinary prompt",
             "expected retirement to append the ordinary prompt normally")

      after_reload = HQ::RemoteService.new(registry: registry).agent(created[:key])
      assert(after_reload[:latest_inquiry].nil? && after_reload[:suspended_inquiry].nil?,
             "expected retired inquiry state to remain retired after reload")
      events = HQ::AgentMemory.new(
        HQ::AgentStore.new(registry.projects).load.find { |item| item.key == created[:key] }
      ).events
      retired_event = events.reverse.find { |event| event["type"] == "inquiry_retired" }
      assert(retired_event.dig("metadata", "inquiry_id") == inquiry_id,
             "expected retirement to record only the intended suspended inquiry id")

      begin
        client_a.restore_inquiry(created[:key], inquiry_id)
        raise "expected retired inquiry restore to fail"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 409, "expected retired inquiry restore to be rejected")
      end
    end
  end

  def assert_remote_agent_payload_includes_attachments
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)
      created = service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Remote Agent",
        "prompt" => "Work remotely.",
        "agent" => "codex"
      )
      agent = HQ::AgentStore.new(registry.projects).load.find { |item| item.key == created[:key] }
      memory = HQ::AgentMemory.new(agent)
      FileUtils.mkdir_p(File.join(workspace, "docs"))
      FileUtils.mkdir_p(File.join(workspace, "assets"))
      release_path = File.join(workspace, "docs/release.txt")
      File.write(release_path, "Plain release checklist\n")
      File.write(File.join(workspace, "docs/notes.md"), "# Notes\n\n- Check attachment viewer\n")
      File.write(File.join(workspace, "assets/lesson.css"), "body { color: rgb(12, 34, 56); }\n")
      File.write(File.join(workspace, "assets/lesson.js"), "document.body.dataset.lessonReady = 'true';\n")
      File.write(File.join(workspace, "docs/private.txt"), "not a preview asset\n")
      File.write(
        File.join(workspace, "docs/lesson.html"),
        <<~HTML
          <!doctype html>
          <html>
            <head>
              <title>Tycho lesson</title>
              <link rel="stylesheet" href="../assets/lesson.css">
              <script src="../assets/lesson.js"></script>
            </head>
            <body>
              <h1>Interactive lesson</h1>
              <img src="private.txt" alt="">
            </body>
          </html>
        HTML
      )
      file_uri_notes_path = File.join(workspace, "docs/file-uri-notes.md")
      File.write(file_uri_notes_path, "# File URI Notes\n\n- Render this from a file URL\n")
      ruby_path = File.join(workspace, "scripts/runner.rb")
      js_path = File.join(workspace, "web/app.js")
      extensionless_path = File.join(workspace, "docs/README")
      binary_text_path = File.join(workspace, "docs/payload.txt")
      FileUtils.mkdir_p(File.dirname(ruby_path))
      FileUtils.mkdir_p(File.dirname(js_path))
      File.write(ruby_path, "puts \"plain Ruby attachment\"\n")
      File.write(js_path, "console.log(\"plain JavaScript attachment\");\n")
      File.write(extensionless_path, "Plain extensionless attachment\n")
      File.binwrite(binary_text_path, "\x00\x01tycho-binary-payload".b)
      image_path = File.join(workspace, "tmp/screenshot.png")
      image_bytes = Base64.decode64(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
      )
      FileUtils.mkdir_p(File.dirname(image_path))
      File.binwrite(image_path, image_bytes)
      memory.append_attachment!(
        {
          "kind" => "link",
          "title" => "Implementation PR",
          "url" => "https://github.com/example/web/pull/123",
          "description" => "Generated implementation PR."
        },
        created_at: Time.parse("2026-04-05 17:57:00")
      )
      memory.append_attachment!(
        {
          "kind" => "document",
          "title" => "Release checklist",
          "url" => File.join(workspace, "docs/release.txt")
        },
        created_at: Time.parse("2026-04-05 17:58:00")
      )
      memory.append_attachment!(
        {
          "kind" => "document",
          "title" => "Markdown notes",
          "url" => File.join(workspace, "docs/notes.md")
        },
        created_at: Time.parse("2026-04-05 17:58:30")
      )
      memory.append_attachment!(
        {
          "kind" => "document",
          "title" => "File URI notes",
          "url" => "file://#{file_uri_notes_path}"
        },
        created_at: Time.parse("2026-04-05 17:58:45")
      )
      memory.append_attachment!(
        {
          "kind" => "document",
          "title" => "HTML lesson",
          "url" => File.join(workspace, "docs/lesson.html")
        },
        created_at: Time.parse("2026-04-05 17:58:50")
      )
      memory.append_attachment!(
        {
          "kind" => "image",
          "title" => "UI screenshot",
          "url" => image_path
        },
        created_at: Time.parse("2026-04-05 17:59:00")
      )
      memory.append_attachment!(
        {
          "kind" => "document",
          "title" => "Ruby runner",
          "url" => ruby_path
        },
        created_at: Time.parse("2026-04-05 17:59:10")
      )
      memory.append_attachment!(
        {
          "kind" => "document",
          "title" => "JavaScript app",
          "url" => js_path
        },
        created_at: Time.parse("2026-04-05 17:59:15")
      )
      memory.append_attachment!(
        {
          "kind" => "document",
          "title" => "Extensionless notes",
          "url" => extensionless_path
        },
        created_at: Time.parse("2026-04-05 17:59:20")
      )
      memory.append_attachment!(
        {
          "kind" => "document",
          "title" => "Binary text name",
          "url" => binary_text_path
        },
        created_at: Time.parse("2026-04-05 17:59:30")
      )

      payload = service.agent(created[:key])
      attachments = payload[:attachments]
      assert(attachments.map { |item| item["title"] } == [
        "Binary text name",
        "Extensionless notes",
        "JavaScript app",
        "Ruby runner",
        "UI screenshot",
        "HTML lesson",
        "File URI notes",
        "Markdown notes",
        "Release checklist",
        "Implementation PR"
      ], "expected Remote agent payload to expose newest attachments first")
      assert(attachments.map { |item| item["type"] } == %w[file file file file file file file file file link],
             "expected Remote agent payload to expose normalized file/link attachments")
      assert(attachments.all? { |item| item["id"].to_s.length == 20 },
             "expected Remote agent payload to expose stable attachment IDs")
      assert(attachments.map { |item| item["title"] }.include?("Implementation PR"),
             "expected Remote agent payload to include attachment titles")
      assert(attachments.find { |item| item["title"] == "Release checklist" }["path"] == File.join(workspace, "docs/release.txt"),
             "expected local attachments to expose normalized paths")
      assert(!attachments.find { |item| item["title"] == "File URI notes" }.key?("url"),
             "expected file:// attachments to normalize away from URL")
      assert(attachments.find { |item| item["title"] == "Implementation PR" }["description"] == "Generated implementation PR.",
             "expected Remote agent payload to include attachment descriptions")
      list_payload = service.agents.find { |item| item[:key] == created[:key] }
      assert(list_payload[:attachments].length == 10,
             "expected Remote agents list payload to include attachments for detail rendering")
      assert(!list_payload[:updated_at].to_s.empty?,
             "expected Remote agents list payload to expose last update time for compact list metadata")
      ruby_attachment = service.attachment(attachments.find { |item| item["title"] == "Ruby runner" }["id"])
      assert(ruby_attachment["format"] == "text", "expected Ruby source attachments to render as plain text")
      assert(ruby_attachment["content"].include?("plain Ruby attachment"),
             "expected Ruby source attachment viewer content")
      js_attachment = service.attachment(attachments.find { |item| item["title"] == "JavaScript app" }["id"])
      assert(js_attachment["format"] == "text", "expected JavaScript source attachments to render as plain text")
      assert(js_attachment["content"].include?("plain JavaScript attachment"),
             "expected JavaScript source attachment viewer content")
      extensionless_attachment = service.attachment(attachments.find { |item| item["title"] == "Extensionless notes" }["id"])
      assert(extensionless_attachment["format"] == "text",
             "expected extensionless plain text attachments to render as plain text")
      assert(extensionless_attachment["content"].include?("Plain extensionless attachment"),
             "expected extensionless plain text attachment viewer content")
      binary_text_attachment = service.attachment(attachments.find { |item| item["title"] == "Binary text name" }["id"])
      assert(binary_text_attachment["format"] == "binary",
             "expected binary attachments to stay download-only even with a text extension")
      assert(!binary_text_attachment.key?("content"),
             "expected binary attachments not to expose preview content")
      plain_attachment = service.attachment(attachments.find { |item| item["title"] == "Release checklist" }["id"])
      assert(plain_attachment["format"] == "text", "expected txt documents to render as plain text")
      assert(plain_attachment["content"].include?("Plain release checklist"),
             "expected plain text attachment viewer content")
      assert(!plain_attachment["content_mtime"].to_s.empty?,
             "expected file attachments to expose source freshness metadata")
      FileUtils.touch(release_path, mtime: Time.now + 120)
      newer_plain = service.agent(created[:key])[:attachments].find { |item| item["id"] == plain_attachment["id"] }
      assert(newer_plain["content_mtime"] != plain_attachment["content_mtime"],
             "expected agent attachment payloads to show when source files are newer than cached previews")
      original_release_content = File.read(release_path)
      File.write(release_path, "Updated release checklist\n")
      refreshed_plain = service.attachment(plain_attachment["id"])
      assert(refreshed_plain["content"].include?("Updated release checklist"),
             "expected a refreshed attachment payload to re-read content from its source path")
      File.write(release_path, original_release_content)
      markdown_attachment = service.attachment(attachments.find { |item| item["title"] == "Markdown notes" }["id"])
      assert(markdown_attachment["format"] == "markdown", "expected markdown documents to be marked for markdown rendering")
      assert(markdown_attachment["content"].include?("# Notes"), "expected markdown attachment content")
      file_uri_attachment = service.attachment(attachments.find { |item| item["title"] == "File URI notes" }["id"])
      assert(file_uri_attachment["format"] == "markdown",
             "expected file URI markdown documents to be marked for markdown rendering")
      assert(file_uri_attachment["content"].include?("# File URI Notes"),
             "expected file URI markdown attachment content")
      html_attachment = service.attachment(attachments.find { |item| item["title"] == "HTML lesson" }["id"])
      assert(html_attachment["format"] == "html", "expected HTML documents to be marked for sandboxed HTML rendering")
      assert(html_attachment["content"].include?("<h1>Interactive lesson</h1>"),
             "expected HTML attachment content")
      assert(html_attachment.dig("preview_assets", "../assets/lesson.css").start_with?("data:text/css;base64,"),
             "expected referenced workspace CSS to be packaged for the sandboxed preview")
      assert(html_attachment.dig("preview_assets", "../assets/lesson.js").start_with?("data:application/javascript;base64,"),
             "expected referenced workspace JavaScript to be packaged for the sandboxed preview")
      assert(!html_attachment.fetch("preview_assets").key?("private.txt"),
             "expected non-web workspace files to stay outside the HTML preview package")
      link_attachment = service.attachment(attachments.find { |item| item["title"] == "Implementation PR" }["id"])
      assert(!link_attachment.key?("content"), "expected link attachments to skip local file content")
      image_attachment = service.attachment(attachments.find { |item| item["title"] == "UI screenshot" }["id"])
      assert(image_attachment["format"] == "image", "expected image attachments to be marked as images")
      assert(image_attachment["blob_path"].end_with?("/blob"), "expected image attachments to expose a blob route")
      image_blob = service.attachment_blob(image_attachment["id"])
      assert(image_blob[:content_type] == "image/png", "expected image blob route to preserve image MIME type")
      assert(image_blob.dig(:headers, "Content-Disposition").include?('filename="screenshot.png"'),
             "expected image blob route to expose a download filename")
      assert(image_blob.dig(:headers, "X-Content-Type-Options") == "nosniff",
             "expected image blob route to prevent MIME sniffing")
      assert(image_blob[:body].bytes.first(8) == image_bytes.bytes.first(8),
             "expected image blob route to stream the local image bytes")
      server = HQ::RemoteServer.new(logger: Logger.new(StringIO.new), output: StringIO.new)
      routed = server.send(:route, service, "GET", "/attachments/#{plain_attachment["id"]}", {}, nil)
      assert(routed.dig(:body, :attachment, "content").include?("Plain release checklist"),
             "expected attachment content to be reachable through the Remote API route")
      routed_blob = server.send(:route, service, "GET", "/attachments/#{image_attachment["id"]}/blob", {}, nil)
      assert(routed_blob[:content_type] == "image/png",
             "expected image blobs to be reachable through the Remote API route")
      revision_before = payload[:revision].to_s
      FileUtils.touch(agent.attachments_path, mtime: Time.now + 60)
      revision_after = service.agent(created[:key])[:revision].to_s
      assert(revision_after != revision_before,
             "expected Remote agent revision to track attachment sidecar changes")
      deleted = server.send(:route, service, "DELETE", "/attachments/#{plain_attachment["id"]}", {}, nil)
      assert(deleted.dig(:body, :deleted), "expected attachment delete route to report deletion")
      remaining_titles = deleted.dig(:body, :agent, :attachments).map { |attachment| attachment["title"] }
      assert(!remaining_titles.include?("Release checklist"),
             "expected deleted attachments to disappear from the agent payload")
      begin
        service.attachment(plain_attachment["id"])
        raise "expected deleted attachment to be unavailable"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 404, "expected deleted attachment lookup to return not found")
      end
    end
  end

  def assert_remote_agent_pull_request_diff_payload
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(
        registry: registry,
        github_client: FakeUnavailableGitHubClient.new
      )
      server = HQ::RemoteServer.new
      created = service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Remote Agent",
        "prompt" => "Work remotely.",
        "agent" => "codex"
      )
      agent = HQ::AgentStore.new(registry.projects).load.find { |item| item.key == created[:key] }
      memory = HQ::AgentMemory.new(agent)
      memory.append_attachment!(
        {
          "kind" => "pull_request",
          "title" => "Example PR",
          "url" => "https://github.com/example/web/pull/123",
          "description" => "Generated review."
        },
        created_at: Time.parse("2026-04-05 17:57:00")
      )
      memory.append_attachment!(
        {
          "kind" => "link",
          "title" => "Duplicate PR",
          "url" => "https://github.com/example/web/pull/123/files"
        },
        created_at: Time.parse("2026-04-05 17:58:00")
      )

      payload = service.agent_pull_requests(created[:key])
      assert(payload.length == 1, "expected duplicate PR URLs to collapse into one reference")
      reference = payload.first
      assert(reference["repository"] == "example/web", "expected GitHub repository to be parsed")
      assert(reference["number"] == 123, "expected GitHub PR number to be parsed")
      assert(reference["error"].nil?, "expected ordinary PR listing to avoid unavailable GitHub metadata")
      metadata_refresh = service.refresh_agent_pull_request_metadata(created[:key])
      assert(metadata_refresh[:failed].length == 1,
             "expected explicit metadata refresh errors to be reported without hiding PR references")

      snapshot = {
        "id" => reference["id"],
        "agent_key" => created[:key],
        "provider" => "github",
        "repository" => "example/web",
        "number" => 123,
        "url" => "https://github.com/example/web/pull/123",
        "title" => "Origin PR title",
        "state" => "open",
        "draft" => true,
        "head_sha" => "abc1234",
        "base_sha" => "def5678",
        "fetched_at" => Time.now.iso8601,
        "diff_format" => HQ::PullRequestDiff::DIFF_FORMAT,
        "files" => [
          {
            "path" => "lib/example.rb",
            "status" => "modified",
            "binary" => false,
            "additions" => 1,
            "deletions" => 0,
            "hunks" => []
          }
        ],
        "file_count" => 1,
        "additions" => 1,
        "deletions" => 0,
        "truncated" => false
      }
      HQ::PullRequestDiff::Store.new.save(snapshot)

      listed_from_snapshot = service.agent_pull_requests(created[:key]).first
      assert(listed_from_snapshot["title"] == "Origin PR title" &&
             listed_from_snapshot["state"] == "open" && listed_from_snapshot["draft"] == true,
             "expected saved origin metadata to backfill the agent PR catalog and listing")
      assert(!listed_from_snapshot.fetch("snapshot").key?("fresh"),
             "expected snapshot-seeded metadata to leave remote freshness unknown")

      diff = service.agent_pull_request_diff(created[:key], reference["id"])
      assert(diff["files"].first["path"] == "lib/example.rb", "expected saved PR diff snapshot to be returned")

      routed = server.send(:route, service, "GET",
                           "/agents/#{created[:key]}/pull-requests/#{reference["id"]}/diff", {}, nil)
      assert(routed.dig(:body, :diff, "file_count") == 1, "expected PR diff route to return saved snapshots")
    end
  end

  def assert_agent_pull_request_listing_avoids_eager_metadata_requests
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      client = FakeGitHubReviewClient.new
      snapshot_store = CountingPullRequestDiffStore.new(File.join(dir, "diffs.json"))
      service = HQ::RemoteService.new(registry:, github_client: client, pull_request_diff_store: snapshot_store)
      created = service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Many pull requests",
        "prompt" => "Review pull requests.",
        "agent" => "codex"
      )
      agent = HQ::AgentStore.new(registry.projects).load.find { |item| item.key == created[:key] }
      memory = HQ::AgentMemory.new(agent)
      3.times do |index|
        memory.append_attachment!(
          {
            "kind" => "link",
            "title" => "PR #{index + 1}",
            "url" => "https://github.com/example/web/pull/#{index + 1}"
          },
          created_at: Time.parse("2026-08-09 13:00:0#{index}")
        )
      end

      listed = service.agent_pull_requests(created[:key])
      metadata_requests = client.requests.count { |kind, path| kind == :get_json && path.include?("/pulls/") }

      assert(listed.length == 3, "expected every attached pull request to be listed")
      assert(metadata_requests.zero?,
             "expected ordinary PR listing to avoid one blocking GitHub metadata request per pull request")
      assert(snapshot_store.all_calls == 1,
             "expected ordinary PR listing to parse the shared diff snapshot store only once")

      server = HQ::RemoteServer.new
      response = server.send(
        :route,
        service,
        "POST",
        "/agents/#{created[:key]}/pull-requests/metadata/refresh",
        {},
        nil
      )
      refreshed = response[:body]
      metadata_requests = client.requests.count { |kind, path| kind == :get_json && path.include?("/pulls/") }
      assert(metadata_requests == 3, "expected explicit metadata refresh to request each pull request once")
      assert(refreshed[:pull_requests].all? { |item| item["title"] == "Shared PR" },
             "expected refreshed GitHub metadata to be returned from the persistent catalog")
      assert(refreshed[:pull_requests].all? { |item| item["metadata_refreshed_at"].to_s.length.positive? },
             "expected cached PR metadata to expose its refresh time")
      catalog = JSON.parse(File.read(agent.pull_request_catalog_path))
      assert(catalog.fetch("entries").length == 3,
             "expected newly discovered pull requests to be persisted in the agent-owned PR catalog")
      assert(!File.exist?(File.join(HQ::AGENT_LOGS_DIR, "pull_request_catalog.json")),
             "expected agent PR listing to avoid a shared cross-agent catalog")

      second_created = service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Other pull requests",
        "prompt" => "Review another list.",
        "agent" => "codex"
      )
      second_agent = HQ::AgentStore.new(registry.projects).load.find { |item| item.key == second_created[:key] }
      HQ::AgentMemory.new(second_agent).append_attachment!(
        {
          "kind" => "link",
          "title" => "Other PR",
          "url" => "https://github.com/other/repository/pull/99"
        },
        created_at: Time.parse("2026-08-09 13:01:00")
      )
      requests_before_second_list = client.requests.length
      second_list = service.agent_pull_requests(second_created[:key])
      second_catalog = JSON.parse(File.read(second_agent.pull_request_catalog_path))
      assert(second_list.length == 1 && client.requests.length == requests_before_second_list,
             "expected another agent's PR list to remain network-free")
      assert(second_agent.pull_request_catalog_path != agent.pull_request_catalog_path,
             "expected each agent to own a distinct PR catalog path")
      assert(second_catalog.fetch("entries").length == 1 && catalog.fetch("entries").length == 3,
             "expected one agent's PR discovery to stay isolated from every other catalog")

      restarted = HQ::RemoteService.new(registry:, github_client: FakeUnavailableGitHubClient.new)
      cached = restarted.agent_pull_requests(created[:key])
      assert(cached.length == 3 && cached.all? { |item| item["title"] == "Shared PR" },
             "expected PR references and metadata to survive a Remote server restart")

      catalog_paths = [
        agent.pull_request_catalog_path,
        "#{agent.pull_request_catalog_path}.bak",
        "#{agent.pull_request_catalog_path}.lock"
      ]
      archive = agent.archive_logs!(File.join(dir, "archive"))
      assert(catalog_paths.all? { |path| File.exist?(File.join(archive, File.basename(path))) },
             "expected agent archive to move the PR catalog, backup, and lock sidecars")
      assert(catalog_paths.none? { |path| File.exist?(path) },
             "expected agent archive to leave no active PR catalog sidecars behind")
    end
  end

  def assert_concurrent_pull_request_diff_refreshes_are_coalesced
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      client = BlockingGitHubDiffClient.new
      registry = registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(
        registry:,
        github_client: client,
        pull_request_diff_store: HQ::PullRequestDiff::Store.new(File.join(dir, "diffs.json"))
      )
      agents = 2.times.map do |index|
        created = service.create_agent(
          "project_key" => "web",
          "template_key" => "custom",
          "name" => "Shared PR agent #{index + 1}",
          "prompt" => "Review the shared PR.",
          "agent" => "codex"
        )
        agent = HQ::AgentStore.new(registry.projects).load.find { |item| item.key == created[:key] }
        HQ::AgentMemory.new(agent).append_attachment!(
          {
            "kind" => "link",
            "title" => "Shared PR",
            "url" => "https://github.com/example/web/pull/123"
          },
          created_at: Time.parse("2026-08-09 13:02:0#{index}")
        )
        agent
      end
      references = agents.map { |agent| HQ::PullRequestDiff.references_for_agent(agent).fetch(0) }
      first = Thread.new { service.send(:refresh_pull_request_snapshot, references.fetch(0)) }
      client.metadata_started.pop
      second = Thread.new { service.send(:refresh_pull_request_snapshot, references.fetch(1)) }

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      Thread.pass until second.status == "sleep" || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      follower_waiting = second.status == "sleep"

      client.release!
      [first, second].each(&:value)

      assert(follower_waiting, "expected the second agent refresh to join the in-flight PR fetch")
      assert(client.metadata_requests == 1 && client.diff_requests == 1,
             "expected concurrent identical diff refreshes to share one metadata and diff fetch")
      catalogs = agents.map { |agent| JSON.parse(File.read(agent.pull_request_catalog_path)) }
      assert(catalogs.all? { |catalog| catalog.dig("entries", references.first.id, "metadata", "title") == "Shared PR" },
             "expected every coalesced caller to persist metadata in its own agent catalog")
    end
  end

  def assert_pull_request_review_refresh_reuses_metadata
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      client = FakeGitHubReviewClient.new
      service = HQ::RemoteService.new(
        registry: registry_for_project(dir, workspace),
        github_client: client,
        pull_request_diff_store: HQ::PullRequestDiff::Store.new(File.join(dir, "diffs.json"))
      )
      reference = HQ::PullRequestDiff.reference_from_url("https://github.com/example/web/pull/123")
      refreshed = service.send(:refresh_pull_request_fetch, reference)

      detail_requests = client.requests.count { |kind, path| kind == :get_json && path.end_with?("/pulls/123") }
      assert(detail_requests == 1, "expected review refresh to reuse the PR metadata fetched for its diff")
      assert(refreshed.dig(:context, "head_sha") == "head", "expected reused PR metadata to preserve review context")
    end
  end

  def assert_pull_request_feature_gate_and_global_inbox
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      disabled = HQ::RemoteService.new(
        registry: registry,
        github_client: HQ::GitHubAPIClient.new(token: ""),
        pull_request_diff_store: HQ::PullRequestDiff::Store.new(File.join(dir, "disabled-diffs.json")),
        pull_request_review_store: HQ::PullRequestReview::Store.new(File.join(dir, "disabled-reviews.json"))
      )
      assert(disabled.setup.dig(:github, :enabled) == false, "expected setup to report GitHub disabled without credentials")
      begin
        disabled.pull_request_inbox
        raise "expected disabled PR route to fail closed"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 424 && e.message.include?("GitHub App"),
               "expected one stable integration-not-configured response")
      end

      client = FakeGitHubReviewClient.new
      review_store = HQ::PullRequestReview::Store.new(File.join(dir, "reviews.json"))
      service = HQ::RemoteService.new(
        registry: registry,
        github_client: client,
        pull_request_diff_store: HQ::PullRequestDiff::Store.new(File.join(dir, "diffs.json")),
        pull_request_review_store: review_store
      )
      first = service.create_agent(
        "project_key" => "web", "template_key" => "custom", "name" => "First",
        "prompt" => "Review.", "agent" => "codex"
      )
      second = service.create_agent(
        "project_key" => "web", "template_key" => "custom", "name" => "Second",
        "prompt" => "Review.", "agent" => "codex"
      )
      agents = HQ::AgentStore.new(registry.projects).load
      agents.each do |agent|
        HQ::AgentMemory.new(agent).append_attachment!(
          { "kind" => "link", "title" => "Shared PR", "url" => "https://github.com/example/web/pull/123" }
        )
      end

      inbox = service.pull_request_inbox
      assert(inbox.length == 1, "expected project and cross-agent references to deduplicate globally")
      sources = inbox.first["occurrences"]
      assert(sources.any? { |source| source["agent_key"] == first[:key] } &&
             sources.any? { |source| source["agent_key"] == second[:key] } &&
             sources.any? { |source| source["project_key"] == "web" },
             "expected canonical PR to preserve every agent and project occurrence")
      assert(client.requests.none? { |request| request.first == :get_text },
             "expected inbox metadata work not to fetch patches")
    end
  end

  def assert_pull_request_line_handoff_uses_snapshot_context
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      diff_store = HQ::PullRequestDiff::Store.new(File.join(dir, "handoff-diffs.json"))
      service = HQ::RemoteService.new(registry:, github_client: FakeGitHubReviewClient.new, pull_request_diff_store: diff_store,
                                      pull_request_review_store: HQ::PullRequestReview::Store.new(File.join(dir, "handoff-reviews.json")))
      created = service.create_agent("project_key" => "web", "template_key" => "custom", "name" => "Recipient", "prompt" => "Work.", "agent" => "codex")
      agent = HQ::AgentStore.new(registry.projects).load.find { |item| item.key == created[:key] }
      HQ::AgentMemory.new(agent).append_attachment!({ "kind" => "link", "title" => "PR", "url" => "https://github.com/example/web/pull/123" })
      HQ::AgentStore.new(registry.projects).save([agent])
      reference = HQ::PullRequestDiff.reference_from_url("https://github.com/example/web/pull/123")
      diff_store.save(
        "id" => reference.id, "snapshot_id" => "snapshot-1", "provider" => "github", "repository" => "example/web", "number" => 123,
        "base_sha" => "base", "head_sha" => "head", "diff_format" => HQ::PullRequestDiff::DIFF_FORMAT,
        "files" => [{ "path" => "lib/example.rb", "hunks" => [{ "lines" => [{ "kind" => "added", "new_number" => 4, "content" => "puts :ok" }] }] }]
      )
      persisted = service.update_pull_request_review_state(
        reference.id,
        "selection_snapshot_id" => "snapshot-1",
        "selections" => { "lines" => [{ "path" => "lib/example.rb", "hunk_index" => 0, "line_index" => 0 }] }
      )
      assert(persisted.dig("selections", "lines", 0, "path") == "lib/example.rb",
             "expected valid selected lines to persist with the sibling snapshot id contract")
      begin
        service.update_pull_request_review_state(reference.id, "selection_snapshot_id" => "old", "selections" => { "lines" => [] })
        raise "expected stale selected line state to fail"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 409, "expected stale selected line state to return conflict")
      end
      begin
        service.update_pull_request_review_state(reference.id, "selection_snapshot_id" => "snapshot-1", "selections" => [])
        raise "expected malformed selected line state to fail"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 400, "expected malformed selected line state to return bad request")
      end
      result = service.handoff_pull_request_review(reference.id, "agent_key" => created[:key], "note" => "Inspect this.", "start" => false, "idempotency_key" => "line-handoff-1",
                                                    "selection" => { "snapshot_id" => "snapshot-1", "lines" => [{ "path" => "lib/example.rb", "hunk_index" => 0, "line_index" => 0 }] })
      content = result[:conversation].last[:content]
      assert(content.include?("Inspect this.") && content.include?(HQ::PullRequestSelection::OPEN) && content.include?("https://github.com/example/web/pull/123"),
             "expected handoff to append bounded immutable line context through the normal user-message flow")
      begin
        service.handoff_pull_request_review(reference.id, "agent_key" => created[:key], "note" => "Retry", "start" => false, "idempotency_key" => "line-handoff-stale",
                                            "selection" => { "snapshot_id" => "old", "lines" => [{ "path" => "lib/example.rb", "hunk_index" => 0, "line_index" => 0 }] })
        raise "expected stale line selection to fail"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 409, "expected stale selected lines to be rejected")
      end
      retry_result = service.handoff_pull_request_review(reference.id, "agent_key" => created[:key], "note" => "Ignored", "start" => false, "idempotency_key" => "line-handoff-1",
                                                          "selection" => { "snapshot_id" => "snapshot-1", "lines" => [{ "path" => "lib/example.rb", "hunk_index" => 0, "line_index" => 0 }] })
      assert(retry_result[:idempotent] == true, "expected an idempotent handoff retry")
    end
  end

  def assert_remote_prompt_accepts_pull_request_context
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      diff_store = HQ::PullRequestDiff::Store.new(File.join(dir, "composer-diffs.json"))
      service = HQ::RemoteService.new(registry:, github_client: FakeGitHubReviewClient.new,
                                      pull_request_diff_store: diff_store)
      created = service.create_agent("project_key" => "web", "template_key" => "custom", "name" => "Composer",
                                     "prompt" => "Work.", "agent" => "codex")
      agent = HQ::AgentStore.new(registry.projects).load.find { |item| item.key == created[:key] }
      HQ::AgentMemory.new(agent).append_attachment!(
        { "kind" => "link", "title" => "PR", "url" => "https://github.com/example/web/pull/123" }
      )
      HQ::AgentStore.new(registry.projects).save([agent])
      reference = HQ::PullRequestDiff.reference_from_url("https://github.com/example/web/pull/123")
      diff_store.save(
        "id" => reference.id, "snapshot_id" => "composer-snapshot", "provider" => "github",
        "repository" => "example/web", "number" => 123, "base_sha" => "base", "head_sha" => "head",
        "diff_format" => HQ::PullRequestDiff::DIFF_FORMAT,
        "files" => [{ "path" => "lib/example.rb", "hunks" => [{ "lines" => [
          { "kind" => "removed", "old_number" => 3, "content" => "old" },
          { "kind" => "added", "new_number" => 4, "content" => "new" }
        ] }] }]
      )

      result = service.submit_prompt(created[:key],
                                     "prompt" => "Explain this range.",
                                     "pull_request_contexts" => [{
                                       "pull_request_id" => reference.id,
                                       "snapshot_id" => "composer-snapshot",
                                       "comment" => "Explain why these two sides differ.",
                                       "lines" => [
                                         { "path" => "lib/example.rb", "hunk_index" => 0, "line_index" => 0 },
                                         { "path" => "lib/example.rb", "hunk_index" => 0, "line_index" => 1 }
                                       ]
                                     }])
      content = result[:conversation].last[:content]
      assert(content.start_with?("Explain this range.") && content.include?(HQ::PullRequestSelection::OPEN),
             "expected normal composer messages to include validated PR context")
      assert(content.include?('"path":"lib/example.rb"') && content.include?('"side":"left"') &&
             content.include?('"side":"right"') && content.include?('"old_number":3') &&
             content.include?('"new_number":4') &&
             content.include?("Comment on this range:\nExplain why these two sides differ."),
             "expected PR context to carry repository file, side, and line metadata")

      begin
        service.submit_prompt(created[:key],
                              "prompt" => "Oversized comment.",
                              "pull_request_contexts" => [{
                                "pull_request_id" => reference.id, "snapshot_id" => "composer-snapshot",
                                "comment" => "x" * ((8 * 1024) + 1),
                                "lines" => [{ "path" => "lib/example.rb", "hunk_index" => 0, "line_index" => 0 }]
                              }])
        raise "expected oversized PR comment to fail"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 400 && e.message.include?("at most 8 KB"),
               "expected oversized PR comments to return a bounded input error")
      end

      begin
        asset_pattern = File.join(HQ::AGENT_LOGS_DIR, "assets", created[:key], "**", "*")
        asset_files_before = Dir.glob(asset_pattern).select { |path| File.file?(path) }
        service.submit_prompt(created[:key],
                              "prompt" => "Stale.",
                              "attachments" => [{
                                "filename" => "stale.txt", "mime_type" => "text/plain",
                                "content_base64" => Base64.strict_encode64("must not be imported")
                              }],
                              "pull_request_contexts" => [{
                                "pull_request_id" => reference.id, "snapshot_id" => "old",
                                "lines" => [{ "path" => "lib/example.rb", "hunk_index" => 0, "line_index" => 0 }]
                              }])
        raise "expected stale composer PR context to fail"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 409 && e.message.include?("changed"),
               "expected stale composer PR context to return an actionable conflict")
        asset_files_after = Dir.glob(asset_pattern).select { |path| File.file?(path) }
        assert(asset_files_after == asset_files_before,
               "expected stale PR context validation to happen before uploaded files are written")
      end
    end
  end

  def assert_github_app_auth_routes
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      client = FakeGitHubAuthClient.new
      service = HQ::RemoteService.new(
        registry: registry_for_project(dir, workspace),
        github_client: client
      )
      server = HQ::RemoteServer.new

      started = server.send(:route, service, "POST", "/github/auth/device", {}, nil)
      assert(started[:status] == 202 && started.dig(:body, :github, :user_code) == "ABCD-EFGH",
             "expected the GitHub device route to return only public authorization fields")

      polled = server.send(:route, service, "POST", "/github/auth/device/login-id/poll", {}, nil)
      assert(polled.dig(:body, :github, :status) == "authenticated",
             "expected the GitHub device poll route to complete login")

      logged_out = server.send(:route, service, "DELETE", "/github/auth", {}, nil)
      assert(logged_out.dig(:body, :github, :source) == "gh",
             "expected App logout to preserve the reported gh compatibility source")
    end
  end

  def assert_pull_request_posting_is_confirmed_stale_safe_and_idempotent
    with_remote_temp_store do |dir|
      with_env_values("TYCHO_GITHUB_WRITE_ENABLED" => "true") do
        workspace = File.join(dir, "workspace")
        write_project_workspace(workspace)
        registry = registry_for_project(dir, workspace)
        client = FakeGitHubReviewClient.new
        diff_store = HQ::PullRequestDiff::Store.new(File.join(dir, "posting-diffs.json"))
        review_store = HQ::PullRequestReview::Store.new(File.join(dir, "posting-reviews.json"))
        service = HQ::RemoteService.new(
          registry: registry,
          github_client: client,
          pull_request_diff_store: diff_store,
          pull_request_review_store: review_store
        )
        reference = HQ::PullRequestDiff.reference_from_url("https://github.com/example/web/pull/123")
        snapshot = {
          "id" => reference.id,
          "snapshot_id" => "snapshot-1",
          "provider" => "github",
          "repository" => "example/web",
          "number" => 123,
          "base_sha" => "base",
          "head_sha" => "head",
          "fetched_at" => Time.now.iso8601,
          "diff_format" => HQ::PullRequestDiff::DIFF_FORMAT,
          "files" => []
        }
        diff_store.save(snapshot)
        service.save_pull_request_review_draft(
          reference.id,
          "event" => "APPROVE",
          "body" => "Looks good.",
          "comments" => []
        )

        begin
          service.post_pull_request_review(reference.id, "confirm" => false, "idempotency_key" => "review-1")
          raise "expected unconfirmed posting to fail"
        rescue HQ::RemoteServer::Error => e
          assert(e.status == 409, "expected a second confirmation before GitHub mutation")
        end

        client.head_sha = "force-pushed"
        begin
          service.post_pull_request_review(reference.id, "confirm" => true, "idempotency_key" => "review-1")
          raise "expected stale draft to fail"
        rescue HQ::RemoteServer::Error => e
          assert(e.status == 409 && e.message.include?("changed"), "expected stale head to block posting")
        end

        client.head_sha = "head"
        first = service.post_pull_request_review(reference.id, "confirm" => true, "idempotency_key" => "review-1")
        second = service.post_pull_request_review(reference.id, "confirm" => true, "idempotency_key" => "review-1")
        assert(first[:posted]["id"] == 9001 && second[:idempotent] == true,
               "expected a recorded idempotency key to return the first outcome")
        assert(client.review_posts == 1, "expected an idempotent retry not to duplicate the GitHub review")
      end
    end
  end

  def assert_remote_prompt_accepts_uploaded_attachments
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)
      created = service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Remote Agent",
        "prompt" => "Work remotely.",
        "agent" => "codex"
      )
      image_bytes = Base64.decode64(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
      )
      notes = "# Prompt Notes\n\nUse this as uploaded context.\n"
      binary_bytes = "\x00\x01tycho-binary-payload".b

      result = service.submit_prompt(
        created[:key],
        "prompt" => "Review the uploaded context.",
        "attachments" => [
          {
            "filename" => "screenshot.png",
            "mime_type" => "image/png",
            "kind" => "image",
            "content_base64" => Base64.strict_encode64(image_bytes)
          },
          {
            "filename" => "prompt-notes.md",
            "mime_type" => "text/markdown",
            "kind" => "document",
            "content_base64" => Base64.strict_encode64(notes)
          },
          {
            "filename" => "payload.custom",
            "mime_type" => "application/octet-stream",
            "content_base64" => Base64.strict_encode64(binary_bytes)
          }
        ]
      )

      uploads = result[:agent][:attachments].select { |attachment| attachment["source"] == "remote_upload" }
      assert(uploads.length == 3, "expected uploaded prompt attachments in the agent payload")
      assert(uploads.all? { |attachment| attachment["id"].start_with?("att_") },
             "expected uploaded prompt attachments to keep generated IDs")
      assert(uploads.all? { |attachment| attachment["type"] == "file" },
             "expected uploaded prompt attachments to use file attachment type")
      assert(uploads.all? { |attachment| attachment["path"].start_with?("/") },
             "expected uploaded prompt attachments to use absolute local file paths")
      assert(uploads.all? { |attachment| File.file?(attachment["path"]) },
             "expected uploaded prompt attachments to be written under the agent asset store")
      conversation_message = result[:conversation].find { |block| block[:kind] == "message" && block[:role] == "user" }
      assert(conversation_message.dig(:metadata, "attachments").length == 3,
             "expected conversation messages to expose uploaded attachment metadata")

      document = service.attachment(uploads.find { |item| item["title"] == "prompt-notes.md" }["id"])
      assert(document["content"].include?("Prompt Notes"), "expected uploaded markdown document preview")
      image = service.attachment(uploads.find { |item| item["title"] == "screenshot.png" }["id"])
      assert(image["blob_path"].end_with?("/blob"), "expected uploaded image to expose a blob path")
      blob = service.attachment_blob(image["id"])
      assert(blob[:body] == image_bytes, "expected uploaded image blob to be served unchanged")
      binary = service.attachment(uploads.find { |item| item["title"] == "payload.custom" }["id"])
      assert(binary["format"] == "binary", "expected arbitrary uploaded files to use download-only binary handling")
      assert(!binary.key?("content"), "expected arbitrary binary uploads not to expose preview content")
      binary_blob = service.attachment_blob(binary["id"])
      assert(binary_blob[:body] == binary_bytes, "expected arbitrary uploaded file blobs to be served unchanged")

      saved_agent = HQ::AgentStore.new(registry.projects).load.find { |agent| agent.key == created[:key] }
      prompt_context = HQ::AgentMemory.new(saved_agent).latest_user_message_after(Time.at(0))
      assert(prompt_context.include?("Attachments are available as files or links"),
             "expected resume prompt context to list local file attachments")
      assert(prompt_context.include?("prompt-notes.md"), "expected resume prompt context to name uploaded documents")

      upload_only = service.submit_prompt(
        created[:key],
        "attachments" => [
          {
            "filename" => "followup.txt",
            "mime_type" => "text/plain",
            "kind" => "document",
            "content_base64" => Base64.strict_encode64("Follow-up context\n")
          }
        ]
      )
      upload_only_message = upload_only[:conversation].reverse.find do |block|
        next false unless block[:kind] == "message" && block[:role] == "user"

        Array(block.dig(:metadata, "attachments")).any? { |attachment| attachment["title"] == "followup.txt" }
      end
      assert(upload_only_message, "expected attachment-only submissions to create a user message")
      assert(upload_only_message[:content] == "Please review the attached files.",
             "expected attachment-only submissions to use the upload review prompt")

      uploaded_document_path = document["path"]
      delete_upload = service.delete_attachment(document["id"])
      assert(delete_upload[:deleted], "expected uploaded attachment deletion to succeed")
      assert(!File.exist?(uploaded_document_path),
             "expected deleting a remote-upload attachment to remove its cached asset file")
      remaining_upload_titles = delete_upload.dig(:agent, :attachments).map { |attachment| attachment["title"] }
      assert(!remaining_upload_titles.include?("prompt-notes.md"),
             "expected deleted uploaded attachments to disappear from the agent payload")

      begin
        service.submit_prompt(
          created[:key],
          "prompt" => "Bad upload",
          "attachments" => [
            {
              "filename" => "payload.exe",
              "mime_type" => "application/octet-stream",
              "content_base64" => "not valid base64"
            }
          ]
        )
        raise "expected invalid uploads to fail"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 400, "expected invalid uploads to return a bad request")
      end
    end
  end

  def assert_remote_prompt_start_accepts_dash_prefixed_message
    old_codex_bin = ENV["TYCHO_CODEX_BIN"]
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      fake_codex = File.join(dir, "fake-codex")
      argv_path = File.join(dir, "codex-argv.json")
      File.write(fake_codex, <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        File.write(#{argv_path.dump}, JSON.generate(ARGV))
        if ARGV.include?("--")
          output_index = ARGV.index("-o")
          if output_index
            File.write(ARGV[output_index + 1], JSON.generate(
              "status" => "success",
              "summary" => "Prompt accepted.",
              "summary_sections" => nil,
              "inquiry" => nil,
              "attachments" => nil,
              "memory_handoff" => nil
            ))
          end
          exit 0
        end

        prompt = ARGV.reverse.find { |argument| argument.include?("inquiry reply") }
        if prompt&.start_with?("-")
          warn "error: unexpected argument " + prompt.inspect
          warn "For more information, try '--help'."
          exit 2
        end
      RUBY
      File.chmod(0o755, fake_codex)
      ENV["TYCHO_CODEX_BIN"] = fake_codex

      registry = registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)
      created = service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Remote Agent",
        "prompt" => "Work remotely.",
        "agent" => "codex"
      )
      store = HQ::AgentStore.new(registry.projects)
      agents = store.load
      seeded = agents.find { |agent| agent.key == created[:key] }
      seeded.instance_variable_set(:@session_id, "codex-session-123")
      seeded.runs << HQ::ManagedAgent::AgentRun.new(
        started_at: Time.now - 120,
        finished_at: Time.now - 90,
        exit_code: 0,
        status: "success",
        log_path: seeded.raw_log_path,
        command: "codex exec"
      )
      store.save(agents)

      message = <<~PROMPT.chomp
        - instead of "inquiry reply" use "user answers"
        - make the header right aligned like in user chat block
        - use header-style all-caps keys and humanize "the_key_name" -> "THE KEY NAME"
        - make the answers italic
      PROMPT

      service.submit_prompt(created[:key], "prompt" => message, "start" => true)
      result = wait_for_agent_terminal_status(service, created[:key])
      argv = JSON.parse(File.read(argv_path))
      prompt_argument = argv.find { |argument| argument.include?("inquiry reply") }
      prompt_index = argv.index(prompt_argument)

      assert(result[:status] == "succeeded",
             "expected dash-prefixed Remote UI prompt to start successfully, got #{result[:status].inspect}")
      assert(prompt_index && argv[prompt_index - 1] == "--",
             "expected Codex prompt to be separated from CLI options, got #{argv.inspect}")
    ensure
      if old_codex_bin
        ENV["TYCHO_CODEX_BIN"] = old_codex_bin
      else
        ENV.delete("TYCHO_CODEX_BIN")
      end
    end
  end

  def assert_remote_agent_conversation_includes_run_summary
    Dir.mktmpdir("hq-remote-test") do |dir|
      old_agents_file = replace_constant(HQ, :AGENTS_FILE, File.join(dir, "managed_agents.json"))
      old_logs_dir = replace_constant(HQ, :AGENT_LOGS_DIR, File.join(dir, "agents"))
      old_archive_dir = replace_constant(HQ, :AGENT_ARCHIVE_DIR, File.join(dir, "agents", "archive"))

      FileUtils.mkdir_p(HQ::AGENT_LOGS_DIR)
      FileUtils.mkdir_p(HQ::AGENT_ARCHIVE_DIR)
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      registry = registry_for(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)

      created = service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Remote Agent",
        "prompt" => "Work remotely.",
        "agent" => "codex"
      )
      agent = HQ::AgentStore.new(registry.projects).load.find { |item| item.key == created[:key] }
      memory = HQ::AgentMemory.new(agent)
      memory.append_assistant_message!(
        "The normal assistant response should stay in the conversation.",
        created_at: Time.now - 1
      )
      shared_time = Time.now
      memory.append_assistant_message!(
        "The first same-second assistant response is invalid.",
        created_at: shared_time,
        metadata: { "_stream_sequence" => 20 }
      )
      memory.append_validation_retry!(
        "Structured output failed validation. Retrying in the same native session (1 of 2).",
        created_at: shared_time,
        metadata: {
          "_stream_sequence" => 21,
          "will_retry" => true,
          "next_correction_attempt" => 1,
          "correction_limit" => 2,
          "errors" => [
            { "code" => "missing_field", "path" => "$.attachments" }
          ]
        }
      )
      memory.append_assistant_message!(
        "The second same-second assistant response is corrected.",
        created_at: shared_time,
        metadata: { "_stream_sequence" => 23 }
      )
      memory.append_run_summary!(
        summary: "A detailed run summary that should stay readable in the conversation.\n\nSecond paragraph stays available for the full Summary page.",
        status: "succeeded",
        created_at: shared_time,
        metadata: {
          "_stream_sequence" => 24,
          "attachments" => [
            {
              "type" => "file",
              "kind" => "document",
              "title" => "summary-notes.md",
              "path" => File.join(workspace, "summary-notes.md")
            }
          ],
          "summary_sections" => [
            { "type" => "text", "text" => "Preserved the legacy summary." },
            { "type" => "link", "text" => "Read the implementation", "url" => "https://example.test/implementation" },
            { "type" => "attachment", "attachment" => {
              "type" => "file", "title" => "summary-notes.md", "path" => File.join(workspace, "summary-notes.md")
            } }
          ]
        }
      )

      conversation = service.conversation(created[:key])
      summary = conversation.find { |block| block[:kind] == "run_summary" }
      retry_block = conversation.find { |block| block[:kind] == "validation_retry" }
      assistant = conversation.find { |block| block[:role] == "assistant" }
      invalid_assistant_index = conversation.index do |block|
        block[:role] == "assistant" && block[:content].include?("first same-second")
      end
      retry_index = conversation.index(retry_block)
      corrected_assistant_index = conversation.index do |block|
        block[:role] == "assistant" && block[:content].include?("second same-second")
      end
      summary_index = conversation.index(summary)
      memory_summary = memory.events.find { |event| event["type"] == "run_summary" }

      assert(summary&.dig(:content)&.include?("A detailed run summary"),
             "expected Remote UI conversation payload to include run summary blocks")
      assert(summary&.dig(:content)&.include?("Second paragraph"),
             "expected Remote UI conversation payload to expose full run summaries for preview truncation")
      assert(summary&.dig(:metadata, "summary_id").to_s.start_with?("summary-"),
             "expected run summary conversation blocks to expose a stable summary id")
      assert(summary&.dig(:metadata, "attachments")&.first&.dig("title") == "summary-notes.md",
             "expected run summary conversation blocks to keep attachment metadata")
      assert(summary&.dig(:metadata, "summary_sections") == [
        { "type" => "text", "text" => "Preserved the legacy summary." },
        { "type" => "link", "text" => "Read the implementation", "url" => "https://example.test/implementation" },
        { "type" => "attachment", "attachment" => {
          "type" => "file", "title" => "summary-notes.md", "path" => File.join(workspace, "summary-notes.md")
        } }
      ], "expected run summary conversation blocks to keep ordered rich blocks beside attachments")
      assert(invalid_assistant_index && retry_index && corrected_assistant_index && summary_index &&
             invalid_assistant_index < retry_index && retry_index < corrected_assistant_index &&
             corrected_assistant_index < summary_index,
             "expected same-second retry events to stay between assistant responses and before the summary")
      assert(assistant&.dig(:content)&.include?("normal assistant response"),
             "expected normal assistant messages to remain visible in the conversation")
      assert(retry_block&.dig(:content)&.include?("Retrying in the same native session"),
             "expected Remote UI conversation payload to include Tycho system event blocks")
      assert(retry_block&.dig(:metadata, "errors", 0, "path") == "$.attachments",
             "expected system event blocks to expose safe field-level validation details")
      assert(memory_summary&.dig("content")&.include?("A detailed run summary"),
             "expected run summaries to remain persisted for the Summary page")
      service.archive_agent(created[:key])
      archived_summary = service.conversation(created[:key]).find { |block| block[:kind] == "run_summary" }
      assert(archived_summary&.dig(:metadata, "summary_sections") == summary[:metadata]["summary_sections"],
             "expected archived run history to restore structured sections")
    ensure
      replace_constant(HQ, :AGENTS_FILE, old_agents_file) if old_agents_file
      replace_constant(HQ, :AGENT_LOGS_DIR, old_logs_dir) if old_logs_dir
      replace_constant(HQ, :AGENT_ARCHIVE_DIR, old_archive_dir) if old_archive_dir
    end
  end

  def assert_remote_agent_debug_endpoints
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)
      server = HQ::RemoteServer.new
      old_log_file = replace_constant(HQ, :LOG_FILE, File.join(dir, "hq.log"))

      created = service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Debug Agent",
        "prompt" => "Work remotely.",
        "agent" => "codex"
      )
      agent = HQ::AgentStore.new(registry.projects).load.find { |item| item.key == created[:key] }
      started_at = Time.now
      raw_lines = [
        "=== [#{started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ===",
        JSON.generate("type" => "item.completed", "item" => { "type" => "agent_message", "text" => "Debug reply." })
      ]
      File.write(agent.raw_log_path, "#{raw_lines.join("\n")}\n")
      File.write(HQ::LOG_FILE, "token=super-secret-token-value #{agent.key} Memory capture failed\n")
      memory = HQ::AgentMemory.new(agent)
      memory.append_user_message!("Debug prompt.", created_at: Time.now)
      memory.append_run_summary!(summary: "Debug summary.", status: "succeeded", created_at: Time.now)

      debug = service.agent_debug(agent.key)
      assert(debug.dig(:memory, :event_types, "user_message") == 1,
             "expected agent debug to count user memory events")
      assert(debug.dig(:memory, :event_types, "run_summary") == 1,
             "expected agent debug to count run summary memory events")
      assert(debug.dig(:memory, :event_types, "system_prompt").to_i.positive?,
             "expected agent debug to count seed system prompt memory events")
      assert(debug.dig(:files, :raw, :exists), "expected agent debug to expose raw log metadata")
      assert(debug[:recent_app_log].first.include?("[REDACTED]"), "expected agent debug app log tail to redact tokens")

      request = HQ::RemoteServer.const_get(:Request).new(
        method: "GET",
        path: "/agents/#{agent.key}/logs",
        query: "type=memory&tail=5",
        headers: {},
        body: ""
      )
      log_response = server.send(:route, service, "GET", "/agents/#{agent.key}/logs", {}, request)
      assert(log_response.dig(:body, :log, :type) == "memory", "expected agent log route to honor type")
      assert(log_response.dig(:body, :log, :tail).any? { |line| line.include?("Debug summary.") },
             "expected agent log route to return bounded memory tail")

      dry_run = service.agent_memory_capture_dry_run(agent.key)
      assert(dry_run[:current_run_line_count] == 1, "expected dry-run capture to inspect current raw run")
      assert(dry_run[:assistant_message_count] == 1, "expected dry-run capture to count assistant messages")

      FileUtils.rm_f(agent.memory_path)
      rebuilt = service.rebuild_agent_memory(agent.key)
      assert(rebuilt[:event_count].positive?, "expected memory rebuild endpoint to write events")
      assert(File.exist?(agent.memory_path), "expected memory rebuild endpoint to create memory jsonl")
    ensure
      replace_constant(HQ, :LOG_FILE, old_log_file) if old_log_file
    end
  end

  def assert_remote_project_payloads_include_status_and_detail
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)
      agent = service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Remote Agent",
        "prompt" => "Work remotely.",
        "agent" => "codex"
      )

      projects = service.projects
      project = projects.find { |item| item[:key] == "web" }
      assert(project, "expected project list to include web")
      assert(project[:group] == "Core", "expected project group")
      assert(project[:status] == "configured", "expected project status")
      detail = service.project("web")
      assert(detail[:pr_number] == "123", "expected PR number")
      assert(detail[:managed_agent_count] == 1, "expected managed-agent count")
      assert(detail[:agent_template_summaries].first[:prompt] == "Default prompt for web.",
             "expected Remote UI project detail to expose full template prompt for agent creation")
      assert(detail.dig(:recent_agent_summary, :key) == agent[:key], "expected recent agent summary")
    end
  end

  def assert_remote_project_git_diff_payload
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      File.write(File.join(workspace, "tracked.txt"), "one\n")
      git!(workspace, "init")
      git!(workspace, "config", "user.email", "tycho@example.test")
      git!(workspace, "config", "user.name", "Tycho Test")
      git!(workspace, "config", "diff.mnemonicPrefix", "true")
      git!(workspace, "add", ".")
      git!(workspace, "commit", "-m", "initial")
      File.write(File.join(workspace, "tracked.txt"), "one\ntwo\n")
      File.write(File.join(workspace, "notes draft.txt"), "draft\n")

      registry = registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)
      diff = service.project_git_diff("web", scope: "worktree")
      tracked = diff[:files].find { |file| file[:path] == "tracked.txt" }
      untracked = diff[:files].find { |file| file[:path] == "notes draft.txt" }
      assert(diff[:scope] == "worktree", "expected worktree diff scope")
      assert(tracked, "expected tracked file diff")
      assert(tracked[:hunks].first[:lines].any? { |line| line[:kind] == "added" && line[:content] == "two" },
             "expected tracked additions to be parsed")
      assert(untracked && untracked[:status] == "untracked", "expected untracked files to be represented")
      assert(untracked[:additions] == 1, "expected untracked text additions to be counted")

      server = HQ::RemoteServer.new
      request = HQ::RemoteServer.const_get(:Request).new(
        method: "GET",
        path: "/projects/web/git/diff",
        query: "scope=all",
        headers: {},
        body: ""
      )
      response = server.send(:route, service, "GET", "/projects/web/git/diff", {}, request)
      assert(response.dig(:body, :diff, :scope) == "all", "expected git diff route to honor query scope")

      status = server.send(:route, service, "GET", "/projects/web/git/status", {}, nil)
      assert(status.dig(:body, :git, :dirty), "expected git status route to report dirty workspace")
      assert(status.dig(:body, :git, :dirty_files).to_i >= 2, "expected git status route to count dirty files")
    end
  end

  def assert_remote_project_workspace_routes
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      FileUtils.mkdir_p(File.join(workspace, "docs"))
      File.write(File.join(workspace, "docs", "guide.md"), "# Guide\n")
      File.write(File.join(workspace, ".env"), "TOKEN=secret\n")
      registry = registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)
      server = HQ::RemoteServer.new

      listing_request = HQ::RemoteServer::Request.new(
        method: "GET",
        path: "/projects/web/workspace",
        query: "path=docs&limit=50",
        headers: {},
        body: ""
      )
      listing = server.send(:route, service, "GET", listing_request.path, {}, listing_request)
      assert(listing[:body].dig(:workspace, :path) == "docs", "expected workspace listing route")
      assert(listing[:body].dig(:workspace, :entries, 0, :path) == "docs/guide.md",
             "expected workspace routes to return relative paths")
      assert(!listing[:body].inspect.include?(workspace), "expected workspace API responses to hide host paths")

      preview_request = HQ::RemoteServer::Request.new(
        method: "GET",
        path: "/projects/web/workspace/preview",
        query: "path=docs%2Fguide.md",
        headers: {},
        body: ""
      )
      preview = server.send(:route, service, "GET", preview_request.path, {}, preview_request)
      assert(preview[:body].dig(:preview, :content) == "# Guide\n", "expected text preview route")

      traversal = HQ::RemoteServer::Request.new(
        method: "GET",
        path: "/projects/web/workspace",
        query: "path=%252e%252e%252foutside",
        headers: {},
        body: ""
      )
      begin
        server.send(:route, service, "GET", traversal.path, {}, traversal)
        raise "expected encoded traversal to be rejected"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 400 && e.details[:code] == "invalid_path", "expected sanitized workspace path error")
        assert(!e.message.include?(workspace), "expected workspace errors to hide host paths")
      end

      begin
        service.project_workspace("wrong-project")
        raise "expected wrong project routing to fail"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 404, "expected wrong project routing to stay project-scoped")
      end
    end
  end

  def assert_remote_project_update_route_edits_metadata
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)
      server = HQ::RemoteServer.new

      updated = server.send(
        :route,
        service,
        "PATCH",
        "/projects/web",
        {
          "name" => "Web Renamed",
          "group" => "Ops",
          "agent" => "claude",
          "model" => "sonnet",
          "reasoning_effort" => "low"
        },
        nil
      )
      project = updated.dig(:body, :project)
      assert(project[:name] == "Web Renamed", "expected updated project name in response")
      assert(project[:group] == "Ops", "expected updated project group in response")
      assert(project[:path] == workspace, "expected project workspace path to stay unchanged")
      assert(project[:agent] == "claude", "expected default harness to update")
      assert(project[:model] == "sonnet", "expected project model to update")
      assert(project[:reasoning_effort] == "low", "expected project effort to update")
      assert(project[:pr_url].end_with?("/pull/123"), "expected PR URL to stay unchanged")

      persisted = YAML.safe_load(File.read(registry.path), aliases: true)
      entry = persisted["projects"].find { |item| item["key"] == "web" }
      assert(entry["name"] == "Web Renamed", "expected updated project name to persist")
      assert(entry["group"] == "Ops", "expected updated project group to persist")
      assert(entry["path"] == workspace, "expected persisted workspace path to stay unchanged")
      assert(entry["agent"] == "claude", "expected default harness to persist")
      assert(entry["model"] == "sonnet", "expected model to persist")
      assert(entry["reasoning_effort"] == "low", "expected effort to persist")
      assert(entry["pr_url"].end_with?("/pull/123"), "expected PR URL to stay unchanged")

      begin
        server.send(:route, service, "PATCH", "/projects/web", { "path" => File.join(dir, "other") }, nil)
        raise "expected Remote project path edits to be rejected"
      rescue HQ::RemoteServer::Error => e
        assert(e.message.include?("path cannot be changed"), "expected immutable path error")
      end

      begin
        server.send(:route, service, "PATCH", "/projects/web", { "pr_url" => "https://github.com/example/web/pull/12" }, nil)
        raise "expected Remote project PR URL edits to be rejected"
      rescue HQ::RemoteServer::Error => e
        assert(e.message.include?("pr_url cannot be changed"), "expected immutable PR URL error")
      end
    end
  end

  def assert_remote_agent_model_and_effort_payloads
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      config_path = File.join(dir, "hq.yml")
      prompts_path = File.join(dir, "system_prompts.yml")
      File.write(config_path, <<~YAML)
        projects:
          - key: web
            name: Web
            path: #{workspace}
            agent: codex
            model: gpt-5.1-codex-max
            reasoning_effort: low
      YAML
      File.write(prompts_path, <<~YAML)
        custom: Default prompt for %{project_key}.
        reviewer:
          name: Reviewer
          prompt: Review %{project_key}.
          agent: claude
          model: sonnet
          reasoning_effort: xhigh
      YAML
      registry = HQ::Registry.new(path: config_path, system_prompts_path: prompts_path)
      service = HQ::RemoteService.new(registry: registry)

      project = service.project("web")
      reviewer_template = project[:agent_template_summaries].find { |item| item[:key] == "reviewer" }
      assert(reviewer_template[:model] == "sonnet", "expected project detail to expose template model")
      assert(reviewer_template[:reasoning_effort] == "xhigh",
             "expected project detail to expose template reasoning effort")

      inherited = service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Inherited",
        "prompt" => "Use project defaults."
      )
      assert(inherited[:model] == "gpt-5.1-codex-max", "expected created agent to inherit project model")
      assert(inherited[:reasoning_effort] == "low", "expected created agent to inherit project effort")

      updated = service.update_agent(
        inherited[:key],
        "model" => "opus",
        "reasoning_effort" => "max"
      )
      assert(updated[:model] == "opus", "expected update payload to save model")
      assert(updated[:reasoning_effort] == "max", "expected update payload to save effort")

      cloned = service.clone_agent(updated[:key], {})
      assert(cloned.dig(:agent, :model) == "opus", "expected clone to copy source model")
      assert(cloned.dig(:agent, :reasoning_effort) == "max", "expected clone to copy source effort")

      cleared = service.update_agent(updated[:key], "model" => "", "reasoning_effort" => "")
      assert(cleared[:model].nil?, "expected blank model update to clear model")
      assert(cleared[:reasoning_effort].nil?, "expected blank effort update to clear effort")

      pi = service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Pi Agent",
        "prompt" => "Use Pi.",
        "agent" => "pi",
        "model" => "openai-codex/gpt-5.4",
        "reasoning_effort" => "high"
      )
      assert(pi[:agent] == "pi", "expected Remote API payload to preserve Pi harness selection")
      assert(pi[:model] == "openai-codex/gpt-5.4", "expected Remote API payload to preserve Pi model")
      assert(pi[:reasoning_effort] == "high", "expected Remote API payload to preserve Pi thinking level")
      assert(pi[:skill_trigger] == "/skill:", "expected Remote API payload to expose Pi skill invocation")
    end
  end

  def assert_remote_hidden_settings_filter_projects_and_agents
    with_remote_temp_store do |dir|
      prompts_path = File.join(dir, "system_prompts.yml")
      config_path = File.join(dir, "hq.yml")
      workspaces = %w[web-charlie worker docs].to_h do |key|
        path = File.join(dir, key)
        FileUtils.mkdir_p(path)
        [key, path]
      end
      File.write(config_path, <<~YAML)
        groups:
          Cookpad:
            hidden: true
        projects:
          - key: web-charlie
            name: Web Charlie
            group: Cookpad
            path: #{workspaces["web-charlie"]}
            hidden: false
          - key: worker
            name: Worker
            group: Cookpad
            path: #{workspaces["worker"]}
          - key: docs
            name: Docs
            group: Personal
            path: #{workspaces["docs"]}
      YAML
      File.write(prompts_path, <<~YAML)
        custom: Default prompt for %{project_key}.
      YAML
      registry = HQ::Registry.new(path: config_path, system_prompts_path: prompts_path)
      agents = [
        hidden_test_agent("web-charlie-agent-1", "web-charlie", workspaces["web-charlie"]),
        hidden_test_agent("worker-agent-1", "worker", workspaces["worker"]),
        hidden_test_agent("worker-archived-agent", "worker", workspaces["worker"]),
        hidden_test_agent("docs-agent-1", "docs", workspaces["docs"])
      ]
      HQ::AgentStore.new(registry.projects).save(agents)
      service = HQ::RemoteService.new(registry: registry)

      assert(service.projects.map { |project| project[:key] }.include?("web-charlie"),
             "expected explicit project hidden false to stay visible")
      assert(!service.projects.map { |project| project[:key] }.include?("worker"),
             "expected group-hidden project to be omitted from normal project list")
      visible_agent_keys = service.agents.map { |agent| agent[:key] }
      assert(visible_agent_keys.include?("web-charlie-agent-1") && visible_agent_keys.include?("docs-agent-1"),
             "expected normal agent list to include visible project agents")
      assert(!visible_agent_keys.include?("worker-agent-1"),
             "expected normal agent list to omit agents for hidden projects")
      begin
        service.submit_prompt("docs-agent-1", "prompt" => "Attach", "parent_agent_key" => "worker-agent-1")
        raise "expected hidden delegation parent to be rejected"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 404, "expected hidden delegation parent to be non-enumerable")
      end
      HQ::AgentStore.new(registry.projects).archive_agent!("worker-archived-agent")
      assert(service.archived_agents.dig(:pagination, :total).zero?,
             "expected hidden archives to stay out of discovery")
      legacy_record = HQ::AgentArchiveStore.new.find("worker-archived-agent")
      legacy_manifest = HQ::FileStore.read_json(legacy_record.manifest_path, fallback: {})
      legacy_manifest.delete("project_hidden_at_archive")
      HQ::FileStore.write_json(legacy_record.manifest_path, legacy_manifest)
      FileUtils.touch(File.dirname(File.dirname(legacy_record.manifest_path)))
      service_projects = service.instance_variable_get(:@projects)
      service.instance_variable_set(:@projects, service_projects.reject { |project| project.key == "worker" })
      assert(service.archived_agents.dig(:pagination, :total).zero?,
             "expected legacy archives for missing projects to fail closed")
      service.instance_variable_set(:@projects, service_projects)
      begin
        service.agent("worker-archived-agent")
        raise "expected hidden archived agent detail to be hidden"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 404, "expected hidden archived agent detail to return 404")
      end
      begin
        service.project("worker")
        raise "expected hidden project detail to be hidden"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 404, "expected hidden project detail to return 404")
      end

      settings = service.hidden_settings
      worker = settings[:projects].find { |project| project[:key] == "worker" }
      assert(worker[:hidden] == true && worker[:visibility_source] == "group",
             "expected hidden settings to expose group-inherited hidden project")

      updated = service.update_hidden_setting("scope" => "group", "key" => "Cookpad", "hidden" => false)
      assert(updated[:groups].find { |group| group[:name] == "Cookpad" }[:hidden_config] == false,
             "expected Remote hidden settings to update group hidden config")
      assert(service.projects.map { |project| project[:key] }.include?("worker"),
             "expected group visibility change to reveal inherited projects")
      assert(service.agents.map { |agent| agent[:key] }.include?("worker-agent-1"),
             "expected group visibility change to reveal inherited project agents")
      assert(service.archived_agents.dig(:pagination, :total).zero?,
             "expected legacy archives without immutable visibility to remain hidden")

      service.update_hidden_setting("scope" => "project", "key" => "docs", "hidden" => true)
      assert(!service.projects.map { |project| project[:key] }.include?("docs"),
             "expected project hidden setting to remove project from normal list")
      assert(!service.agents.map { |agent| agent[:key] }.include?("docs-agent-1"),
             "expected project hidden setting to remove its agents from normal list")
      persisted = YAML.safe_load(File.read(config_path), permitted_classes: [Symbol], aliases: true)
      assert(persisted.dig("groups", "Cookpad", "hidden") == false,
             "expected group hidden setting to persist to hq.yml")
      assert(persisted["projects"].find { |project| project["key"] == "docs" }["hidden"] == true,
             "expected project hidden setting to persist to hq.yml")
    end
  end

  def assert_remote_response_style_settings
    with_remote_temp_store do |dir|
      path = File.join(dir, "config", "response_style.md")
      FileUtils.mkdir_p(File.dirname(path))
      with_env_values("TYCHO_RESPONSE_STYLE_PATH" => path) do
        workspace = File.join(dir, "workspace")
        write_project_workspace(workspace)
        service = HQ::RemoteService.new(registry: registry_for_project(dir, workspace))
        server = HQ::RemoteServer.new

        fetched = server.send(:route, service, "GET", "/settings/response-style", {}, nil)
        assert(fetched.dig(:body, :response_style, :path) == path,
               "expected response style settings to expose the configured path")
        assert(fetched.dig(:body, :response_style, :exists) == false,
               "expected a missing response style to be an addable empty state")

        created_text = "Lead with the result.\n"
        created = server.send(
          :route,
          service,
          "PATCH",
          "/settings/response-style",
          { "content" => created_text },
          nil
        )
        assert(created.dig(:body, :response_style, :exists) == true,
               "expected saving the empty state to create a response style")
        assert(File.read(path) == created_text, "expected response style creation to persist")

        agent = service.create_agent(
          "project_key" => "web",
          "template_key" => "custom",
          "name" => "Styled Agent",
          "prompt" => "Use the global style.",
          "agent" => "codex"
        )
        assert(agent[:response_style_source] == "global",
               "expected agents without an override to report the active global response style")

        updated_text = "Write plainly. Keep technical precision.\n"
        updated = server.send(
          :route,
          service,
          "PATCH",
          "/settings/response-style",
          { "content" => updated_text },
          nil
        )
        assert(updated.dig(:body, :response_style, :content) == updated_text,
               "expected response style update to return saved content")
        assert(File.read(path) == updated_text, "expected response style update to persist atomically")
        assert(File.read("#{path}.bak") == "Lead with the result.\n",
               "expected response style update to retain a backup")

        deleted = server.send(:route, service, "DELETE", "/settings/response-style", {}, nil)
        assert(deleted.dig(:body, :response_style, :exists) == false,
               "expected removing a response style to return the addable empty state")
        assert(!File.exist?(path), "expected removing a response style to delete the configured file")
        assert(service.agent(agent[:key])[:response_style_source] == "disabled",
               "expected agents without an override to report disabled when the global style is removed")
        assert(File.read("#{path}.bak") == "Lead with the result.\n",
               "expected removing a response style to retain its existing backup")

        begin
          server.send(:route, service, "PATCH", "/settings/response-style", { "content" => 123 }, nil)
          raise "expected non-string response style content to fail"
        rescue HQ::RemoteServer::Error => e
          assert(e.status == 400, "expected invalid response style content to return a bad request")
        end
      end
    end
  end

  def assert_remote_schedule_routes
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      registry = registry_for(dir, workspace)
      File.write(File.join(HQ::USER_SCHEDULES_DIR, "weekly.md"), "Run weekly review.\n")
      File.write(HQ::SCHEDULES_FILE, <<~YAML)
        schedules:
          - key: weekday
            cron: "0 9 * * 1-5"
            target:
              type: agent
              project_key: web
              message: "Run maintenance."
          - key: weekly-file
            cron: "0 12 * * 1"
            target:
              type: agent
              project_key: web
              message_source: file
              message_file: schedules/weekly.md
      YAML
      daemon_supervisor = FakeScheduleDaemonSupervisor.new
      service = HQ::RemoteService.new(registry: registry, schedule_daemon_supervisor: daemon_supervisor)
      server = HQ::RemoteServer.new

      listed = server.send(:route, service, "GET", "/schedules", {}, nil)
      assert(listed.dig(:body, :schedules).length == 2, "expected schedule list route")
      assert(listed.dig(:body, :daemon, :status) == "stopped", "expected schedule daemon status")
      assert(listed.dig(:body, :schedules, 0, :message_source) == "inline", "expected editable message source in payload")
      assert(listed.dig(:body, :schedules, 0, :message) == "Run maintenance.", "expected editable message in payload")

      message = server.send(:route, service, "GET", "/schedules/weekly-file/message", {}, nil)
      assert(message.dig(:body, :message, :message_file) == "schedules/weekly.md",
             "expected schedule message route to expose message_file")
      assert(message.dig(:body, :message, :content) == "Run weekly review.\n",
             "expected schedule message route to read markdown")
      updated_message = server.send(:route, service, "PATCH", "/schedules/weekly-file/message",
                                    { "content" => "Updated weekly review.\n" }, nil)
      assert(updated_message.dig(:body, :message, :content) == "Updated weekly review.\n",
             "expected schedule message route to save markdown")
      assert(File.read(File.join(HQ::USER_SCHEDULES_DIR, "weekly.md")) == "Updated weekly review.\n",
             "expected schedule message route to persist markdown")

      created = server.send(:route, service, "POST", "/schedules", {
                              "key" => "daily",
                              "name" => "Daily check",
                              "cron" => "15 10 * * *",
                              "timezone" => "UTC",
                              "project_key" => "web",
                              "agent_name" => "Daily Agent",
                              "system_message" => "Daily system context.",
                              "message_source" => "inline",
                              "message" => "Check the project.",
                              "policy" => {
                                "overlap" => "queue",
                                "missed" => "skip_missed",
                                "archive_previous_agent" => false
                              }
                            }, nil)
      assert(created[:status] == 201, "expected schedule create route")
      assert(created.dig(:body, :schedule, :key) == "daily", "expected created schedule payload")
      assert(created.dig(:body, :schedule, :project_key) == "web", "expected created schedule project")
      assert(created.dig(:body, :schedule, :system_message) == "Daily system context.",
             "expected created schedule system message")
      assert(created.dig(:body, :schedule, :policy, "overlap") == "skip",
             "expected schedule policy to use the fixed overlap default")

      updated = server.send(:route, service, "PATCH", "/schedules/daily", {
                              "key" => "daily",
                              "name" => "Daily check edited",
                              "cron" => "30 11 * * 1-5",
                              "timezone" => "local",
                              "project_key" => "web",
                              "system_message" => "Updated system context.",
                              "message_source" => "inline",
                              "message" => "Check weekdays.",
                              "policy" => {
                                "overlap" => "queue",
                                "missed" => "skip_missed",
                                "archive_previous_agent" => false
                              }
                            }, nil)
      assert(updated.dig(:body, :schedule, :name) == "Daily check edited", "expected schedule update route")
      assert(updated.dig(:body, :schedule, :cron) == "30 11 * * 1-5", "expected updated schedule cron")
      assert(updated.dig(:body, :schedule, :system_message) == "Updated system context.",
             "expected updated schedule system message")
      assert(updated.dig(:body, :schedule, :policy) == {
        "overlap" => "skip",
        "missed" => "run_once_on_start",
        "archive_previous_agent" => true
      }, "expected schedule update to ignore removed advanced policy options")
      stored_daily = YAML.safe_load_file(HQ::SCHEDULES_FILE).fetch("schedules").find { |item| item["key"] == "daily" }
      assert(!stored_daily.key?("enabled"), "expected schedule saves to drop enabled config")
      assert(!stored_daily.key?("policy"), "expected schedule saves to drop policy config")

      loop_agent = service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Review session",
        "prompt" => "Work on the open pull request.",
        "agent" => "codex"
      )
      loop_ends_at = Time.now + 3_600
      begin
        server.send(:route, service, "POST", "/agents/#{loop_agent[:key]}/loop-schedule", {
                      "schedule_key" => "daily",
                      "name" => "Duplicate loop",
                      "interval_minutes" => 10,
                      "ends_at" => loop_ends_at.iso8601,
                      "message" => "Check for reviews."
                    }, nil)
        raise "expected duplicate loop schedule key to fail"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 400, "expected duplicate loop schedule key to return a bad request")
      end
      untouched_agent = service.send(:load_all_agents).find { |item| item.key == loop_agent[:key] }
      assert(untouched_agent.schedule_key.to_s.empty?,
             "expected invalid loop creation to leave the existing session unscheduled")
      schedule_prompts = HQ::AgentMemory.new(untouched_agent).events.select do |event|
        event["type"] == "system_prompt" && event.dig("metadata", "prompt_role") == "schedule"
      end
      assert(schedule_prompts.empty?, "expected invalid loop creation not to alter session memory")

      begin
        with_stubbed_agent_start_error("loop start failed") do
          server.send(:route, service, "POST", "/agents/#{loop_agent[:key]}/loop-schedule", {
                        "schedule_key" => "broken-loop",
                        "name" => "Broken loop",
                        "interval_minutes" => 10,
                        "ends_at" => loop_ends_at.iso8601,
                        "message" => "Check for reviews."
                      }, nil)
        end
        raise "expected failed loop start to return an error"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 409, "expected failed loop start to return a conflict")
      end
      rolled_back_agent = service.send(:load_all_agents).find { |item| item.key == loop_agent[:key] }
      rolled_back_schedules = YAML.safe_load_file(HQ::SCHEDULES_FILE).fetch("schedules")
      assert(rolled_back_agent.schedule_key.to_s.empty?,
             "expected failed loop start to restore the agent schedule association")
      assert(rolled_back_schedules.none? { |item| item["key"] == "broken-loop" },
             "expected failed loop start to remove the created schedule")
      assert(!HQ::ScheduleStore.new.load.key?("broken-loop"),
             "expected failed loop start to remove the created schedule state")
      rolled_back_prompts = HQ::AgentMemory.new(rolled_back_agent).events.select do |event|
        event["type"] == "system_prompt" && event.dig("metadata", "prompt_role") == "schedule"
      end
      assert(rolled_back_prompts.empty?, "expected failed loop start to restore agent memory")

      loop_response = with_stubbed_agent_start do
        server.send(:route, service, "POST", "/agents/#{loop_agent[:key]}/loop-schedule", {
                      "schedule_key" => "review-loop",
                      "name" => "Review loop",
                      "interval_minutes" => 10,
                      "ends_at" => loop_ends_at.iso8601,
                      "message" => "Check for new PR reviews and address actionable feedback."
                    }, nil)
      end
      assert(loop_response[:status] == 201, "expected agent loop creation route")
      assert(loop_response.dig(:body, :schedule, :target_agent_key) == loop_agent[:key],
             "expected loop schedule to target the existing session")
      assert(loop_response.dig(:body, :schedule, :cron) == "*/10 * * * *",
             "expected loop interval to become a normal cron schedule")
      assert(loop_response.dig(:body, :schedule, :ends_at) == loop_ends_at.iso8601,
             "expected loop schedule to retain its end time")
      assert(loop_response.dig(:body, :agent, :schedule_key) == "review-loop",
             "expected the existing session to gain the loop schedule association")
      assert(daemon_supervisor.calls.include?([:start, nil, false]),
             "expected loop creation to start a stopped scheduler daemon")
      stored_loop = YAML.safe_load_file(HQ::SCHEDULES_FILE).fetch("schedules").find do |item|
        item["key"] == "review-loop"
      end
      assert(stored_loop.dig("target", "agent_key") == loop_agent[:key],
             "expected loop target session to persist in schedules.yml")
      assert(stored_loop.dig("target", "system_message").include?("owned by the Tycho schedule"),
             "expected loop schedule to persist the normal schedule system prompt")
      loop_state = HQ::ScheduleStore.new.load.fetch("review-loop")
      assert(loop_state.last_target_key == loop_agent[:key] && loop_state.run_count == 1,
             "expected the immediate first loop run to use the existing session")

      loop_memory_before_removal = File.binread(
        service.send(:load_all_agents).find { |item| item.key == loop_agent[:key] }.memory_path
      )
      removed_loop = server.send(:route, service, "DELETE", "/schedules/review-loop", {}, nil)
      assert(removed_loop.dig(:body, :deleted), "expected conversation schedule removal to delete the schedule")
      assert(removed_loop.dig(:body, :detached_agent_keys) == [loop_agent[:key]],
             "expected schedule removal to identify the preserved session")
      assert(removed_loop.dig(:body, :agents, 0, :key) == loop_agent[:key],
             "expected schedule removal to return every detached agent for immediate reconciliation")
      assert(removed_loop.dig(:body, :agent, :key) == loop_agent[:key] &&
             removed_loop.dig(:body, :agent, :schedule_key).nil? &&
             removed_loop.dig(:body, :agent, :scheduled) == false,
             "expected schedule removal to return an immediately detached agent payload")
      detached_loop_agent = service.send(:load_all_agents).find { |item| item.key == loop_agent[:key] }
      assert(detached_loop_agent && detached_loop_agent.schedule_key.nil? && !detached_loop_agent.scheduled?,
             "expected the scheduled session to remain active as an ordinary agent")
      assert(File.binread(detached_loop_agent.memory_path) == loop_memory_before_removal,
             "expected schedule removal to preserve the complete session memory")
      assert(!HQ::ScheduleStore.new.load.key?("review-loop") &&
             YAML.safe_load_file(HQ::SCHEDULES_FILE).fetch("schedules").none? { |item| item["key"] == "review-loop" },
             "expected schedule removal to stop future automatic runs in config and runtime state")
      ordinary_prompt = service.submit_prompt(loop_agent[:key], "prompt" => "Continue manually.", "start" => false)
      assert(ordinary_prompt.dig(:agent, :schedule_key).nil? &&
             ordinary_prompt.fetch(:conversation).any? { |block| block[:content] == "Continue manually." },
             "expected the detached agent to accept ordinary prompts without losing history")

      paused = server.send(:route, service, "POST", "/schedules/weekday/pause", {}, nil)
      assert(paused.dig(:body, :schedule, :paused), "expected schedule pause route")

      resumed = server.send(:route, service, "POST", "/schedules/weekday/resume", {}, nil)
      assert(!resumed.dig(:body, :schedule, :paused), "expected schedule resume route")

      reloaded = server.send(:route, service, "POST", "/schedules/reload", {}, nil)
      assert(reloaded.dig(:body, :ok), "expected schedule reload route")

      started = server.send(:route, service, "POST", "/schedules/daemon/start", { "interval" => 17 }, nil)
      assert(started[:status] == 202, "expected schedule daemon start route to be accepted")
      assert(started.dig(:body, :started), "expected schedule daemon start payload")
      assert(daemon_supervisor.calls.include?([:start, 17, false]), "expected start route to use separate daemon supervisor")

      stopped = server.send(:route, service, "POST", "/schedules/daemon/stop", {}, nil)
      assert(stopped[:status] == 202, "expected schedule daemon stop route to be accepted")
      assert(stopped.dig(:body, :stopped), "expected schedule daemon stop payload")

      restarted = server.send(:route, service, "POST", "/schedules/daemon/restart", { "dry_run" => true }, nil)
      assert(restarted[:status] == 202, "expected schedule daemon restart route to be accepted")
      assert(restarted.dig(:body, :restarted), "expected schedule daemon restart payload")
      assert(daemon_supervisor.calls.include?([:restart, nil, true]), "expected restart route to use separate daemon supervisor")

      HQ::ScheduleStore.new.save(
        "daily" => HQ::ScheduleState.new(key: "daily", status: "paused", enabled: false, run_count: 1, skip_count: 0)
      )
      deleted = server.send(:route, service, "DELETE", "/schedules/daily", {}, nil)
      assert(deleted.dig(:body, :deleted), "expected schedule delete route")
      assert(!HQ::ScheduleStore.new.load.key?("daily"), "expected schedule delete to clear runtime state")
      persisted = YAML.safe_load_file(HQ::SCHEDULES_FILE)
      assert(Array(persisted["schedules"]).none? { |entry| entry["key"] == "daily" },
             "expected deleted schedule to be removed from schedules.yml")
    end
  end

  def assert_remote_setup_payload_includes_readiness
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      write_archived_config(dir)
      registry = registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(
        registry: registry,
        server_url: "http://127.0.0.1:7373",
        public_url: "http://hq.tailnet.test:7373/",
        auth_required: true,
        restartable: true
      )

      setup = service.setup
      assert(setup[:ui_url] == "http://127.0.0.1:7373/", "expected local UI URL")
      assert(setup[:public_ui_url] == "http://hq.tailnet.test:7373/", "expected public UI URL")
      assert(setup.dig(:tailscale, :https) == false, "expected HTTP Tailscale state")
      assert(setup.dig(:auth, :required), "expected auth state")
      assert(setup.dig(:auth, :status) == "token required", "expected required auth status")
      assert(setup.dig(:server, :restartable), "expected setup payload to expose Remote restart readiness")
      assert(setup.dig(:build, :version) == HQ::VERSION, "expected setup payload to expose Tycho version")
      assert(setup.dig(:build, :asset_version).to_s.length == 12, "expected setup payload to expose Remote UI build")
      assert(setup.dig(:counts, :projects) == 1, "expected active project count")
      assert(setup.dig(:counts, :archived_projects) == 1, "expected archived project count")
      assert(setup[:refresh_intervals] == { active_ms: 5_000, idle_ms: 10_000, hidden_ms: 30_000 },
             "expected refresh intervals to use the 5s, 10s, and 30s policy")
      assert(setup[:harnesses].map { |item| item[:name] }.sort == %w[claude claude-wrapper codex opencode pi],
             "expected harness readiness entries")
      claude = setup[:harnesses].find { |item| item[:name] == "claude" }
      claude_models = Array(claude[:model_suggestions]).map { |item| item[:value] }
      assert(claude_models == %w[claude-fable-5 claude-opus-5 claude-opus-4-8 claude-sonnet-5 claude-haiku-4-5],
             "expected Claude readiness to expose only current Anthropic model aliases")
      assert(setup[:tools].map { |item| item[:name] }.sort == %w[tailscale],
             "expected optional tool readiness entries")
      assert(setup.dig(:schema, :valid) == true, "expected valid result schema")
      assert(setup.dig(:config, :prompt_template_count) == 1, "expected prompt template count")
      schedule_prompt_template = setup.dig(:config, :schedule_system_message_template).to_s
      assert(schedule_prompt_template.include?("%{title}"),
             "expected setup payload to expose a title-aware schedule system message template")
      assert(schedule_prompt_template.include?("did not complete a requested change, answer, commit, review, or deliverable"),
             "expected schedule template to share strict no-action guidance")
      assert(setup[:safety].any? { |line| line.include?("Running agents") }, "expected safety defaults")
    end
  end

  def assert_remote_harness_catalogs_are_configurable
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)
      server = HQ::RemoteServer.new

      response = server.send(
        :route,
        service,
        "PATCH",
        "/setup/harnesses/claude/catalog",
        {
          "models" => ["claude-custom-1", "claude-custom-1", " gateway/model "],
          "reasoning_efforts" => ["TURBO", "low", ""]
        },
        nil
      )
      claude = response.dig(:body, :setup, :harnesses).find { |item| item[:name] == "claude" }
      model_values = Array(claude[:model_suggestions]).map { |item| item[:value] }

      assert(model_values.include?("claude-custom-1"), "expected saved custom model to appear in readiness")
      assert(model_values.include?("gateway/model"), "expected custom model names to be stripped")
      assert(claude[:configured_model_suggestions] == ["claude-custom-1", "gateway/model"],
             "expected setup to expose persisted custom model rows")
      assert(claude[:configured_reasoning_effort_suggestions] == %w[turbo low],
             "expected setup to expose persisted custom effort rows")
      assert(claude[:reasoning_effort_suggestions].include?("turbo"),
             "expected custom effort to merge into readiness suggestions")
      assert(claude[:catalog_source].include?("hq.yml custom catalog"),
             "expected catalog source to mention custom config")

      persisted = YAML.safe_load(File.read(registry.path), aliases: true)
      assert(persisted.dig("harness_catalogs", "claude", "models") == ["claude-custom-1", "gateway/model"],
             "expected custom model rows to persist in hq.yml")
      assert(persisted.dig("harness_catalogs", "claude", "reasoning_efforts") == %w[turbo low],
             "expected custom effort rows to persist in hq.yml")
    end
  end

  def assert_remote_setup_refreshes_harness_catalogs
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)
      server = HQ::RemoteServer.new

      HQ::HarnessCatalog.catalog_cache[:sentinel] = true
      response = server.send(:route, service, "POST", "/setup/harnesses/refresh", {}, nil)

      assert(response[:status] == 200, "expected harness refresh route to return ok")
      assert(!HQ::HarnessCatalog.catalog_cache.key?(:sentinel), "expected harness refresh to clear cached catalogs")
      assert(response.dig(:body, :setup, :harnesses).map { |item| item[:name] }.include?("codex"),
             "expected harness refresh to return fresh setup readiness")
    end
  end

  def assert_remote_setup_uses_shared_executable_resolution
    with_remote_temp_store do |dir|
      home = File.join(dir, "home")
      empty_path = File.join(dir, "empty-bin")
      workspace = File.join(dir, "workspace")
      %w[claude codex opencode pi].each do |command|
        write_test_executable(File.join(home, ".local", "bin", command))
      end
      FileUtils.mkdir_p(empty_path)
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)

      with_env_values(
        "HOME" => home,
        "PATH" => empty_path,
        "TYCHO_CLAUDE_BIN" => nil,
        "TYCHO_CODEX_BIN" => nil,
        "TYCHO_OPENCODE_BIN" => nil,
        "TYCHO_PI_BIN" => nil
      ) do
        setup = HQ::RemoteService.new(registry: registry).setup
        codex = setup[:harnesses].find { |item| item[:name] == "codex" }
        claude = setup[:harnesses].find { |item| item[:name] == "claude" }
        opencode = setup[:harnesses].find { |item| item[:name] == "opencode" }
        pi = setup[:harnesses].find { |item| item[:name] == "pi" }
        assert(codex[:ready] && codex[:path].end_with?("/.local/bin/codex"),
               "expected Remote setup to find fallback Codex")
        assert(codex.key?(:model_suggestions), "expected Codex readiness to expose model suggestions")
        assert(codex.key?(:reasoning_effort_suggestions), "expected Codex readiness to expose effort suggestions")
        assert(claude[:ready] && claude[:path].end_with?("/.local/bin/claude"),
               "expected Remote setup to find fallback Claude")
        assert(claude[:reasoning_effort_suggestions].include?("low"),
               "expected Claude readiness to expose fallback effort suggestions")
        assert(opencode[:ready] && opencode[:path].end_with?("/.local/bin/opencode"),
               "expected Remote setup to find fallback OpenCode")
        assert(opencode[:reasoning_effort_suggestions].include?("high"),
               "expected OpenCode readiness to expose variant suggestions")
        assert(pi[:ready] && pi[:path].end_with?("/.local/bin/pi"),
               "expected Remote setup to find fallback Pi")
        assert(pi[:reasoning_effort_suggestions].include?("xhigh"),
               "expected Pi readiness to expose thinking suggestions")
        assert(pi[:safety_gaps].any? { |gap| gap.include?("no sandbox equivalent") },
               "expected Pi safety gaps in setup payload")
      end
    end
  end

  def assert_remote_setup_handles_utf8_harness_output_under_ascii_external
    with_remote_temp_store do |dir|
      home = File.join(dir, "home")
      bin_dir = File.join(dir, "bin")
      logs_dir = File.join(dir, "logs")
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p([home, bin_dir, logs_dir])
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      write_opencode_with_table_output(File.join(bin_dir, "opencode"))

      script = <<~RUBY
        require "json"
        require "hq/remote_server"

        registry = HQ::Registry.new(path: ARGV.fetch(0), system_prompts_path: ARGV.fetch(1))
        setup = HQ::RemoteService.new(registry: registry).setup
        body = JSON.pretty_generate(setup: setup)
        raise "expected OpenCode auth provider in setup payload" unless body.include?("anthropic")

        puts body.bytesize
      RUBY
      env = {
        "LC_ALL" => "C",
        "LANG" => "C",
        "HOME" => home,
        "PATH" => bin_dir,
        "TYCHO_LOGS_ROOT" => logs_dir,
        "TYCHO_CLAUDE_BIN" => nil,
        "TYCHO_CODEX_BIN" => nil,
        "TYCHO_OPENCODE_BIN" => File.join(bin_dir, "opencode")
      }
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-Ilib", "-e", script,
                                        registry.path, registry.system_prompts_path)

      assert(status.success?,
             "expected setup payload to serialize under US-ASCII defaults, stdout=#{out.inspect}, stderr=#{err.inspect}")
    end
  end

  def assert_remote_setup_warns_when_public_url_has_no_token
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(
        registry: registry,
        server_url: "http://127.0.0.1:7373",
        public_url: "http://hq.tailnet.test:7373/",
        auth_required: false
      )

      setup = service.setup
      assert(setup.dig(:auth, :required) == false, "expected auth to remain optional")
      assert(setup.dig(:auth, :status) == "token recommended", "expected public URL to recommend token")
      assert(setup.dig(:auth, :warning).to_s.include?("TYCHO_REMOTE_TOKEN"),
             "expected setup auth warning to mention TYCHO_REMOTE_TOKEN")
      assert(setup[:safety].any? { |line| line.include?("TYCHO_REMOTE_TOKEN") },
             "expected setup safety guidance to mention TYCHO_REMOTE_TOKEN")
    end
  end

  def assert_remote_welcome_onboarding_creates_project
    with_remote_temp_store do |dir|
      config_path = File.join(dir, "hq.yml")
      prompts_path = File.join(dir, "system_prompts.yml")
      welcome_path = File.join(dir, "workspaces", "welcome")
      old_welcome_path = replace_constant(HQ, :WELCOME_WORKSPACE_DIR, welcome_path)
      File.write(config_path, "projects: []\n")
      File.write(prompts_path, "custom: Default prompt.\n")
      registry = HQ::Registry.new(path: config_path, system_prompts_path: prompts_path)
      service = HQ::RemoteService.new(registry: registry)

      setup = service.setup
      assert(setup.dig(:onboarding, :active) == true, "expected setup payload to mark onboarding active")
      assert(setup.dig(:onboarding, :welcome_workspace_path) == welcome_path,
             "expected setup payload to expose welcome workspace path")

      project = service.create_welcome_project
      persisted = YAML.safe_load(File.read(config_path), permitted_classes: [Symbol], aliases: true)
      entry = persisted["projects"].first

      assert(project[:key] == "welcome", "expected welcome project payload")
      assert(entry["key"] == "welcome", "expected welcome project to persist")
      assert(entry["path"] == welcome_path, "expected persisted welcome workspace path")
      assert(File.exist?(File.join(welcome_path, "README.md")), "expected welcome README")
      assert(service.setup.dig(:onboarding, :active) == false, "expected onboarding to finish after project creation")
    ensure
      replace_constant(HQ, :WELCOME_WORKSPACE_DIR, old_welcome_path) if old_welcome_path
    end
  end

  def assert_remote_welcome_onboarding_exposes_agent_cli_guides
    with_remote_temp_store do |dir|
      config_path = File.join(dir, "hq.yml")
      prompts_path = File.join(dir, "system_prompts.yml")
      File.write(config_path, "projects: []\n")
      File.write(prompts_path, "custom: Default prompt.\n")
      registry = HQ::Registry.new(path: config_path, system_prompts_path: prompts_path)
      setup = HQ::RemoteService.new(registry: registry).setup
      guides = setup.dig(:onboarding, :agent_cli_guides)

      assert(guides.map { |guide| guide[:key] } == %w[codex claude opencode pi],
             "expected onboarding CLI guides for each built-in harness")
      guides.each do |guide|
        assert(guide[:install_command].to_s.length.positive?, "expected #{guide[:key]} install command")
        assert(guide[:verify_command].to_s.end_with?("--version"), "expected #{guide[:key]} verification command")
        assert(guide[:setup].to_s.length.positive?, "expected #{guide[:key]} setup guidance")
        assert(guide[:documentation_url].to_s.start_with?("https://"), "expected #{guide[:key]} official docs URL")
      end
    end
  end

  def assert_remote_server_restart_route_schedules_restart
    output = StringIO.new
    server = HQ::RemoteServer.new(
      restart_command: [RbConfig.ruby, "bin/tycho", "serve", "--port", "7374"],
      logger: Logger.new(StringIO.new),
      output: output
    )
    closed = false
    listener = Object.new
    listener.define_singleton_method(:closed?) { closed }
    listener.define_singleton_method(:close) { closed = true }
    server.instance_variable_set(:@server, listener)

    response = server.send(:route, Object.new, "POST", "/server/restart", {})

    assert(response[:status] == 202, "expected restart route to return accepted")
    assert(response.dig(:body, :restarting), "expected restart route to acknowledge restart")
    assert(response.dig(:body, :command) == RbConfig.ruby, "expected restart route to expose command head")
    assert(response.dig(:headers, "Cache-Control").include?("no-store"),
           "expected restart route to disable caching for the restart response")
    assert(response.dig(:headers, "Clear-Site-Data") == "\"cache\"",
           "expected restart route to ask the browser to clear cached assets")
    assert(server.instance_variable_get(:@restart_requested), "expected restart route to mark restart requested")
    assert(server.instance_variable_get(:@shutdown), "expected restart route to request server shutdown")
    assert(closed, "expected restart route to close the listening socket")

    unavailable = HQ::RemoteServer.new(logger: Logger.new(StringIO.new), output: StringIO.new)
    begin
      unavailable.send(:route, Object.new, "POST", "/server/restart", {})
      raise "expected non-restartable server to reject restart"
    rescue HQ::RemoteServer::Error => e
      assert(e.status == 409, "expected non-restartable restart to return conflict")
    end
  end

  def assert_remote_broker_lists_configured_servers
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      config_path = File.join(dir, "hq.yml")
      prompts_path = File.join(dir, "system_prompts.yml")
      File.write(config_path, <<~YAML)
        remote_servers:
          - key: office-mac
            name: Office Mac
            icon: computer
            url: http://office-mac.example.test:7373/
            token_env: TYCHO_OFFICE_MAC_TOKEN
        projects:
          - key: web
            name: Web
            path: #{workspace}
      YAML
      File.write(prompts_path, "custom: Default prompt for %{project_key}.\n")
      registry = HQ::Registry.new(path: config_path, system_prompts_path: prompts_path)
      service = HQ::RemoteService.new(registry: registry, server_url: "http://127.0.0.1:7373")
      server = HQ::RemoteServer.new

      response = server.send(:route, service, "GET", "/servers", {}, nil)
      servers = response.dig(:body, :servers)

      assert(servers.map { |item| item[:key] } == %w[local office-mac],
             "expected broker server list to include local and configured remotes")
      assert(servers.first[:local] == true, "expected local broker server to be marked local")
      assert(servers.first[:icon] == "home", "expected local broker server to use the home icon")
      assert(servers.first.keys.sort == %i[auth_configured icon key local name url version],
             "expected broker server list to include only display metadata")
      assert(servers.first[:version] == HQ::VERSION,
             "expected local broker server to expose the running Tycho version")
      remote = servers.last
      assert(remote[:name] == "Office Mac", "expected configured remote display name")
      assert(remote[:icon] == "computer", "expected configured remote icon")
      assert(remote[:url] == "http://office-mac.example.test:7373",
             "expected configured remote URL to be normalized")
      assert(remote[:auth_configured] == false,
             "expected missing token env to avoid exposing credentials as configured")
    end
  end

  def assert_remote_resource_catalog_combines_and_retains_peer_resources
    peer_failing = false
    peer_payload = {
      schema_version: 1,
      build: { version: "0.9.0-peer" },
      agents: [{ key: "peer-agent", name: "Peer Agent", project_key: "peer-project" }],
      projects: [{ key: "peer-project", name: "Peer Project" }]
    }
    handler = lambda do |request|
      if request[:method] == "GET" && request[:path] == "/resources" && !peer_failing
        {
          status: 200,
          content_type: "application/json",
          body: JSON.generate(peer_payload)
        }
      else
        {
          status: 503,
          content_type: "application/json",
          body: JSON.generate(error: "peer unavailable")
        }
      end
    end

    with_fixture_http_server(handler) do |target_url|
      with_remote_temp_store do |dir|
        workspace = File.join(dir, "workspace")
        write_project_workspace(workspace)
        config_path = File.join(dir, "hq.yml")
        prompts_path = File.join(dir, "system_prompts.yml")
        File.write(config_path, <<~YAML)
          remote_servers:
            - key: peer
              name: Peer
              url: #{target_url}
          projects:
            - key: local-project
              name: Local Project
              path: #{workspace}
        YAML
        File.write(prompts_path, "custom: Default prompt for %{project_key}.\n")
        registry = HQ::Registry.new(path: config_path, system_prompts_path: prompts_path)
        local_service_class = Struct.new(:payload) do
          def resource_snapshot
            payload
          end
        end
        local_service = local_service_class.new(
          {
            schema_version: 1,
            build: { version: HQ::VERSION },
            agents: [{ key: "local-agent", name: "Local Agent", project_key: "local-project" }],
            projects: [{ key: "local-project", name: "Local Project" }]
          }
        )
        snapshot_path = File.join(dir, "remote_resources.json")
        catalog = HQ::RemoteResourceCatalog.new(
          max_workers: 2,
          logger: Logger.new(StringIO.new),
          snapshot_path: snapshot_path
        )
        catalog.reconcile(registry: registry, server_url: "http://127.0.0.1:7373")
        catalog.refresh(
          "local",
          registry: registry,
          server_url: "http://127.0.0.1:7373",
          local_service: local_service,
          force: true
        )
        catalog.refresh(
          "peer",
          registry: registry,
          server_url: "http://127.0.0.1:7373",
          local_service: local_service,
          force: true
        )
        wait_for_resource_catalog(catalog) do |snapshot|
          snapshot[:servers].all? { |entry| entry[:status] == "online" }
        end

        snapshot = catalog.snapshot
        local, peer = snapshot[:servers]
        assert(local[:agents].first[:server_key] == "local",
               "expected local catalog resources to carry ownership")
        assert(peer[:agents].first[:server_key] == "peer",
               "expected peer catalog resources to carry ownership")
        assert(peer[:projects].first[:key] == "peer-project",
               "expected peer projects to share the combined catalog")
        assert(local[:version] == HQ::VERSION && peer[:version] == "0.9.0-peer",
               "expected resource catalog servers to expose host and peer Tycho versions")
        assert(File.exist?(snapshot_path), "expected a successful peer refresh to persist its snapshot")
        assert((File.stat(snapshot_path).mode & 0o777) == 0o600,
               "expected persisted peer snapshots to be private")

        peer_failing = true
        catalog.refresh(
          "peer",
          registry: registry,
          server_url: "http://127.0.0.1:7373",
          local_service: local_service,
          force: true
        )
        wait_for_resource_catalog(catalog) do |next_snapshot|
          next_snapshot[:servers].find { |entry| entry[:key] == "peer" }[:status] == "offline"
        end

        stale_peer = catalog.snapshot[:servers].find { |entry| entry[:key] == "peer" }
        assert(stale_peer[:stale] == true, "expected failed peer refreshes to mark cached data stale")
        assert(stale_peer[:agents].first[:key] == "peer-agent",
               "expected stale peer resources to remain visible")
        assert(stale_peer[:retry_after_ms].positive?,
               "expected failed peer refreshes to publish retry backoff")

        restarted_catalog = HQ::RemoteResourceCatalog.new(
          max_workers: 1,
          logger: Logger.new(StringIO.new),
          snapshot_path: snapshot_path
        )
        restarted_catalog.reconcile(registry: registry, server_url: "http://127.0.0.1:7373")
        restored_peer = restarted_catalog.snapshot[:servers].find { |entry| entry[:key] == "peer" }
        assert(restored_peer[:status] == "loading" && restored_peer[:stale] == true,
               "expected a restored peer snapshot to start stale while it reconnects")
        assert(restored_peer[:last_success_at] == peer[:last_success_at],
               "expected a restored peer snapshot to preserve its last successful refresh")
        assert(restored_peer[:version] == "0.9.0-peer",
               "expected a restored peer snapshot to preserve the last known Tycho version")
        assert(restored_peer[:agents].first[:key] == "peer-agent",
               "expected peer agents to survive a broker restart")

        peer_failing = false
        peer_payload = {
          schema_version: 1,
          projects: []
        }
        restarted_catalog.refresh(
          "peer",
          registry: registry,
          server_url: "http://127.0.0.1:7373",
          local_service: local_service,
          force: true
        )
        wait_for_resource_catalog(restarted_catalog) do |next_snapshot|
          next_snapshot[:servers].find { |entry| entry[:key] == "peer" }[:status] == "offline"
        end
        incomplete_peer = restarted_catalog.snapshot[:servers].find { |entry| entry[:key] == "peer" }
        assert(incomplete_peer[:agents].first[:key] == "peer-agent",
               "expected an incomplete successful response to retain the persisted peer snapshot")

        route_server = HQ::RemoteServer.new(resource_catalog: restarted_catalog)
        forgotten = route_server.send(
          :route,
          HQ::RemoteService.new(registry: registry, server_url: "http://127.0.0.1:7373"),
          "DELETE",
          "/servers/peer/resources",
          {},
          nil
        )
        forgotten_peer = forgotten.dig(:body, :servers).find { |entry| entry[:key] == "peer" }
        assert(forgotten_peer[:agents].empty? && forgotten_peer[:last_success_at].nil?,
               "expected the peer cache route to forget persisted resources without removing the server")
        assert(JSON.parse(File.read(snapshot_path)).fetch("servers").empty?,
               "expected forgetting peer resources to clear the disk snapshot")

        peer_payload = {
          schema_version: 1,
          agents: [{ key: "peer-agent", name: "Peer Agent", project_key: "peer-project" }],
          projects: [{ key: "peer-project", name: "Peer Project" }]
        }
        restarted_catalog.refresh(
          "peer",
          registry: registry,
          server_url: "http://127.0.0.1:7373",
          local_service: local_service,
          force: true
        )
        wait_for_resource_catalog(restarted_catalog) do |next_snapshot|
          peer_entry = next_snapshot[:servers].find { |entry| entry[:key] == "peer" }
          peer_entry[:status] == "online" && peer_entry[:agents].any?
        end

        peer_payload = {
          schema_version: 1,
          agents: [],
          projects: []
        }
        restarted_catalog.refresh(
          "peer",
          registry: registry,
          server_url: "http://127.0.0.1:7373",
          local_service: local_service,
          force: true
        )
        wait_for_resource_catalog(restarted_catalog) do |next_snapshot|
          peer_entry = next_snapshot[:servers].find { |entry| entry[:key] == "peer" }
          persisted_entry = JSON.parse(File.read(snapshot_path)).fetch("servers").first
          peer_entry[:status] == "online" &&
            peer_entry[:agents].empty? &&
            persisted_entry.fetch("agents").empty?
        rescue Errno::ENOENT, JSON::ParserError
          false
        end
        authoritative_peer = restarted_catalog.snapshot[:servers].find { |entry| entry[:key] == "peer" }
        assert(authoritative_peer[:agents].empty? && authoritative_peer[:projects].empty?,
               "expected a valid full snapshot to remove agents and projects that no longer exist")

        reloaded_catalog = HQ::RemoteResourceCatalog.new(
          max_workers: 1,
          logger: Logger.new(StringIO.new),
          snapshot_path: snapshot_path
        )
        reloaded_catalog.reconcile(registry: registry, server_url: "http://127.0.0.1:7373")
        reloaded_peer = reloaded_catalog.snapshot[:servers].find { |entry| entry[:key] == "peer" }
        assert(reloaded_peer[:agents].empty? && reloaded_peer[:projects].empty?,
               "expected authoritative remote deletions to remain deleted after restart")

        registry.remove_remote_server!("peer")
        reloaded_catalog.reconcile(registry: registry, server_url: "http://127.0.0.1:7373")
        persisted = JSON.parse(File.read(snapshot_path))
        assert(persisted.fetch("servers").empty?,
               "expected removing a peer to forget its persisted resource snapshot")
      end
    end
  end

  def wait_for_resource_catalog(catalog)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    loop do
      snapshot = catalog.snapshot
      return snapshot if yield(snapshot)
      raise "resource catalog refresh timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep(0.01)
    end
  end

  def assert_remote_broker_proxies_configured_server_requests
    old_token = ENV["TYCHO_REMOTE_TARGET_TOKEN"]
    ENV["TYCHO_REMOTE_TARGET_TOKEN"] = "target-secret"
    requests = []
    handler = lambda do |request|
      requests << request
      case [request[:method], request[:path]]
      when ["POST", "/agents/web-agent-1/messages"]
        {
          status: 200,
          content_type: "application/json",
          body: JSON.generate(
            agent: { key: "web-agent-1", name: "Remote Agent" },
            echoed_query: request[:query],
            echoed_body: JSON.parse(request[:body])
          )
        }
      when ["GET", "/projects/web/workspace"]
        {
          status: 200,
          content_type: "application/json",
          body: JSON.generate(
            workspace: {
              path: "docs",
              parent: "",
              entries: [{ name: "guide.md", path: "docs/guide.md", kind: "file", size_bytes: 8 }],
              offset: 0,
              limit: 100,
              total: 1,
              next_offset: nil,
              truncated: false
            }
          )
        }
      when ["GET", "/attachments/image/blob"]
        {
          status: 200,
          content_type: "image/png",
          body: "png-bytes".b,
          headers: { "X-Content-Type-Options" => "nosniff" }
        }
      when ["GET", "/agents/unauthorized"]
        {
          status: 401,
          content_type: "application/json",
          body: JSON.generate(error: "Unauthorized")
        }
      else
        {
          status: 404,
          content_type: "application/json",
          body: JSON.generate(error: "missing #{request[:path]}")
        }
      end
    end
    with_fixture_http_server(handler) do |target_url|
      with_remote_temp_store do |dir|
        workspace = File.join(dir, "workspace")
        write_project_workspace(workspace)
        config_path = File.join(dir, "hq.yml")
        prompts_path = File.join(dir, "system_prompts.yml")
        File.write(config_path, <<~YAML)
          remote_servers:
            - key: target
              name: Target
              url: #{target_url}
              token_env: TYCHO_REMOTE_TARGET_TOKEN
          projects:
            - key: web
              name: Web
              path: #{workspace}
        YAML
        File.write(prompts_path, "custom: Default prompt for %{project_key}.\n")
        registry = HQ::Registry.new(path: config_path, system_prompts_path: prompts_path)
        service = HQ::RemoteService.new(registry: registry)
        server = HQ::RemoteServer.new

        request = HQ::RemoteServer.const_get(:Request).new(
          method: "POST",
          path: "/servers/target/agents/web-agent-1/messages",
          query: "force=true",
          headers: {},
          body: ""
        )
        proxied = server.send(
          :route,
          service,
          "POST",
          "/servers/target/agents/web-agent-1/messages",
          { "prompt" => "Hello target" },
          request
        )
        assert(proxied[:status] == 200, "expected broker proxy to preserve target success status")
        assert(proxied.dig(:body, "echoed_query") == "force=true",
               "expected broker proxy to preserve query string")
        assert(proxied.dig(:body, "echoed_body", "prompt") == "Hello target",
               "expected broker proxy to forward JSON request body")
        assert(requests.last.dig(:headers, "authorization") == "Bearer target-secret",
               "expected broker proxy to use configured target token")

        workspace_request = HQ::RemoteServer.const_get(:Request).new(
          method: "GET",
          path: "/servers/target/projects/web/workspace",
          query: "path=docs&limit=100",
          headers: {},
          body: ""
        )
        workspace_response = server.send(
          :route,
          service,
          "GET",
          workspace_request.path,
          {},
          workspace_request
        )
        assert(workspace_response.dig(:body, "workspace", "entries", 0, "path") == "docs/guide.md",
               "expected project workspace payloads to stay scoped to the target server")
        assert(requests.last[:path] == "/projects/web/workspace" &&
               requests.last[:query] == "path=docs&limit=100",
               "expected project workspace paths and pagination to survive broker routing")

        blob = server.send(:route, service, "GET", "/servers/target/attachments/image/blob", {}, nil)
        assert(blob[:content_type] == "image/png", "expected broker proxy to preserve target content type")
        assert(blob[:body] == "png-bytes", "expected broker proxy to pass non-JSON response bodies through")
        assert(blob.dig(:headers, "X-Content-Type-Options") == "nosniff",
               "expected broker proxy to preserve safe blob headers")

        unauthorized = server.send(:route, service, "GET", "/servers/target/agents/unauthorized", {}, nil)
        assert(unauthorized[:status] == 502, "expected target 401 to be mapped away from broker auth")
        assert(unauthorized.dig(:body, :error).include?("rejected broker credentials"),
               "expected target credential failures to be explicit")

        begin
          server.send(:route, service, "GET", "/servers/target/proxy/setup", {}, nil)
          raise "expected peer proxy to reject server-level routes"
        rescue HQ::RemoteServer::Error => e
          assert(e.status == 404, "expected peer proxy restriction to use not found")
        end
      end
    end
  ensure
    if old_token
      ENV["TYCHO_REMOTE_TARGET_TOKEN"] = old_token
    else
      ENV.delete("TYCHO_REMOTE_TARGET_TOKEN")
    end
  end

  def assert_remote_broker_proxies_loopback_peer_requests
    requests = []
    handler = lambda do |request|
      requests << request
      case [request[:method], request[:path]]
      when ["GET", "/agents"]
        {
          status: 200,
          content_type: "application/json",
          body: JSON.generate(agents: [{ key: "peer-agent-1", name: "Peer Agent" }])
        }
      else
        {
          status: 404,
          content_type: "application/json",
          body: JSON.generate(error: "missing #{request[:path]}")
        }
      end
    end

    with_fixture_http_server(handler) do |target_url|
      port = URI.parse(target_url).port
      key = "loopback-#{port}"
      with_remote_temp_store do |dir|
        workspace = File.join(dir, "workspace")
        write_project_workspace(workspace)
        registry = registry_for(dir, workspace)
        service = HQ::RemoteService.new(registry: registry)
        server = HQ::RemoteServer.new

        proxied = server.send(:route, service, "GET", "/servers/#{key}/agents", {}, nil)
        assert(proxied.dig(:body, "agents", 0, "key") == "peer-agent-1",
               "expected loopback peer API request to be proxied")
        assert(!requests.last.fetch(:headers, {}).key?("authorization"),
               "expected ad hoc loopback peer proxy to avoid forwarding browser authorization")
      end
    end
  end

  def assert_remote_broker_logs_recoverable_activity_5xx
    handler = lambda do |request|
      assert(request[:path] == "/activity", "expected focused peer activity request")
      {
        status: 503,
        content_type: "application/json",
        body: JSON.generate(error: "temporary failure for super-secret")
      }
    end

    with_fixture_http_server(handler) do |target_url|
      Dir.mktmpdir("tycho-peer-activity") do |dir|
        workspace = File.join(dir, "workspace")
        write_project_workspace(workspace)
        config_path = File.join(dir, "hq.yml")
        prompts_path = File.join(dir, "system_prompts.yml")
        File.write(config_path, <<~YAML)
          projects:
            - key: web
              name: Web
              path: #{workspace}
          remote_servers:
            - key: failing-peer
              name: Failing peer
              url: #{target_url}
        YAML
        File.write(prompts_path, "custom: Default prompt for %{project_key}.\n")
        registry = HQ::Registry.new(path: config_path, system_prompts_path: prompts_path)
        log_output = StringIO.new
        logger = Logger.new(log_output)
        broker = HQ::RemoteBroker.new(registry: registry, logger: logger)
        request = HQ::RemoteServer.const_get(:Request).new(
          method: "GET",
          path: "/servers/failing-peer/activity",
          headers: { "x-tycho-remote-server-token" => "super-secret" },
          body: ""
        )

        response = broker.proxy("failing-peer", "GET", "/activity", {}, request)
        assert(response[:status] == 503, "expected peer 5xx activity responses to remain recoverable broker results")
        log = log_output.string
        assert(log.include?("failing-peer") && log.include?("/activity") && log.include?("status=503") &&
               log.include?("treating as recoverable"),
               "expected peer activity failure logs to include safe peer, path, status, and recovery context")
        assert(!log.include?("super-secret"), "expected peer activity failure logs to omit credentials")
      end
    end
  end

  def assert_remote_server_persists_added_servers
    requests = []
    handler = lambda do |request|
      requests << request
      case [request[:method], request[:path]]
      when ["GET", "/agents"]
        unless request.dig(:headers, "authorization") == "Bearer target-secret"
          next({
            status: 401,
            content_type: "application/json",
            body: JSON.generate(error: "Unauthorized")
          })
        end
        {
          status: 200,
          content_type: "application/json",
          body: JSON.generate(agents: [{ key: "peer-agent-1", name: "Peer Agent" }])
        }
      when ["GET", "/agents"]
        unless request.dig(:headers, "authorization") == "Bearer target-secret"
          next({
            status: 401,
            content_type: "application/json",
            body: JSON.generate(error: "Unauthorized")
          })
        end
        {
          status: 200,
          content_type: "application/json",
          body: JSON.generate(agents: [{ key: "peer-agent-1", name: "Peer Agent" }])
        }
      else
        {
          status: 404,
          content_type: "application/json",
          body: JSON.generate(error: "missing #{request[:path]}")
        }
      end
    end

    with_fixture_http_server(handler) do |target_url|
      with_remote_temp_store do |dir|
        workspace = File.join(dir, "workspace")
        write_project_workspace(workspace)
        config_path = File.join(dir, "hq.yml")
        prompts_path = File.join(dir, "system_prompts.yml")
        File.write(config_path, <<~YAML)
          projects:
            - key: web
              name: Web
              path: #{workspace}
        YAML
        File.write(prompts_path, "custom: Default prompt for %{project_key}.\n")
        registry = HQ::Registry.new(path: config_path, system_prompts_path: prompts_path)
        service = HQ::RemoteService.new(registry: registry, server_url: "http://127.0.0.1:7373")
        server = HQ::RemoteServer.new

        created = server.send(:route, service, "POST", "/servers", {
          "name" => "tycho-peer",
          "url" => target_url,
          "token" => "target-secret"
        }, nil)

        assert(created[:status] == 201, "expected Remote server add route to create a persisted server")
        assert(created.dig(:body, :server, :key) == "tycho-peer",
               "expected persisted server key to derive from display name")
        persisted = YAML.safe_load(File.read(config_path), aliases: true)
        assert(persisted.dig("remote_servers", 0, "key") == "tycho-peer",
               "expected added server to persist to hq.yml")
        assert(persisted.dig("remote_servers", 0, "url") == target_url.sub(%r{/+\z}, ""),
               "expected persisted server URL to be normalized")
        assert(!persisted.dig("remote_servers", 0).key?("token"),
               "expected UI-entered server token to stay out of hq.yml")
        assert(!persisted.dig("remote_servers", 0).key?("token_encrypted"),
               "expected UI-entered server token to stay out of hq.yml")
        assert(!File.read(config_path).include?("target-secret"),
               "expected Remote server route to avoid writing UI-entered tokens")
        assert(requests.all? { |request| request.dig(:headers, "authorization") == "Bearer target-secret" },
               "expected broker requests to use the provided browser-local token")

        promoted = server.send(:route, service, "POST", "/servers/tycho-peer/credentials", {
          "token" => "target-secret"
        }, nil)
        credential_path = File.join(dir, "remote_credentials.json")
        assert(promoted[:status] == 200 && promoted.dig(:body, :credential, :state) == "verified",
               "expected browser promotion to verify and persist the credential")
        assert(File.stat(credential_path).mode & 0o777 == 0o600,
               "expected browser-promoted credentials to use private file permissions")
        assert(!promoted.dig(:body, :credential).to_s.include?("target-secret"),
               "expected credential metadata to omit token values")

        updated = server.send(:route, service, "PATCH", "/servers/tycho-peer", {
          "name" => "Studio Mac",
          "icon" => "computer"
        }, nil)
        assert(updated[:status] == 200, "expected Remote server identity update route to succeed")
        assert(updated.dig(:body, :server, :name) == "Studio Mac",
               "expected identity update route to return the new display name")
        assert(updated.dig(:body, :server, :icon) == "computer",
               "expected identity update route to return the new icon")
        persisted_after_update = YAML.safe_load(File.read(config_path), aliases: true)
        assert(persisted_after_update.dig("remote_servers", 0, "name") == "Studio Mac",
               "expected identity update route to persist the display name")
        assert(persisted_after_update.dig("remote_servers", 0, "icon") == "computer",
               "expected identity update route to persist the icon")
        assert(persisted_after_update.dig("remote_servers", 0, "url") == target_url.sub(%r{/+\z}, ""),
               "expected identity update route to preserve the remote URL")

        begin
          server.send(:route, service, "PATCH", "/servers/local", {
            "name" => "Local",
            "icon" => "server"
          }, nil)
          raise "expected local server identity update to fail"
        rescue HQ::RemoteServer::Error => e
          assert(e.status == 400, "expected local server identity update rejection to return bad request")
        end

        proxy_request = HQ::RemoteServer.const_get(:Request).new(
          method: "GET",
          path: "/servers/tycho-peer/agents",
          query: "",
          headers: {},
          body: ""
        )
        proxied = server.send(:route, service, "GET", "/servers/tycho-peer/agents", {}, proxy_request)
        assert(proxied.dig(:body, "agents", 0, "key") == "peer-agent-1",
               "expected the broker to use the Tycho-stored credential after browser promotion")

        deleted = server.send(:route, service, "DELETE", "/servers/tycho-peer", {}, nil)
        assert(deleted[:status] == 200, "expected Remote server delete route to succeed")
        persisted_after_delete = YAML.safe_load(File.read(config_path), aliases: true)
        assert(!persisted_after_delete.key?("remote_servers"),
               "expected deleted server to be removed from hq.yml")
        credentials_after_delete = JSON.parse(File.read(credential_path))
        assert(!credentials_after_delete.fetch("servers").key?("tycho-peer"),
               "expected deleting a peer to remove its Tycho-stored credential")
      end
    end
  end

  def assert_remote_server_allows_tailnet_ad_hoc_servers
    service = HQ::RemoteService.allocate
    service.send(:validate_ad_hoc_remote_url!, "http://vps-cd946cb7.tail952bf7.ts.net:7373")
    service.send(:validate_ad_hoc_remote_url!, "https://vps-cd946cb7.tail952bf7.ts.net")

    begin
      service.send(:validate_ad_hoc_remote_url!, "http://example.com:7373")
      raise "expected public ad hoc host to be rejected"
    rescue HQ::RemoteServer::Error => e
      assert(e.status == 400, "expected public ad hoc host rejection to return bad request")
      assert(e.message.include?("loopback or Tailscale MagicDNS"),
             "expected rejection to explain supported ad hoc host types")
    end
  end

  def assert_server_detects_unauthenticated_non_loopback_bind
    output = StringIO.new
    logger = Logger.new(StringIO.new)
    server = HQ::RemoteServer.new(host: "100.64.0.10", token: "", logger: logger, output: output)

    assert(server.send(:unauthenticated_non_loopback?), "expected tokenless non-loopback bind to be flagged")
  end

  def assert_serve_command_accepts_daemon_mode
    captured = nil
    out = StringIO.new
    err = StringIO.new
    status = HQ::ServeCommand.run(
      ["daemon", "--host", "127.0.0.1", "--port", "7474"],
      executable: "bin/tycho",
      command_prefix: ["serve"],
      out: out,
      err: err,
      server_starter: ->(**kwargs) { captured = kwargs }
    )

    assert(status == 0, "expected serve daemon parser to succeed")
    assert(err.string.empty?, "expected no parser errors, got #{err.string.inspect}")
    assert(captured.fetch(:daemonize) == true, "expected serve daemon to request daemon mode")
    assert(captured.fetch(:explicit_host) == true, "expected explicit host to be preserved")
    assert(captured.dig(:options, :host) == "127.0.0.1", "expected host option to be parsed")
    assert(captured.dig(:options, :port) == 7474, "expected port option to be parsed")
    assert(captured.fetch(:restart_command) == ["bin/tycho", "serve", "daemon", "--host", "127.0.0.1", "--port", "7474"],
           "expected daemon restart command to preserve original argv")
  end

  def assert_remote_push_subscription_lifecycle
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      registry = registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)
      config = service.push_config

      assert(config[:configured], "expected push config to be ready")
      assert(!config[:public_key].to_s.empty?, "expected push config to expose VAPID public key")
      assert(config[:magic_dns_https_required], "expected push config to require HTTPS for MagicDNS")

      saved = service.save_push_subscription(
        {
          "endpoint" => "https://push.example.test/subscription/1",
          "keys" => {
            "p256dh" => "p256dh-key",
            "auth" => "auth-key"
          }
        },
        user_agent: "Remote UI test"
      )
      assert(saved[:subscribed], "expected subscription save response")
      assert(saved[:subscription_count] == 1, "expected one enabled subscription")
      current_status = service.push_status("endpoint" => "https://push.example.test/subscription/1")
      assert(current_status[:subscribed],
             "expected push config to identify the current browser subscription")
      assert(current_status[:endpoint_host] == "push.example.test" && current_status[:user_agent] == "Remote UI test",
             "expected push status to expose provider and browser diagnostics")
      assert(!current_status.key?(:endpoint) && !current_status.key?(:p256dh) && !current_status.key?(:auth),
             "expected push status to keep capability URLs and encryption keys private")
      assert(!service.push_status("endpoint" => "https://push.example.test/subscription/other")[:subscribed],
             "expected push config not to confuse another browser subscription with this browser")

      disabled = service.disable_push_subscription("endpoint" => "https://push.example.test/subscription/1")
      assert(!disabled[:subscribed], "expected unsubscribe response")
      assert(disabled[:subscription_count].zero?, "expected disabled subscription to be excluded from count")
      assert(!service.push_status("endpoint" => "https://push.example.test/subscription/1")[:subscribed],
             "expected push config to expose a disabled browser subscription as inactive")
    end
  end

  def assert_remote_agent_push_notifications
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      notifier = RecordingPushNotifier.new
      activity_snapshot = HQ::AgentActivitySnapshot.new
      service = HQ::RemoteService.new(
        registry: registry,
        web_push_notifier: notifier,
        agent_activity_snapshot: activity_snapshot
      )
      started_at = Time.now - 60

      input_agent = stale_running_agent(
        key: "web-agent-1",
        name: "Web input",
        workspace: workspace,
        started_at: started_at,
        structured_result: {
          "status" => "input_required",
          "summary" => "Needs release confirmation",
          "inquiry" => { "message" => "Release now?" }
        }
      )
      finished_agent = stale_running_agent(
        key: "web-agent-2",
        name: "Web done",
        workspace: workspace,
        started_at: started_at
      )
      no_action_agent = stale_running_agent(
        key: "web-agent-3",
        name: "Web no action",
        workspace: workspace,
        started_at: started_at,
        structured_result: {
          "status" => "no_action_needed",
          "summary" => "Checked pull requests. Nothing needs action."
        }
      )
      HQ::AgentStore.new([]).save([input_agent, finished_agent, no_action_agent])
      [input_agent, finished_agent, no_action_agent].each do |agent|
        File.write(File.join(HQ::AGENT_LOGS_DIR, "#{agent.key}.status"), "0")
      end

      refreshed_agents = HQ::AgentStore.new([]).load
      refreshed_input_agent = refreshed_agents.find { |agent| agent.key == "web-agent-1" }
      assert(refreshed_input_agent.status == "awaiting-input",
             "expected a normal agent refresh to observe the completed inquiry run")
      assert(notifier.payloads.empty?,
             "expected the independent refresh not to have access to the push notifier")

      result = service.dispatch_agent_push_notifications!
      assert(result[:events] == 2, "expected two agent push events")
      input_activity = activity_snapshot.snapshot[:agents].find { |agent| agent[:key] == "web-agent-1" }
      assert(input_activity[:awaiting_input] && input_activity[:unread],
             "expected notification reconciliation to publish finalized inquiry activity")
      assert(notifier.payloads.length == 2, "expected two push payloads")
      assert(notifier.payloads.any? { |payload| payload[:title] == "Agent requires response" },
             "expected requires-response notification")
      assert(notifier.payloads.any? { |payload| payload[:title] == "Agent finished" },
             "expected finished notification")
      assert(notifier.payloads.all? { |payload| payload[:url].start_with?("/#agent/") },
             "expected notification click URLs to target agent detail")
      assert(notifier.payloads.all? { |payload| payload[:tag] == "hq:agents" },
             "expected agent notifications to share a group tag")
      assert(notifier.payloads.any? { |payload| payload[:renotify] == true && payload[:silent] == false },
             "expected input-required notifications to renotify audibly")
      assert(notifier.payloads.any? { |payload| payload[:silent] == true },
             "expected finished notifications to be silent")
      assert(notifier.payloads.all? { |payload| payload[:badge_count] == 2 },
             "expected agent notifications to carry the unread app badge count")
      agents = service.agents
      assert(agents.find { |agent| agent[:key] == "web-agent-1" }[:unread],
             "expected finalized input-required agent to be marked unread")
      assert(agents.find { |agent| agent[:key] == "web-agent-2" }[:unread],
             "expected finalized Codex agent to be marked unread")
      no_action_payload = agents.find { |agent| agent[:key] == "web-agent-3" }
      assert(no_action_payload[:last_result] == "no action", "expected no-action agent to expose no-action label")
      assert(!no_action_payload[:unread], "expected no-action agent to stay read")
      forged_no_action_event = HQ::AgentStore::PollEvent.new(
        agent_key: "web-agent-3",
        from_status: "running",
        to_status: "succeeded",
        run_count: 1
      )
      no_action_result = service.send(:dispatch_agent_push_events, [forged_no_action_event], agents: HQ::AgentStore.new([]).load)
      assert(no_action_result[:events].zero?, "expected no-action events to be ignored by push dispatch")
      assert(notifier.payloads.length == 2, "expected forged no-action event not to send a push payload")
      read_payload = service.mark_agent_read("web-agent-2")
      assert(!read_payload[:unread], "expected explicit reading mutation to clear unread state")
      read_agent = service.agents.find { |agent| agent[:key] == "web-agent-2" }
      assert(!read_agent[:unread], "expected explicit reading mutation to persist")

      service.dispatch_agent_push_notifications!
      assert(notifier.payloads.length == 2, "expected duplicate agent push events to be suppressed")
    end
  end

  def assert_remote_search_index_includes_agents_and_projects
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)
      service.create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Searchable Agent",
        "prompt" => "Work remotely.",
        "agent" => "codex"
      )

      index = service.search_index
      assert(index[:agents].any? { |agent| agent[:name] == "Searchable Agent" },
             "expected search index agents")
      assert(index[:projects].any? { |project| project[:key] == "web" },
             "expected search index projects")
    end
  end

  def assert_remote_skills_payload_uses_discovery
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      old_home = ENV["HOME"]
      home = File.join(dir, "home")
      ENV["HOME"] = home
      write_project_workspace(workspace)
      skill_dir = File.join(workspace, ".agents", "skills", "review")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), "# Review\n")
      user_skill_dir = File.join(home, ".agents", "skills", "teach")
      FileUtils.mkdir_p(user_skill_dir)
      File.write(File.join(user_skill_dir, "SKILL.md"), "# Teach\n")
      system_skill_dir = File.join(home, ".codex", "skills", ".system", "imagegen")
      FileUtils.mkdir_p(system_skill_dir)
      File.write(File.join(system_skill_dir, "SKILL.md"), "# Imagegen\n")
      opencode_skill_dir = File.join(workspace, ".opencode", "skills", "plan")
      FileUtils.mkdir_p(opencode_skill_dir)
      File.write(File.join(opencode_skill_dir, "SKILL.md"), "# Plan\n")
      registry = registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry: registry)

      payload = service.skills("web", "codex")
      assert(payload[:trigger] == "$", "expected Codex skill trigger")
      assert(payload[:skills].any? { |skill| skill["name"] == "review" }, "expected discovered skill")
      assert(payload[:skills].any? { |skill| skill["name"] == "teach" },
             "expected Codex discovery to include ~/.agents/skills")
      assert(payload[:skills].any? { |skill| skill["name"] == "imagegen" },
             "expected Codex discovery to include nested ~/.codex/skills")

      opencode_payload = service.skills("web", "opencode")
      assert(opencode_payload[:trigger] == "$", "expected OpenCode fallback skill trigger")
      assert(opencode_payload[:skills].any? { |skill| skill["name"] == "plan" },
             "expected OpenCode discovery to include workspace .opencode/skills")
      assert(opencode_payload[:skills].any? { |skill| skill["name"] == "teach" },
             "expected OpenCode discovery to include ~/.agents/skills")

      pi_skill_dir = File.join(home, ".pi", "agent", "skills", "operate")
      FileUtils.mkdir_p(pi_skill_dir)
      File.write(File.join(pi_skill_dir, "SKILL.md"), "# Operate\n")
      pi_payload = service.skills("web", "pi")
      assert(pi_payload[:trigger] == "/skill:", "expected Pi skill command prefix")
      assert(pi_payload[:skills].any? { |skill| skill["name"] == "operate" },
             "expected Pi discovery to include ~/.pi/agent/skills")
      assert(pi_payload[:skills].any? { |skill| skill["name"] == "teach" },
             "expected Pi discovery to include ~/.agents/skills")
    ensure
      ENV["HOME"] = old_home
    end
  end

  def assert_remote_ui_routes_load_without_auth
    server = HQ::RemoteServer.new(token: "secret", logger: Logger.new(StringIO.new), output: StringIO.new)
    ui_request = HQ::RemoteServer.const_get(:Request).new(
      method: "GET",
      path: "/",
      headers: {},
      body: ""
    )

    assert(server.send(:ui_request?, ui_request), "expected / to be recognized as a UI route")
    response = server.send(:route_ui, "/")
    assert(response[:content_type].include?("text/html"), "expected / to return HTML")
    assert(response[:body].include?("Tycho - Factorio for Agents"), "expected / body to include app shell title")
    legacy_request = HQ::RemoteServer.const_get(:Request).new(
      method: "GET",
      path: "/ui",
      headers: {},
      body: ""
    )
    assert(server.send(:ui_request?, legacy_request), "expected /ui compatibility route to be recognized")
    legacy_response = server.send(:route_ui, "/ui")
    assert(legacy_response[:content_type].include?("text/html"), "expected /ui compatibility route to return HTML")
    assert(response[:body].include?('name="theme-color" content="#282a36"'),
           "expected root shell to expose a PWA theme color")
    assert(response[:body].include?('id="tycho-boot-shell"') &&
           response[:body].include?('data-state="loading"') &&
           response[:body].include?('role="status" aria-live="polite" aria-atomic="true"'),
           "expected root shell to provide an accessible server-rendered loading surface")
    assert(response[:body].include?('id="tycho-boot-retry"') &&
           response[:body].include?('class="tycho-boot-mark"'),
           "expected root shell to expose branded loading and recovery controls before application JavaScript")
    assert(response[:body].include?('@media (prefers-reduced-motion: reduce)') &&
           response[:body].include?('animation: none;'),
           "expected root shell to provide a static reduced-motion loading state")
    assert(response[:body].include?('content="width=device-width, initial-scale=1, viewport-fit=cover"'),
           "expected root shell viewport to expose iOS safe-area insets")
    assert(response[:body].match?(%r{href="/manifest\.webmanifest\?v=[0-9a-f]{12}"}),
           "expected root shell to link a versioned web app manifest")
    assert(response[:body].match?(%r{href="/favicon\.png\?v=[0-9a-f]{12}"}),
           "expected root favicon reference to use the Remote UI logo")
    assert(response[:body].match?(%r{href="/apple-touch-icon\.png\?v=[0-9a-f]{12}"}),
           "expected root shell to expose an Apple touch icon")
    assert(response[:body].match?(%r{src="/remote-logo\.png\?v=[0-9a-f]{12}"}),
           "expected root shell to render the Remote UI logo")
    assert(response[:body].include?('aria-controls="unread-agents-panel"'),
           "expected root shell logo to control the unread agents panel")
    assert(response[:body].include?('aria-label="Open agent switcher"'),
           "expected root shell logo to be clickable as an agent switcher")
    assert(response[:body].include?('id="unread-agents-panel"'),
           "expected root shell to expose the agent switcher popup")
    assert(response[:body].include?('id="growl"'),
           "expected root shell to expose growl notifications")
    assert(response[:body].include?("pull-refresh-spinner ui-icon"),
           "expected root shell to render the pull refresh hourglass icon")
    assert(response[:body].match?(%r{href="/ui\.css\?v=[0-9a-f]{12}"}),
           "expected root CSS reference to be asset-versioned")
    assert(response[:body].match?(%r{src="/ui\.js\?v=[0-9a-f]{12}"}),
           "expected root JavaScript reference to be asset-versioned")
    assert(!response[:body].include?("project-edit-button"), "expected Project edit to live in the shared More menu")
    assert(response[:body].include?("header-more-button"), "expected root shell to expose header More actions")
    assert(response[:body].include?('id="header-view-menu"'), "expected root shell to expose contextual view controls")
    assert(response[:body].include?('id="header-schedule-menu"'),
           "expected root shell to expose contextual schedule controls")
    assert(response[:body].include?('id="header-more-panel"'), "expected root shell to expose the header More menu panel")
    assert(response[:body].include?('data-overlay-surface="header-more"') &&
           response[:body].include?('aria-haspopup="menu"'),
           "expected the header More menu to use the shared overlay contract")
    assert(response[:body].include?('id="header-more-badge"'), "expected root shell to expose the header More badge")
    assert(response[:body].include?('id="quick-agent-fab"'), "expected root shell to expose New agent launch")
    assert(response[:body].include?('class="quick-agent-fab-label"'),
           "expected the New agent launch to expose a contextual text label")
    assert(response[:body].include?('id="quick-agent-dialog"'), "expected root shell to expose New agent modal")
    assert(response[:body].include?('aria-label="New agent"'), "expected the create-agent dialog to use consistent naming")
    assert(response[:body].include?('id="confirmation-dialog"') &&
           response[:body].include?('aria-labelledby="confirmation-title"') &&
           response[:body].include?('aria-describedby="confirmation-description"'),
           "expected the root shell to expose the shared labeled confirmation dialog")
    assert(response[:body].include?('data-tab="settings"'), "expected root shell to expose Settings navigation")
    assert(response[:body].include?("<span>Settings</span>"), "expected root shell to label setup navigation as Settings")
    assert(!response[:body].include?('data-tab="search"'), "expected root shell to remove Search navigation")
    assert(!response[:body].include?('data-tab="projects"'), "expected root shell to remove Projects navigation")
    assert(response[:body].include?("<svg class=\"ui-icon\""), "expected root shell controls to use SVG icons")
    %w[‹ ● ⌕ ▦ ⚙].each do |glyph|
      assert(!response[:body].include?(glyph), "expected root shell to avoid text icon glyph #{glyph.inspect}")
    end
    assert(!response[:body].include?("refresh-button"), "expected root shell to omit the header refresh button")

    design_system_request = HQ::RemoteServer.const_get(:Request).new(
      method: "GET",
      path: "/design-system",
      headers: {},
      body: ""
    )
    assert(server.send(:ui_request?, design_system_request),
           "expected /design-system to be recognized as a public UI route")
    design_system = server.send(:route_ui, "/design-system")
    assert(design_system[:content_type].include?("text/html"),
           "expected /design-system to return HTML")
    assert(design_system[:body].include?("Tycho Design System"),
           "expected the design-system preview to identify itself")
    assert(design_system[:body].include?('class="ui-button" data-variant="brand"'),
           "expected the design-system preview to include a semantic primary action")
    assert(design_system[:body].include?('aria-describedby="preview-prompt-error"'),
           "expected the design-system preview to connect invalid fields and errors")
    assert(design_system[:body].include?("Menu overlay") &&
           design_system[:body].include?('class="ui-overlay-surface"'),
           "expected the design-system preview to document menu overlays")
    assert(design_system[:body].include?("Confirmation flow") &&
           design_system[:body].include?("ui-confirmation-dialog__panel"),
           "expected the design-system preview to document consequential confirmations")
    assert(design_system[:body].include?("Detail header") &&
           design_system[:body].include?('class="ui-detail-header ui-surface"') &&
           design_system[:body].include?("ui-detail-header__metadata"),
           "expected the design-system preview to document focused-route header anatomy")
    assert(design_system[:body].include?("Section navigation") &&
           design_system[:body].include?('class="ui-section-nav"') &&
           design_system[:body].include?('class="ui-form-section-heading"'),
           "expected the design-system preview to document shared composite structure")
    assert(design_system[:body].include?("Searchable collection") &&
           design_system[:body].include?('class="ui-search-field"') &&
           design_system[:body].include?('class="ui-collection-summary"'),
           "expected the design-system preview to document search and result-feedback structure")
    assert(design_system[:body].include?("Metadata badges") &&
           design_system[:body].scan('class="ui-badge ui-metadata-badge"').length >= 5 &&
           design_system[:body].include?("Health, urgency, progress, selection, and filtering"),
           "expected the design-system preview to distinguish metadata from product status")
    assert(design_system[:body].include?('class="ui-empty-state" data-state="empty"') &&
           design_system[:body].include?('class="ui-empty-state ui-loading-state tycho-loading-state"') &&
           design_system[:body].include?('role="status" aria-live="polite" aria-atomic="true"'),
           "expected the design-system preview to distinguish empty and announced loading states")
    assert(design_system[:body].match?(%r{href="/ui\.css\?v=[0-9a-f]{12}"}),
           "expected the design-system preview stylesheet to be asset-versioned")

    service_worker = server.send(:route_ui, "/service-worker.js")
    assert(service_worker[:content_type].include?("javascript"), "expected service worker route to return JavaScript")
    assert(service_worker.dig(:headers, "Service-Worker-Allowed") == "/",
           "expected the service worker route to declare root scope")
    assert(service_worker.dig(:headers, "Cache-Control").include?("no-cache"),
           "expected the browser to revalidate service worker updates")
    assert(service_worker.dig(:headers, "X-Tycho-Asset-Version") == HQ::RemoteUI.asset_version,
           "expected service worker responses to identify their loaded daemon build")
    assert(service_worker[:body].include?("skipWaiting"), "expected service worker updates to activate immediately")
    assert(service_worker[:body].include?("clients.claim"), "expected service worker updates to claim active clients")
    assert(service_worker[:body].include?("showNotification"), "expected service worker to display push notifications")
    assert(service_worker[:body].include?('payload.title || "Tycho"'),
           "expected service worker push fallback title to use Tycho")
    assert(service_worker[:body].include?('payload.body || "Tycho has an update."'),
           "expected service worker push fallback body to use Tycho")
    assert(service_worker[:body].include?('icon: "/pwa-icon-192.png"'),
           "expected service worker notifications to use the PWA logo icon")
    assert(service_worker[:body].include?("payload.silent === true"),
           "expected service worker notifications to support silent pushes")
    assert(service_worker[:body].include?("Boolean(payload.renotify && payload.tag)"),
           "expected service worker notifications to support grouped renotify")
    assert(service_worker[:body].include?("syncAppBadge(payload.badge_count)"),
           "expected service worker pushes to sync the app badge count")
    assert(service_worker[:body].include?("setAppBadge"),
           "expected service worker to use the Badging API when available")

    css = server.send(:route_ui, "/ui.css")
    assert(css[:content_type].include?("text/css"), "expected /ui.css to return CSS")
    %w[
      --ds-background-canvas
      --ds-text-primary
      --ds-action-brand
      --ds-feedback-danger
      --ds-focus-ring
      --ds-touch-target
      --ds-z-dialog
    ].each do |token|
      assert(css[:body].include?(token), "expected Remote UI CSS to expose semantic token #{token}")
    end
    %w[
      .ui-stack
      .ui-cluster
      .ui-grid
      .ui-surface
      .ui-button
      .ui-icon-button
      .ui-field
      .ui-input
      .ui-alert
      .ui-badge
      .ui-metadata-badge
      .ui-spinner
      .ui-skeleton
      .ui-empty-state
      .ui-loading-state
      .ui-overlay-surface
      .ui-confirmation-dialog
      .ui-form-layout
      .ui-form-section-heading
      .ui-form-actions
      .ui-section-nav
      .ui-section-panel
      .ui-detail-header
      .ui-detail-header__back
      .ui-detail-header__identity
      .ui-detail-header__text
      .ui-detail-header__title
      .ui-detail-header__metadata
      .ui-detail-header__actions
      .ui-detail-header__action
      .ui-searchable-collection
      .ui-collection-toolbar
      .ui-search-field
      .ui-collection-summary
      .ui-collection-results
      .ui-collection-group
    ].each do |selector|
      assert(css[:body].include?(selector), "expected Remote UI CSS to include #{selector}")
    end
    assert(css[:body].include?(".ui-status") &&
           css[:body].include?('.ui-badge[data-intent="active"]') &&
           css[:body].include?('.ui-badge[data-intent="neutral"]'),
           "expected shared badges to cover the complete product status taxonomy")
    assert(css[:body].include?(".ui-metadata-badge") &&
           css[:body].include?(".pill.ui-metadata-badge") &&
           css[:body].include?("var(--ds-background-surface-sunken)"),
           "expected neutral metadata badges to remain visually separate from semantic status")
    assert(css[:body].include?("@media (prefers-reduced-motion: reduce)"),
           "expected shared motion to respect reduced-motion preferences")
    assert(css[:body].include?("@media (forced-colors: active)"),
           "expected shared controls to retain boundaries in forced-colors mode")
    %w[#282a36 #f8f8f2 #bd93f9 #ff79c6].each do |color|
      assert(css[:body].include?(color), "expected Remote UI CSS to include Dracula color #{color}")
    end
    assert(css[:body].include?("color-scheme: dark"), "expected Remote UI CSS to use the Dracula dark scheme")
    assert(css[:body].include?("--safe-area-top: env(safe-area-inset-top, 0px);"),
           "expected Remote UI to reserve iOS top safe-area space")
    assert(css[:body].include?("padding-top: var(--safe-area-top);"),
           "expected Remote UI headers to absorb iOS safe-area top padding")
    assert(css[:body].include?("top: 0;"),
           "expected sticky and fixed headers to own their safe-area padding instead of being offset")
    assert(css[:body].include?(".agent-dock"), "expected Agent detail to have a bottom dock")
    assert(css[:body].include?("position: fixed"), "expected Agent detail dock to stay pinned to the viewport")
    assert(css[:body].include?(".agent-floating-actions"),
           "expected Agent detail shortcuts to float above the dock")
    assert(css[:body].include?(".go-recent-fab"), "expected Agent detail to include Go to recent")
    assert(css[:body].include?(".agent-settings-panel"), "expected Agent settings to render in the header")
    assert(css[:body].include?(".agent-ownership-badge.takeover"),
           "expected takeover relationships to have a distinct visual state")
    assert(css[:body].include?(".header-more-panel"), "expected header More menus to render as dropdown panels")
    assert(css[:body].include?(".more-menu-item"), "expected header More menus to style compact menu rows")
    assert(css[:body].include?(".more-menu-item.single-line"),
           "expected single-action More menus to use compact rows")
    assert(css[:body].include?(".more-menu-separator"),
           "expected Conversation More menu groups to support separators")
    assert(css[:body].include?(".header-more-badge"),
           "expected header More menus to expose badge styling")
    assert(css[:body].include?("#header-more-button") && css[:body].include?("border: 0;"),
           "expected the header More button to be borderless")
    assert(css[:body].include?(".header-schedule-control") && css[:body].include?(".header-schedule-popover"),
           "expected scheduled agent headers to expose a schedule action menu")
    assert(css[:body].include?(".header-schedule-control.info > summary") &&
           css[:body].include?("color: var(--info);"),
           "expected scheduled agent header icons to match informational agent status")
    assert(css[:body].include?(".status-mark.info"),
           "expected informational agent list icons to match their status pills")
    assert(css[:body].include?(".growl"), "expected Remote UI to style growl notifications")
    assert(css[:body].include?(".agent-sort-menu"), "expected Remote UI to style agent sort dropdowns")
    assert(css[:body].include?(".onboarding-cli-guide") && css[:body].include?(".onboarding-cli-options"),
           "expected Remote UI to style the onboarding CLI guide")
    assert(css[:body].include?(".agent-sort-trigger"), "expected Remote UI to style icon-only sort triggers")
    assert(css[:body].include?(".agent-sort-option"), "expected Remote UI to style text sort options")
    assert(css[:body].include?(".agent-ledger") &&
           css[:body].include?(".agent-ledger .agent-group.empty"),
           "expected grouped Agents results to use one compact ledger with one-line empty projects")
    assert(!css[:body].include?(".agent-settings-actions"),
           "expected Agent settings to move edit/archive actions into the More menu")
    assert(css[:body].include?(".agent-form"), "expected Remote UI to style agent lifecycle forms")
    assert(css[:body].include?("form.form-pending"),
           "expected Remote UI to visibly disable submitted forms while requests are pending")
    assert(css[:body].include?(".inline-icon-button"), "expected Remote UI action buttons to support SVG icons")
    assert(css[:body].include?("button:not(:disabled)") &&
           css[:body].include?("cursor: pointer"),
           "expected enabled button-like controls to show a pointer cursor")
    assert(css[:body].include?(".agent-summary-viewer"), "expected Agent summary to render as a focused page")
    assert(css[:body].include?("max-width: 72ch"),
           "expected Agent summary text to keep a readable measure")
    assert(css[:body].include?(".inquiry-form"), "expected Remote UI to style structured inquiry forms")
    assert(css[:body].include?(".inquiry-banner"), "expected Remote UI inquiry forms to show a decision banner")
    assert(css[:body].include?(".inquiry-mark"), "expected Remote UI inquiry forms to style the inquiry icon")
    assert(css[:body].include?("grid-template-columns: auto minmax(0, 1fr)"),
           "expected inquiry banners to align the icon beside the prompt")
    assert(css[:body].include?(".inquiry-choice-list"), "expected Remote UI inquiry forms to style multi-select choices")
    assert(css[:body].include?(".message.inquiry-response"),
           "expected Remote UI inquiry replies to use distinct message styling")
    assert(css[:body].include?(".message.user.inquiry-response .message-role"),
           "expected Remote UI inquiry reply headers to have dedicated alignment")
    assert(css[:body].include?("justify-content: flex-end"),
           "expected Remote UI inquiry reply headers to stay right aligned")
    assert(css[:body].include?(".parsed-json-key"),
           "expected Remote UI parsed reply keys to have dedicated styling")
    assert(css[:body].include?("font-weight: 700"),
           "expected Remote UI parsed reply keys to use header-style font weight")
    assert(css[:body].include?("text-align: left"),
           "expected Remote UI parsed reply keys to align left")
    assert(css[:body].include?(".parsed-json-value"),
           "expected Remote UI parsed reply answers to have dedicated styling")
    assert(css[:body].include?(".parsed-json-field + .parsed-json-field"),
           "expected Remote UI parsed reply fields to use explicit compact spacing")
    assert(css[:body].include?(".row-title .relative-time.fresh"),
           "expected Remote UI to color very recent list timestamps")
    assert(css[:body].include?(".row-title .relative-time.recent"),
           "expected Remote UI to color recent list timestamps")
    assert(css[:body].include?("max-height: min(72dvh, 620px)"),
           "expected mobile inquiry docks to stay within a compact viewport")
    assert(css[:body].include?("max-height: min(24dvh, 220px)"),
           "expected mobile inquiry fields to scroll in a compact viewport")
    assert(css[:body].include?("-webkit-line-clamp: 3"),
           "expected mobile inquiry banners to avoid consuming the dock")
    assert(css[:body].include?("@keyframes poll-refresh-hourglass"),
           "expected refresh indicators to use the hourglass animation")
    assert(css[:body].include?("transform: rotate(.5turn)"),
           "expected refresh hourglass animation to rotate by half a turn")
    assert(css[:body].include?(".subtitle-status"),
           "expected header subtitles to reserve a persistent icon slot")
    assert(css[:body].include?("grid-template-columns: 14px minmax(0, 1fr)"),
           "expected header subtitle text to keep its position during refresh")
    assert(css[:body].include?("margin-left: 28px"),
           "expected user chat messages to be offset from the left")
    assert(css[:body].include?("margin-right: 28px"),
           "expected non-user chat messages to be offset from the right")
    assert(css[:body].include?("justify-self: end"),
           "expected user chat messages to align right")
    assert(css[:body].include?(".message.user .message-content"),
           "expected user chat message content to have dedicated alignment")
    assert(css[:body].include?(".message.user .message-content {\n  text-align: left;"),
           "expected user chat message text to stay readable with left alignment")
    assert(css[:body].include?(".message.user.pending"),
           "expected pending user chat messages to pulse while sending")
    assert(css[:body].include?(".message-send-status"),
           "expected pending user chat messages to show a sending status outside the bubble")
    assert(css[:body].include?(".tycho-loading-logo") && css[:body].include?("@keyframes tycho-loading-pulse"),
           "expected Remote UI loading states to animate the Tycho logo")
    assert(css[:body].include?(".message-content.markdown-message-content"),
           "expected assistant and legacy summary chat messages to render markdown with message-scoped layout")
    assert(css[:body].include?(".message-content {\n  min-width: 0;"),
           "expected chat message content to allow markdown blocks to shrink inside the viewport")
    assert(css[:body].include?(".message-markdown-viewer"),
           "expected assistant and legacy summary chat markdown to have compact message styling")
    assert(!css[:body].include?(".message.user .block-menu-popover"),
           "expected user message action menus to keep the shared inward alignment")
    assert(css[:body].include?(".agent-summary-markdown-viewer"),
           "expected Agent summary markdown to use focused page styling")
    assert(css[:body].include?("font-weight: 700"),
           "expected chat labels to render bold")
    assert(css[:body].include?(".message-group"),
           "expected internal chat messages to render in collapsed groups")
    assert(css[:body].include?(".message-group > summary"),
           "expected collapsed chat groups to expose a summary row")
    assert(css[:body].include?(".message-group {\n  width: calc(100% - 28px);\n  margin-right: 28px;\n  overflow: visible;"),
           "expected Agent activity groups to keep copy menus visible outside the unified box")
    assert(css[:body].include?(".message-group .message + .message"),
           "expected Agent activity rows to use horizontal separators instead of nested cards")
    assert(css[:body].include?(".message-group .message-role {\n  gap: 5px;\n  color: color-mix(in srgb, var(--muted) 82%, transparent);"),
           "expected Agent activity roles to use subtle text")
    assert(css[:body].include?(".message-group .message-content {\n  color: color-mix(in srgb, var(--text) 76%, var(--muted));\n  font-size: 14px;"),
           "expected Agent activity rows to use readable subtle text")
    assert(css[:body].include?(".turn-completed-metrics"),
           "expected Codex turn completion metrics to have dedicated layout")
    assert(css[:body].include?(".turn-completed-message-content {\n  display: block;\n  white-space: normal;"),
           "expected usage metric rows to avoid inherited pre-wrap blank lines")
    assert(css[:body].include?(".turn-completed-metric strong"),
           "expected Codex turn completion metrics to style compact values")
    assert(css[:body].include?(".attachment-flyout"), "expected Agent detail to style attachment flyouts")
    assert(css[:body].include?("max-block-size: min(46dvh, 340px)") &&
           css[:body].include?("overflow: hidden;"),
           "expected attachment flyouts to shrink-wrap until their viewport-aware height cap")
    assert(css[:body].include?(".attachment-list {\n  display: grid;\n  min-block-size: 0;\n  overflow-y: auto;") &&
           css[:body].include?("overscroll-behavior: contain;"),
           "expected attachment flyout lists to own bounded scrolling")
    assert(css[:body].include?("max-block-size: min(64dvh, 520px)"),
           "expected mobile attachment flyouts to use a viewport-aware height cap")
    assert(css[:body].include?(".attachment-item"), "expected Agent detail attachments to render as rows")
    assert(css[:body].include?(".attachment-main"), "expected Agent detail attachment rows to separate links from actions")
    assert(css[:body].include?(".attachment-actions"), "expected Agent detail attachment rows to expose row actions")
    assert(css[:body].include?(".attachment-viewer-actions"), "expected Attachment detail to style refresh/delete actions")
    assert(css[:body].include?(".attachment-viewer-menu") &&
           css[:body].include?(".attachment-viewer-menu-popover"),
           "expected Attachment detail actions to use a compact context menu")
    assert(css[:body].include?(".attachment-nav-drawer"), "expected Attachment detail to style the navigation drawer")
    assert(css[:body].include?(".attachment-nav-item.active"), "expected Attachment detail navigation to highlight the current item")
    assert(css[:body].include?(".pending-attachments"), "expected Agent detail to style pending prompt attachments")
    assert(css[:body].include?(".attachment-upload-button"), "expected Agent detail to style upload attachment controls")
    assert(css[:body].include?(".composer-drop-overlay"),
           "expected Agent detail composer to style drag-and-drop attachment overlays")
    assert(css[:body].include?(".composer.drop-active .composer-drop-overlay"),
           "expected Agent detail composer to reveal the drag-and-drop attachment overlay while active")
    assert(css[:body].include?(".message-attachments"), "expected chat messages to style attached prompt files")
    assert(css[:body].include?(".summary-attachment-menu"), "expected Conversation summaries to style attachment menus")
    assert(css[:body].include?(".summary-attachment-menu-popover"),
           "expected Conversation summary attachments to open as a menu")
    assert(css[:body].include?(".summary-attachment-overlay-root") &&
           css[:body].include?("position: fixed") &&
           css[:body].include?("z-index: var(--ds-z-dropdown)"),
           "expected Conversation summary attachment menus to use a viewport overlay on the shared dropdown layer")
    assert(css[:body].include?(".summary-attachment-list-full"),
           "expected detailed Summary pages to render full attachment lists")
    assert(css[:body].include?(".summary-attachment-item") &&
           css[:body].include?(".summary-attachment-download"),
           "expected Summary attachments to pair detail links with quick download actions")
    assert(css[:body].include?(".summary-attachment-row"),
           "expected Summary attachments to render as block rows")
    assert(css[:body].include?(".attachment-text-viewer"), "expected Attachment detail to style plain text")
    assert(css[:body].include?(".attachment-image-viewer"), "expected Attachment detail to style image previews")
    assert(css[:body].include?(".html-attachment-frame"),
           "expected Attachment detail to style sandboxed HTML previews")
    assert(css[:body].include?(".code-viewer") && css[:body].include?(".code-line::before"),
           "expected Attachment detail to style syntax-highlighted text previews with line numbers")
    assert(css[:body].include?(".agent-attachment-shell"),
           "expected Agent detail to replace the conversation with an attachment viewer")
    assert(!css[:body].include?(".agent-view-switch"),
           "expected Agent detail attachment view to omit the old conversation header")
    assert(css[:body].include?(".agent-view-toggle-button"),
           "expected Agent detail attachment view to expose icon-only conversation switching")
    assert(css[:body].include?(".markdown-viewer"), "expected Attachment detail to style rendered markdown")
    assert(css[:body].include?(".markdown-viewer {\n  min-width: 0;\n  max-width: 100%;"),
           "expected markdown attachments to use the available viewer width")
    assert(css[:body].include?(".markdown-viewer th"),
           "expected rendered markdown tables to style header cells")
    assert(css[:body].include?("border-collapse: collapse"),
           "expected rendered markdown tables to use collapsed borders")
    assert(css[:body].include?("text-underline-offset: 3px"),
           "expected rendered markdown links to have readable underline spacing")
    assert(css[:body].include?("white-space: pre"),
           "expected rendered markdown code blocks to preserve whitespace")
    assert(css[:body].include?(".markdown-code-menu") && css[:body].include?(".markdown-code-menu-popover"),
           "expected rendered Markdown code blocks to style compact action menus")
    assert(css[:body].include?("overflow-wrap: anywhere"),
           "expected rendered markdown inline code to avoid horizontal page overflow")
    assert(css[:body].include?(".skill-flyout"), "expected skills to use a floating picker")
    assert(css[:body].include?(".skill-autocomplete"), "expected prompt skill autocomplete to use a floating picker")
    assert(css[:body].include?(".skill-autocomplete-action"), "expected skill autocomplete commands to have distinct styling")
    assert(css[:body].include?("min-height: min(180px, 42dvh)"),
           "expected the skill picker to show multiple skills before scrolling")
    assert(css[:body].include?(".agent-running-indicator"),
           "expected running agents to show an animated composer status icon")
    assert(css[:body].include?(".ui-icon"), "expected shared SVG icon styling")
    assert(css[:body].include?(".header-mark .brand-logo"), "expected Remote UI logo image styling")
    assert(css[:body].include?(".keyboard-shortcut-hint"),
           "expected Remote UI keyboard shortcut hints to have shared styling")
    assert(css[:body].include?(".shortcut-hints-visible .keyboard-shortcut-hint"),
           "expected Remote UI shortcut hints to appear while the modifier key is held")
    assert(css[:body].include?(".logo-alert-badge"), "expected Remote UI logo to style an unread count badge")
    assert(css[:body].include?(".header-mark.unread-panel-open"),
           "expected Remote UI logo to highlight while the unread popup is open")
    assert(css[:body].include?(".unread-agents-panel"), "expected Remote UI to style the unread agents popup")
    assert(css[:body].include?("border: 1px solid color-mix(in srgb, var(--pink) 62%, transparent);"),
           "expected unread popup to use the open logo border color")
    assert(css[:body].include?("0 0 0 4px color-mix(in srgb, var(--pink) 18%, transparent),"),
           "expected unread popup to use the open logo highlight ring")
    assert(css[:body].include?(".header-mark {\n  position: relative;"),
           "expected Remote UI header logo to have dedicated borderless styling")
    assert(!css[:body].include?(".app-header.header-hidden"),
           "expected detail headers to stay visible instead of using a hide class")
    assert(css[:body].include?(".app-header.detail-header"),
           "expected detail headers to be fixed to the top")
    assert(css[:body].include?(".content.detail-page"),
           "expected detail pages to reserve space for fixed headers")
    assert(css[:body].include?("var(--agent-dock-height, 220px) + 8px"),
           "expected Agent detail content to reserve space for the dock")
    assert(css[:body].include?(".agent-dock:has(.skill-flyout:not(.hidden))"),
           "expected the skill flyout to stack above the floating Summary shortcut")
    assert(css[:body].include?(".agent-dock:has(.attachment-flyout:not(.hidden))"),
           "expected the attachment flyout to stack above the skill flyout")
    assert(css[:body].include?(".agent-dock:has(.attachment-flyout:not(.hidden)) {\n    overflow: visible;"),
           "expected mobile attachment flyouts to escape the scrollable composer dock")
    assert(!css[:body].include?(".server-lifecycle-card"),
           "expected Settings restart readiness to use the normal automation readiness card")
    assert(css[:body].include?("#settings-push-notifications"),
           "expected Settings push section to support header menu scrolling")
    assert(css[:body].include?("grid-template-columns: repeat(3, minmax(0, 1fr));"),
           "expected bottom navigation to use the simplified three-tab layout")
    assert(css[:body].include?(".bulk-action-bar"),
           "expected Agents tab to style bulk archive controls")
    assert(css[:body].include?(".quick-agent-fab"),
           "expected Remote UI to style the Quick Agent floating action button")
    assert(css[:body].include?(".quick-agent-dialog"),
           "expected Remote UI to style the Quick Agent modal")
    assert(css[:body].include?("height: 100dvh;") &&
           css[:body].include?(".quick-agent-dialog[open] {\n    position: fixed;\n    inset: 0;") &&
           css[:body].include?("overflow-y: auto;") &&
           css[:body].include?("overscroll-behavior: contain;"),
           "expected the mobile Quick Agent form to fill and scroll within the viewport")
    assert(css[:body].include?("--touch-target: 44px") && css[:body].include?("--control-height: 44px"),
           "expected audited Remote UI controls to share accessible sizing tokens")
    assert(css[:body].include?(".top-actions .search-box"),
           "expected Agents tab search to flex inside the action row")
    assert(css[:body].include?(".top-actions {\n  flex-wrap: nowrap;"),
           "expected Agents tab search and toolbar controls to stay on one row")
    assert(css[:body].include?("flex: 1 1 auto;"),
           "expected Agents tab search to shrink instead of forcing toolbar wrapping")
    assert(css[:body].include?(".agent-toolbar-actions"),
           "expected Agents tab toolbar actions to align independently from the search width")
    assert(css[:body].include?(".agent-toolbar-actions {\n  display: inline-flex;\n  flex: 0 0 auto;"),
           "expected Agents tab toolbar actions to keep fixed width beside search")
    assert(css[:body].include?(".ui-collection-toolbar {\n  position: sticky;") &&
           css[:body].include?("top: var(--app-header-height, 64px);"),
           "expected the Agents filter toolbar to stay below the sticky app header")
    assert(css[:body].include?(".agent-mobile-toolbar-menu") &&
           css[:body].include?(".agent-toolbar-actions {\n    display: none;"),
           "expected narrow Agents toolbars to collapse desktop actions into a context menu")
    assert(css[:body].include?(".agent-bulk-select-button"),
           "expected Agents tab to style the icon-only bulk selection control")
    assert(css[:body].include?(".agent-bulk-menu"),
           "expected Agents tab to style bulk action dropdowns")
    assert(!css[:body].include?(".agent-bulk-trigger"),
           "expected the bulk selector itself to anchor the bulk action dropdown")
    assert(css[:body].include?(".selectable-agent-row"),
           "expected Agents tab to style selectable bulk archive rows")
    assert(css[:body].include?(".compact-actions"),
           "expected Hidden settings rows to support compact action buttons")
    assert(css[:body].include?(".schedule-card-body") && css[:body].include?("padding: 0;"),
           "expected Schedule block body to remove extra card padding")
    assert(css[:body].include?(".schedule-details") && css[:body].include?("margin: 12px 0 0;"),
           "expected Schedule details wrapper to preserve compact top breathing room")
    assert(css[:body].include?(".schedule-disclosure") && css[:body].include?("position: absolute"),
           "expected Schedule block to pin a visible collapsible disclosure control")
    assert(css[:body].include?(".schedule-management-actions") && css[:body].include?("justify-content: flex-end"),
           "expected Schedule management actions to align right")
    assert(css[:body].include?("align-items: center;") && css[:body].include?(".schedule-action-menu"),
           "expected Schedule daemon menu to align with the New schedule button")
    assert(css[:body].include?(".schedule-row") && css[:body].include?("grid-template-columns: auto minmax(0, 1fr) auto"),
           "expected Schedule rows to reserve a right-side action column")
    assert(css[:body].include?(".schedule-summary-grid > .status-mark") &&
           css[:body].include?(".schedule-row > .status-mark") &&
           css[:body].include?("background: transparent;") &&
           css[:body].include?("border: 0;"),
           "expected Schedule calendar icons to render without boxed backgrounds")
    assert(css[:body].include?(".schedule-row-title") && css[:body].include?("align-items: center"),
           "expected Schedule status labels to align inline with row titles")
    assert(css[:body].include?(".schedule-row-actions") && css[:body].include?("justify-content: flex-end"),
           "expected Schedule row buttons to align right")
    assert(css[:body].include?(".schedule-row-actions") && css[:body].include?("gap: 8px;"),
           "expected Schedule row buttons to be properly spaced")
    assert(css[:body].include?(".kv-copy-button"),
           "expected copyable key/value rows to style their copy button")
    assert(css[:body].include?(".hidden-toggle-button.active.visible-state"),
           "expected Hidden settings rows to style the visible segment in the triple toggle")
    assert(css[:body].include?("flex-wrap: nowrap"),
           "expected Hidden settings toggle segments to stay horizontal")
    assert(css[:body].include?(".project-info-title"),
           "expected Project edit form to style the read-only information title")
    assert(css[:body].include?(".diff-viewer") && css[:body].include?(".diff-line.added"),
           "expected Remote UI to style project Git diff rows")
    assert(css[:body].include?("overflow-x: auto;"),
           "expected diff file bodies to expose a horizontal scrollbar for long code lines")
    assert(css[:body].include?("-webkit-text-size-adjust: 100%;") &&
           css[:body].include?("text-size-adjust: 100%;"),
           "expected Remote UI to prevent mobile browser text inflation")
    assert(css[:body].include?(".diff-hunk-header code,\n  .diff-lines") &&
           css[:body].include?("font-size: 11px;"),
           "expected mobile diff code typography to stay compact")
    assert(!css[:body].include?("max-height: min(70dvh, 720px);"),
           "expected diff file bodies to avoid per-file vertical scroll limits")
    assert(!css[:body].include?("max-height: min(58dvh, 680px);"),
           "expected split diff file bodies to avoid per-file vertical scroll limits")
    assert(css[:body].include?(".diff-scope-switch"),
           "expected Remote UI to style Git diff scope toggles")
    helper_request = HQ::RemoteServer.const_get(:Request).new(
      method: "GET",
      path: "/ui-helpers.js",
      headers: {},
      body: ""
    )
    assert(server.send(:ui_request?, helper_request), "expected /ui-helpers.js to be recognized as a UI route")
    assert(response[:body].match?(%r{src="/ui-helpers\.js\?v=[0-9a-f]{12}"}),
           "expected root helper JavaScript reference to be asset-versioned")
    assert(response[:body].index("/ui-helpers.js") < response[:body].index("/ui.js"),
           "expected Remote UI helpers to load before the main application script")
    helpers_js = server.send(:route_ui, "/ui-helpers.js")
    assert(helpers_js[:content_type].include?("javascript"), "expected /ui-helpers.js to return JavaScript")
    assert(helpers_js[:body].include?("TychoRemoteHelpers"),
           "expected Remote UI helper asset to expose the helper namespace")
    assert(helpers_js[:body].include?("function compareAgentsBySort"),
           "expected agent sort comparators to live in the helper asset")
    assert(helpers_js[:body].include?("function compareQuickSwitchAgents"),
           "expected quick switch agent ordering to live in the helper asset")
    assert(helpers_js[:body].include?("function parseRoute") &&
           helpers_js[:body].include?("function routeHash") &&
           helpers_js[:body].include?("function routeStateKey"),
           "expected Remote UI route helpers to live in the helper asset")
    assert(helpers_js[:body].include?("function elementStateKey") &&
           helpers_js[:body].include?("function controlState") &&
           helpers_js[:body].include?("function safeLocalStorageGet"),
           "expected Remote UI form preservation primitives to live in the helper asset")
    assert(helpers_js[:body].include?("function markdownHeadingSlug") &&
           helpers_js[:body].include?("function decodeHashFragment"),
           "expected Remote UI Markdown anchor primitives to live in the helper asset")
    assert(helpers_js[:body].include?("function attachmentHref") &&
           helpers_js[:body].include?("function attachmentTarget") &&
           helpers_js[:body].include?("function attachmentBlobPath"),
           "expected Remote UI attachment target primitives to live in the helper asset")
    js = server.send(:route_ui, "/ui.js")
    assert(js[:body].include?('ownership === "takeover"') &&
           js[:body].include?('agent-ownership-badge takeover') &&
           !js[:body].include?('aria-label="generation'),
           "expected relationship rows to label takeovers without displaying delegated ownership generations")
    assert(js[:body].include?("function renderSkillInstallation") &&
           js[:body].include?('data-skill-action="install"') &&
           js[:body].include?('data-skill-action="update"') &&
           js[:body].include?("function changeHarnessSkills") &&
           js[:body].include?("Only Tycho-owned files can be updated") &&
           js[:body].include?("Changed before failure:"),
           "expected Settings to expose confirmed skill actions and partial change details")
    assert(js[:body].include?("function statusIntent") &&
           js[:body].include?("function statusBadge") &&
           js[:body].include?("function statusMarkAttributes") &&
           js[:body].include?('need: "warning"') &&
           js[:body].include?('running: "active"') &&
           js[:body].include?('done: "success"') &&
           js[:body].include?('fail: "danger"'),
           "expected one semantic mapping for legacy product status classes")
    assert(js[:body].include?("function agentStatusBadge") &&
           js[:body].include?("function agentStatusIconName") &&
           js[:body].include?('return "pause"') &&
           js[:body].include?('return "check"') &&
           js[:body].include?('return "ban"') &&
           js[:body].include?('case "awaiting-input":') &&
           js[:body].include?('case "input-required":') &&
           js[:body].include?('case "input_required":') &&
           js[:body].include?('return "badgeQuestionMark"') &&
           js[:body].include?('<path d="M20 6 9 17l-5-5"></path>') &&
           js[:body].include?('<path d="m4.9 4.9 14.2 14.2"></path>') &&
           js[:body].include?('case "no_action_needed":') &&
           js[:body].include?('case "partial":') &&
           js[:body].include?('case "idle":') &&
           js[:body].include?('normalizedStatus === "unread" || inquiryStatus ? "need"') &&
           js[:body].include?('role="img" aria-label="${escapeAttr(label)}"') &&
           js[:body].include?("agentStatusBadge(agent") &&
           !helpers_js[:body].include?("✅".b) &&
           !helpers_js[:body].include?("⏸️".b) &&
           !helpers_js[:body].include?("🚫".b),
           "expected agent status surfaces to use exact accessible Lucide icons without emoji")
    assert(js[:body].scan("statusBadge(").length >= 25 &&
           js[:body].scan("statusMarkAttributes(").length >= 15,
           "expected representative agent, schedule, setup, project, and diff states to use the semantic status contract")
    assert(js[:body].include?("function metadataBadge") &&
           js[:body].scan("metadataBadge(").length >= 16 &&
           js[:body].include?('data-kind="metadata"'),
           "expected compact factual metadata to use one neutral badge contract")
    assert(js[:body].include?('metadataBadge("Markdown")') &&
           js[:body].include?('metadataBadge(`PR #${project.pr_number}`, "chip")') &&
           js[:body].include?('metadataBadge(diffScopeLabel(normalizedScope), "chip")') &&
           js[:body].include?('metadataBadge(`pid ${daemon.pid}`)'),
           "expected format, project, diff, and scheduler metadata to use neutral badges")
    assert(!js[:body].match?(/class="(?:pill|chip) (?:detail|info)"/),
           "expected factual pill and chip markup to use the metadata or status helpers")
    assert(js[:body].include?('response-style-form ui-surface ui-stack'),
           "expected Response style to use the shared surface and layout primitives")
    assert(js[:body].include?('class="ui-input" id="response-style-input"') &&
           js[:body].include?('aria-describedby="response-style-help"'),
           "expected Response style to use the shared field contract")
    assert(js[:body].include?('class="notice need ui-alert"') &&
           js[:body].include?('data-intent="danger" role="alert"'),
           "expected Response style failures to use the shared danger alert")
    %w[agent-form project-form schedule-form schedule-message-form].each do |form_id|
      assert(js[:body].include?("id=\"#{form_id}\"") &&
             js[:body].match?(/id="#{Regexp.escape(form_id)}"[^>]*class="[^"]*ui-form-layout[^"]*"[^>]*data-ds-form="lifecycle"/),
             "expected #{form_id} to use the lifecycle form contract")
    end
    assert(js[:body].scan("ui-form-section-heading").length >= 10 &&
           js[:body].scan("ui-form-actions").length >= 8,
           "expected lifecycle and Settings forms to share section-heading and action anatomy")
    %w[
      agent-template-help
      agent-response-style-help
      schedule-key-help
      schedule-cron-help
      schedule-ends-at-help
      schedule-system-message-help
      schedule-message-help
      schedule-message-content-help
    ].each do |description_id|
      assert(js[:body].include?("aria-describedby=\"#{description_id}\"") &&
             js[:body].include?("id=\"#{description_id}\""),
             "expected lifecycle form help #{description_id} to be programmatically connected")
    end
    assert(js[:body].scan('class="field-card ui-field ui-surface"').length >= 20,
           "expected lifecycle fields to use shared field and surface contracts")
    assert(js[:body].include?('class="agent-advanced-config ui-surface"') &&
           js[:body].include?("data-agent-advanced-summary") &&
           js[:body].include?("function syncAgentAdvancedSummary"),
           "expected agent runtime configuration to use a collapsed Advanced disclosure with a synchronized value summary")
    %w[
      session-loop-default-interval
      session-loop-default-end-time
      session-loop-template-name-
      session-loop-template-prompt-
    ].each do |control_id|
      assert(js[:body].match?(/class="ui-input" id="#{Regexp.escape(control_id)}/),
             "expected Session loop control #{control_id} to use the shared input color and state contract")
    end
    %w[session-loop-default-interval-help session-loop-default-end-time-help].each do |description_id|
      assert(js[:body].include?("aria-describedby=\"#{description_id}\"") &&
             js[:body].include?("id=\"#{description_id}\""),
             "expected Session loop help #{description_id} to be programmatically connected")
    end
    assert(js[:body].scan('data-variant="brand" type="submit"').length >= 7,
           "expected lifecycle primary submits to use the semantic brand action")
    legacy_action_tags = [response[:body], js[:body]].join("\n").scan(
      /<(?:button|a)\b[^>]*class="[^"]*\b(?:primary|danger|inline-icon-button|icon-button|button-link)\b[^"]*"[^>]*>/
    )
    assert(!legacy_action_tags.empty? && legacy_action_tags.all? { |tag| tag.include?("ui-button") },
           "expected every legacy action adapter to consume the shared button contract")
    legacy_action_tags.each do |tag|
      classes = tag[/class="([^"]+)"/, 1].to_s.split
      if classes.include?("icon-button")
        assert(classes.include?("ui-icon-button"),
               "expected legacy icon action to consume the shared icon-button contract: #{tag}")
      end
      if classes.include?("primary")
        assert(tag.include?('data-variant="brand"'),
               "expected legacy primary action to map to the brand variant: #{tag}")
      end
      if classes.include?("danger")
        assert(tag.include?('data-variant="danger"'),
               "expected legacy danger action to map to the danger variant: #{tag}")
      end
    end
    assert(js[:body].include?('<span>Create and run</span>') && js[:body].include?('type="submit"'),
           "expected Quick Agent to expose a visible primary submit action")
    assert(js[:body].include?("Create without running") && js[:body].include?('class="secondary-submit-menu"'),
           "expected create-only agent submission to live behind a secondary option")
    assert(js[:content_type].include?("javascript"), "expected /ui.js to return JavaScript")
    assert(js[:body].include?("DEFAULT_REFRESH_INTERVALS"), "expected UI JavaScript to define refresh defaults")
    assert(js[:body].include?("AGENT_ACTIVITY_POLL_INTERVALS") &&
           js[:body].include?('brokerGet("/servers/activity")') &&
           js[:body].include?("function pollAgentActivity") &&
           js[:body].include?("function loadAgentActivity") &&
           js[:body].include?('`/servers/${encodeURIComponent(server.key)}/activity`'),
           "expected the logo agent activity to poll a dedicated lightweight endpoint")
    assert(js[:body].include?("function mergeAgentActivity") &&
           js[:body].include?("state.activityAppliedSequence") &&
           js[:body].include?("syncUnreadAlert();"),
           "expected activity polling to reject stale responses and update the logo without a page render")
    assert(js[:body].include?("REMOTE_HELPERS.mergeActivityServers") &&
           js[:body].include?("Peer activity fetch degraded") &&
           js[:body].include?("retrying automatically") &&
           js[:body].include?('return "Degraded"') &&
           js[:body].include?("server-activity-error"),
           "expected peer activity 5xx failures to degrade independently with an automatic retry signal")
    assert(js[:body].include?("window.TychoRemoteHelpers"),
           "expected the main Remote UI script to use the helper namespace")
    assert(js[:body].include?('updateViaCache: "none"'),
           "expected service worker registration to bypass browser caches")
    assert(js[:body].include?("function resetRemoteCaches"),
           "expected Remote UI restart to clear browser Cache Storage")
    assert(js[:body].include?('url.searchParams.set("hq_restart"'),
           "expected Remote UI restart to reload with a cache-busting query")
    assert(js[:body].include?("function activateNavTab"),
           "expected Remote UI nav clicks to route through top-tab activation")
    assert(js[:body].include?("function scrollPageToTop"),
           "expected selected Remote UI nav clicks to scroll the current tab to the top")
    assert(js[:body].include?('route.type === "tab" && route.tab === tab'),
           "expected selected Remote UI nav detection to require the current top-level tab")
    assert(js[:body].include?('const DEFAULT_AGENT_SORT = "project_asc"'),
           "expected agent sorting to default to project grouping ascending")
    assert(js[:body].include?('const AGENT_SORT_STORAGE_KEY = "hq.remote.agentSort"'),
           "expected agent sort selection to use session storage")
    assert(js[:body].include?("data-agent-sort-choice"),
           "expected Agents screen to expose sort dropdown choices")
    assert(js[:body].include?('icon: "arrowDownAZ"') &&
           js[:body].include?('icon: "clockArrowDown"') &&
           js[:body].include?('icon: "arrowDownWideNarrow"'),
           "expected agent sort trigger to use lucide sort icons")
    assert(js[:body].include?('M20 8h-5') &&
           js[:body].include?('M15 10V6.5a2.5 2.5 0 0 1 5 0V10') &&
           js[:body].include?('M15 20v-3.5a2.5 2.5 0 0 1 5 0V20'),
           "expected A-Z and Z-A sort icons to use Lucide SVG paths")
    assert(js[:body].include?("function agentSortMenuHtml"),
           "expected Agents screen to render an icon-triggered sort dropdown")
    assert(js[:body].include?("setSessionStorageValue(AGENT_SORT_STORAGE_KEY, state.agentSort)"),
           "expected chosen agent sort to persist for the browser session")
    assert(js[:body].include?("function sortedAgentList"),
           "expected agent sort to support flat agent lists")
    assert(js[:body].include?("function agentSortUsesProjectGroups"),
           "expected agent sort to support project-grouped lists")
    assert(js[:body].include?("function compareAgentsBySort"),
           "expected agent list sorting to support multiple sort modes")
    assert(js[:body].include?("function showGrowl"), "expected UI JavaScript to expose growl notifications")
    assert(js[:body].include?("function handleDocumentCopyClick"),
           "expected copy buttons to be handled outside the main view")
    assert(js[:body].include?('showGrowl("Copied to clipboard", "done")'),
           "expected copy success to use growl feedback")
    assert(response[:body].include?('id="header-title-copy"') &&
           response[:body].include?('aria-label="Copy agent title"') &&
           response[:body].include?('<span class="sr-only">Copy agent title</span>'),
           "expected the Conversation header to expose an accessible agent-title copy control")
    assert(js[:body].include?('setHeader(agent.name || agent.key, agentHeaderLabel(agent), "A", { agentTitle: agent, copyTitle: agent.name || agent.key })') &&
           js[:body].include?("function setHeaderTitleCopy") &&
           js[:body].include?("els.titleCopy.dataset.copy = value") &&
           js[:body].include?('els.titleCopy.removeAttribute("data-copy")'),
           "expected only Agent conversation headers to copy the exact rendered title and clear stale copy data")
    assert(css[:body].include?(".header-title-row") &&
           css[:body].include?(".header-title-copy") &&
           css[:body].include?("flex: 0 0 auto") &&
           css[:body].include?("width: 24px") &&
           css[:body].include?("border-top: 1px solid var(--border)") &&
           css[:body].include?("width: calc(100% + 12px)") &&
           css[:body].include?("margin-top: calc(var(--safe-area-top) + 12px)") &&
           css[:body].include?(".agent-workspace.has-detail") &&
           css[:body].include?(".agent-detail-pane") &&
           css[:body].include?("margin-top: 8px"),
           "expected the title copy control to preserve truncation and responsive header layout")
    assert(!js[:body].include?('setConnection("Copied to clipboard")'),
           "expected copy success to avoid changing the header subtitle")
    assert(js[:body].include?("function copyableKv"),
           "expected Remote UI to expose copyable key/value rows")
    assert(js[:body].include?("kv-copy-button"),
           "expected copyable key/value rows to render a copy control")
    assert(js[:body].include?('["Raw log", agent.log_path]') &&
           js[:body].include?('label === "Status" ? agentStatusKv(agent, { copyable: true }) : copyableKv(label, value)'),
           "expected Conversation settings rows to be copyable")
    assert(js[:body].include?('copyableKv("Path", project.path)') &&
           js[:body].include?('copyableKv("Templates",'),
           "expected Project workspace and template details to be copyable")
    assert(js[:body].include?('copyableKv("Root", setup.logs?.root)') &&
           js[:body].include?('copyableKv("Auth", setup.auth?.status)'),
           "expected Settings configuration, logs, and preferences rows to be copyable")
    assert(js[:body].include?("data-agent-dock"), "expected Agent detail composer to live in a dock")
    assert(js[:body].include?("function renderInquiryForm"),
           "expected Agent detail to render structured inquiry forms")
    assert(js[:body].include?("function renderInquiryLoadingSkeleton") &&
           js[:body].include?('composerState === "inquiry-loading"') &&
           js[:body].include?('class="inquiry-loading-tools"') &&
           js[:body].scan('class="inquiry-loading-tool"').length == 3 &&
           js[:body].include?('class="inquiry-loading-submit"') &&
           js[:body].include?('REMOTE_HELPERS.agentComposerState(agent) === "inquiry-loading"') &&
           css[:body].include?(".inquiry-loading-skeleton") &&
           css[:body].include?("@keyframes inquiry-loading-sweep") &&
           css[:body].include?("@keyframes inquiry-loading-border"),
           "expected pending inquiry detail to hide Summary and render a quiet animated form skeleton")
    assert(js[:body].include?('id="inquiry-form" class="inquiry-form${'),
           "expected inquiry answers to use a dedicated form")
    assert(js[:body].include?("fullScreenInquiryKeys") &&
           js[:body].include?("data-toggle-inquiry-full-screen") &&
           css[:body].include?(".inquiry-form-full-screen"),
           "expected inquiry answers to support full-screen editing")
    assert(js[:body].include?('class="mobile-inquiry"') &&
           js[:body].include?('data-state-key="mobile-inquiry:') &&
           js[:body].include?("Answer required") &&
           js[:body].include?('${compact ? "" : inquiryBanner}') &&
           js[:body].include?('${fullScreenButton}') &&
           css[:body].include?(".mobile-inquiry > summary .mobile-inquiry-full-screen-button") &&
           css[:body].include?(".mobile-inquiry > summary"),
           "expected mobile inquiry answers to use one collapsible header with the full-screen action")
    assert(js[:body].include?("Leave feedback") &&
           js[:body].include?('name="feedback"') &&
           js[:body].include?("const feedback = String(new FormData(form).get(\"feedback\")"),
           "expected every inquiry to end with optional user feedback")
    assert(!js[:body].include?("data-inquiry-confirm") &&
           js[:body].include?('class="inquiry-footer"'),
           "expected inquiry actions to use a direct anchored footer without redundant confirmation")
    assert(js[:body].include?('data-inquiry-validation') && js[:body].include?("function syncViewControls"),
           "expected inquiry answers to expose live validation before submission")
    assert(js[:body].include?("function syncInquiryFieldValidity") &&
           js[:body].include?("data-inquiry-field-error") &&
           css[:body].include?(".inquiry-field.invalid"),
           "expected inquiry validation to identify the required field beside its control")
    assert(js[:body].include?('data-ds-form="inquiry"') &&
           js[:body].include?('class="field-card inquiry-field ui-field ui-surface"') &&
           js[:body].include?('class="ui-input"') &&
           js[:body].include?('data-variant="brand" type="submit"'),
           "expected inquiry decisions to use shared field, surface, input, and action contracts")
    assert(js[:body].include?('role="group" data-inquiry-control data-inquiry-multi=') &&
           js[:body].include?('aria-labelledby="${escapeAttr(relationships.labelId || "")}"') &&
           js[:body].include?('aria-errormessage=') &&
           js[:body].include?('field.querySelector("[data-inquiry-control]")'),
           "expected multi-select inquiries to expose one labelled group with programmatic errors")
    assert(js[:body].include?('id="inquiry-validation"') &&
           js[:body].include?('aria-live="polite" aria-atomic="true"'),
           "expected inquiry readiness changes to be announced atomically")
    assert(css[:body].include?("align-content: start") &&
           css[:body].include?("grid-auto-rows: max-content") &&
           css[:body].include?("height: var(--control-height)"),
           "expected full-screen inquiry fields and controls to keep natural heights")
    assert(js[:body].include?("agentDetailViewMode") &&
           js[:body].include?("data-set-agent-detail-view") &&
           js[:body].include?('role="menuitemradio"'),
           "expected focused Summary and Attachment layouts to use one exclusive view menu")
    assert(js[:body].include?('{ value: "balanced", label: "Balanced", icon: "columns2" }') &&
           js[:body].include?('{ value: "wide", label: "Widen detail", icon: "panelRightOpen" }') &&
           js[:body].include?('{ value: "full", label: "Full view", icon: "maximize2" }'),
           "expected each focused view mode to expose its own active trigger icon")
    assert(js[:body].include?('class="focused-composer"') && js[:body].include?("Continue conversation"),
           "expected mobile focused views to collapse the follow-up composer")
    assert(js[:body].include?('iconSvg("badgeQuestionMark")'),
           "expected inquiry prompt banners to render a badge question icon")
    assert(js[:body].include?('class="inquiry-mark"'),
           "expected inquiry prompt icons to render without status-mark framing")
    assert(!js[:body].include?("Agent is waiting for your answer"),
           "expected inquiry prompt banners to omit the title section")
    assert(!js[:body].include?("Review before sending"),
           "expected inquiry confirmation to omit the extra review title")
    assert(js[:body].include?("novalidate"),
           "expected inquiry submit clicks to reach custom validation instead of becoming silent browser no-ops")
    assert(js[:body].include?("function inquiryAnswerPayload"),
           "expected Remote UI to serialize inquiry answers")
    assert(js[:body].include?('/inquiries/${encodeURIComponent(inquiryId)}/answer'),
           "expected Remote UI inquiry answers to use the guarded answer endpoint")
    assert(js[:body].include?("function renderInquiryLifecycleMenu") &&
           js[:body].include?('data-inquiry-lifecycle-action="${action}"') &&
           js[:body].include?('aria-label="Inquiry actions"') &&
           js[:body].include?('aria-busy="true"'),
           "expected inquiry and composer context menus to expose accessible pending lifecycle actions")
    assert(js[:body].include?('action === "dismiss" ? "Dismiss inquiry" : "Restore inquiry"') &&
           js[:body].include?('action === "dismiss" ? "Dismissing inquiry" : "Restoring inquiry"'),
           "expected dismiss and restore actions to expose stable accessible names and pending labels")
    assert(js[:body].include?("function runInquiryLifecycleAction") &&
           js[:body].include?('showGrowl(`Could not ${label} inquiry: ${error.message}`, "need")'),
           "expected inquiry lifecycle actions to announce failures")
    assert(js[:body].include?('retire_inquiry_id: retireInquiryId') &&
           js[:body].include?('findAgent(key)?.suspended_inquiry?.id'),
           "expected ordinary prompts to retire only the suspended inquiry rendered by that client")
    assert(css[:body].include?(".composer-action-menu") && css[:body].include?(".composer-action-popover"),
           "expected inquiry lifecycle context menus to be positioned in both composers")
    assert(js[:body].include?("normalizeInquiryInputType"),
           "expected Remote UI to normalize inquiry field input types")
    assert(js[:body].include?("function setHeaderMore"), "expected Remote UI to expose reusable header More menus")
    assert(js[:body].include?("function headerMoreKeyForRoute"),
           "expected header More menus to preserve open state across same-route refreshes")
    assert(js[:body].include?('route.tab === "settings") return "settings"'),
           "expected Settings More menu to preserve open state across same-route refreshes")
    assert(js[:body].include?("headerMoreBadge"),
           "expected header More menus to expose a discoverability badge")
    assert(js[:body].include?("function rememberOverlayFocus") &&
           js[:body].include?("function restoreOverlayFocus") &&
           js[:body].include?("function closeDetailsOverlays"),
           "expected non-modal overlays to share focus and peer-dismissal behavior")
    assert(js[:body].include?("function moveOverlayMenuFocus") &&
           js[:body].include?('["ArrowDown", "ArrowUp", "Home", "End"]') &&
           js[:body].include?("closeHeaderMore({ restoreFocus: true })"),
           "expected menus to support arrow navigation and Escape focus restoration")
    assert(js[:body].scan("data-overlay-menu").length >= 6,
           "expected representative details menus to adopt the overlay interaction contract")
    assert(js[:body].include?("function confirmAction") &&
           js[:body].include?("function settleConfirmation") &&
           js[:body].include?('dialog.querySelector("[data-confirmation-cancel]")?.focus'),
           "expected consequential actions to share a safely focused native-dialog contract")
    assert(js[:body].include?('els.confirmationDialog.addEventListener("cancel"') &&
           js[:body].include?("settleConfirmation(false)") &&
           js[:body].include?("settleConfirmation(true)"),
           "expected confirmation Escape, cancel, backdrop, and acceptance behavior")
    assert(js[:body].scan("window.confirm").length == 1,
           "expected window.confirm to remain only as the unsupported-browser fallback")
    assert(js[:body].include?('confirmLabel: "Remove response style"') &&
           js[:body].include?('confirmLabel: agent ? "Remove schedule" : "Delete schedule"') &&
           js[:body].include?('confirmLabel: "Delete attachment"'),
           "expected representative destructive workflows to use explicit confirmation labels")
    assert(helpers_js[:body].include?("function parseBackToRoute"),
           "expected Project routes to parse return crumbs")
    assert(helpers_js[:body].include?('key: parts.slice(1).join("/")'),
           "expected Project return crumbs to preserve remote scoped agent keys")
    assert(helpers_js[:body].include?("function routeBackQuery"),
           "expected Project routes to serialize return crumbs")
    assert(helpers_js[:body].include?('const route = { type: "projectDiff"'),
           "expected Project diff routes to be parsed")
    assert(js[:body].include?("function ensureProjectDiff"),
           "expected Remote UI to load project Git diffs from the API")
    assert(js[:body].include?("ensureProjectDiff(route.key, route.scope, options.forceProjectDiff || options.force)"),
           "expected polling to preserve loaded project Git diffs unless refresh is explicit")
    assert(js[:body].include?("function renderProjectDiff"),
           "expected Remote UI to render project Git diffs")
    assert(js[:body].include?('/git/diff?scope='),
           "expected Remote UI to call the project Git diff endpoint")
    assert(js[:body].include?("data-open-project-diff"),
           "expected Project detail to expose Git diff navigation")
    assert(js[:body].include?("function agentBulkControlsHtml"),
           "expected Agents tab bulk selection to render beside the sort control")
    assert(js[:body].include?("function agentMoreMenuHtml"),
           "expected Conversation actions to move into the header More menu")
    assert(js[:body].include?("Conversation settings"),
           "expected Conversation settings to be available from the More menu")
    assert(js[:body].include?("Open project"),
           "expected Conversation More menu project navigation to use a verb label")
    assert(js[:body].include?('label: "New agent"') &&
           js[:body].include?('attrs: `data-create-agent="${escapeAttr(agent.project_key)}"`'),
           "expected Conversation More menu to create agents in the current project")
    assert(js[:body].include?('label: "PR Diffs"') &&
           js[:body].include?("pullRequestCount > 0") &&
           js[:body].include?('attrs: `data-open-agent-pr-diffs="${escapeAttr(agent.key)}"`'),
           "expected Conversation More menu to expose available pull request diffs")
    assert(helpers_js[:body].include?('back_to=${encodeURIComponent(value)}'),
           "expected Project links opened from agents to carry a back_to crumb")
    assert(js[:body].include?("function setAgentSettings"), "expected Agent metadata to move into header settings")
    assert(js[:body].include?('id="agent-model" name="model"'),
           "expected Remote UI agent form to expose model input")
    assert(js[:body].include?('name="reasoning_effort"'),
           "expected Remote UI agent form to expose reasoning effort input")
    assert(js[:body].include?("data-agent-model-select"),
           "expected Remote UI agent form to expose a persistent model choice control")
    assert(js[:body].include?("function modelChoiceOptions"),
           "expected Remote UI agent form to build model suggestions from setup payload")
    assert(js[:body].include?("model: String(formData.get(\"model\")"),
           "expected Remote UI agent form payload to include model")
    assert(js[:body].include?("Push notifications"), "expected Settings screen to expose push readiness")
    assert(js[:body].include?("function settingsMoreMenuHtml"),
           "expected Settings actions to move into the header More menu")
    assert(js[:body].include?("function setMainHeaderMore"),
           "expected main tabs to share the Settings More menu")
    assert(js[:body].include?("function openQuickAgent"),
           "expected Remote UI to expose Quick Agent creation")
    assert(js[:body].include?("function quickAgentProjectDefaults"),
           "expected Quick Agent to derive project-specific defaults")
    assert(js[:body].include?("await ensureProject(newKey)"),
           "expected Quick Agent project changes to load project detail defaults")
    assert(js[:body].include?("Tycho build"),
           "expected Settings screen to display the Tycho build")
    assert(js[:body].include?("function tychoBuildLabel"),
           "expected Settings screen to format Tycho build metadata")
    assert(js[:body].include?("data-toggle-server-form") &&
           js[:body].include?("state.serverFormOpen ? renderAddServerForm() :") &&
           js[:body].include?("data-refresh-all-servers") &&
           js[:body].include?("data-filter-server") &&
           !js[:body].include?("data-select-server") &&
           js[:body].include?("function renderServerActionsMenu") &&
           js[:body].include?("data-server-action-menu") &&
           js[:body].include?('data-overlay-key="server:'),
           "expected Settings to manage peers while Agents exposes one server filter")
    assert(js[:body].include?("function agentMobileToolbarMenuHtml") &&
           js[:body].include?('data-overlay-key="agent-mobile-toolbar"') &&
           js[:body].include?("data-agent-server-choice") &&
           js[:body].include?("data-toggle-bulk-archive"),
           "expected the narrow Agents toolbar menu to expose server, sort, and bulk actions")
    assert(!js[:body].include?("function renderServerSelect") &&
           !js[:body].include?("data-server-select") &&
           !js[:body].include?("Active Tycho server"),
           "expected Settings server switching to avoid the removed dropdown")
    assert(js[:body].include?("function renderAddServerForm") &&
           js[:body].include?("Add server") &&
           js[:body].include?('name="name"') &&
           js[:body].include?('name="token"') &&
           js[:body].include?("Remote token") &&
           js[:body].include?("tycho-peer"),
           "expected Settings to expose a named add-server form with token input and the 7374 peer default")
    assert(js[:body].include?('id="server-connection-form" class="server-connection-form ui-form-layout" data-ds-form="settings"') &&
           js[:body].include?('class="ui-input" id="server-name-input"') &&
           js[:body].include?('class="ui-input" id="server-url-input"') &&
           js[:body].include?('class="ui-input" id="server-token-input"') &&
           js[:body].include?('class="server-connection-actions ui-form-actions"'),
           "expected Add server to use the shared Settings form, field, input, and action contracts")
    %w[server-name-input-help server-url-input-help server-token-input-help].each do |description_id|
      assert(js[:body].include?("aria-describedby=\"#{description_id}\"") &&
             js[:body].include?("id=\"#{description_id}\""),
             "expected Add server help #{description_id} to be programmatically connected")
    end
    assert(js[:body].include?('brokerPost("/servers"') &&
           js[:body].include?('token: String(token || "")') &&
           js[:body].include?("SERVER_TOKENS_STORAGE_KEY") &&
           js[:body].include?("hq.remote.serverTokens") &&
           js[:body].include?("X-Tycho-Remote-Server-Token") &&
           js[:body].include?('brokerPost(`/servers/${encodeURIComponent(server?.key || "")}/credentials`') &&
           js[:body].include?("removeRemoteServerToken(server?.key)") &&
           js[:body].include?("removeRemoteServerToken(value)") &&
           js[:body].include?('brokerDelete(`/servers/${encodeURIComponent(value)}`') &&
           !js[:body].include?("hq.remote.customServers"),
           "expected Settings server add/remove to persist metadata through broker routes and tokens through browser storage")
    assert(js[:body].include?('label: "Forget cached data"') &&
           js[:body].include?("confirmForgetRemoteServerResources") &&
           js[:body].include?('brokerDelete(`/servers/${encodeURIComponent(value)}/resources`)'),
           "expected peer Settings to expose explicit persisted-resource cache clearing")
    assert(js[:body].include?("data-toggle-server-token-form") &&
           js[:body].include?("function renderServerTokenForm") &&
           js[:body].include?("saveRemoteServerToken") &&
           js[:body].include?('brokerPost(`/servers/${encodeURIComponent(serverKey)}/credentials`') &&
           js[:body].include?("Remote token moved to this Tycho host") &&
           js[:body].include?("Token needed here"),
           "expected Settings to let existing remote servers save a browser-local token")
    assert(js[:body].include?("function serverMetadataBadge") &&
           js[:body].include?('const text = server?.local ? ""') &&
           js[:body].include?("serverIconName(server)") &&
           js[:body].include?('server?.local) return "home"'),
           "expected local resource ownership to render as an accessible home icon without visible text")
    assert(!js[:body].include?(["This", "server"].join(" ")) &&
           js[:body].include?('return server.local ? "Host"'),
           "expected local ownership text to use Host")
    assert(js[:body].include?('renderAgentRow(agent, { serverIcon: true, query })') &&
           js[:body].include?('class="agent-server-inline"') &&
           css[:body].include?(".agent-server-inline > .ui-icon"),
           "expected flat Agent rows to show the local or peer server icon")
    assert(js[:body].include?("function renderServerIdentityForm") &&
           js[:body].include?("data-toggle-server-identity-form") &&
           js[:body].include?("data-server-identity-form") &&
           js[:body].include?('["server", "computer"]') &&
           js[:body].include?('brokerPatch(`/servers/${encodeURIComponent(serverKey)}`') &&
           js[:body].include?("Server identity saved"),
           "expected Settings to edit peer names and Lucide server or computer icons")
    assert(!js[:body].include?("function renderServerHealthNotices") &&
           !js[:body].include?("No cached agents or projects are available yet.") &&
           js[:body].include?("currentAgents().filter(resourceAvailableInNow)"),
           "expected Now to omit disconnected server cards and stale peer agents")
    assert(js[:body].include?("async function loadResourceCatalog") &&
           js[:body].include?('if (error.status !== 404) throw error;') &&
           js[:body].include?('compatibility_mode: "legacy-local"') &&
           js[:body].include?('state.resourceCatalogMode = "legacy"') &&
           js[:body].include?('if (state.resourceCatalogMode === "legacy") return false;'),
           "expected new Remote UI assets to remain usable against a running legacy daemon")
    assert(js[:body].include?("function resourceIsStale") &&
           js[:body].include?('return resourceIsStale(resource) ? "resource-stale" : "";') &&
           !js[:body].include?('if (resourceIsStale(agent)) return "Stale";') &&
           !js[:body].include?('if (resourceIsStale(project)) return "Stale";') &&
           css[:body].include?(".resource-stale") &&
           css[:body].include?("opacity: 0.68"),
           "expected stale peer projects and agents to stay subdued without replacing their status")
    assert(js[:body].include?('class="server-token-form ui-form-layout" data-ds-form="settings"') &&
           js[:body].include?("Verified, stored on this Tycho host, then removed from this browser.") &&
           js[:body].include?('class="primary inline-icon-button ui-button" data-variant="brand" type="submit"'),
           "expected Remote token recovery to use the shared field, input, description, and semantic action contracts")
    assert(css[:body].include?(".server-action-menu > summary") &&
           css[:body].include?("width: var(--touch-target)") &&
           css[:body].include?(".server-action-popover") &&
           css[:body].include?("z-index: var(--ds-z-dropdown)") &&
           css[:body].include?(".server-action-popover .more-menu") &&
           css[:body].include?(".server-action-popover .more-menu-item") &&
           css[:body].include?("#settings-servers") &&
           css[:body].include?("overflow: visible"),
           "expected remote server actions to use one touch-sized contextual menu")
    assert(js[:body].include?('label: "Refresh"') &&
           js[:body].include?('label: tokenEditorOpen ? "Close token editor" : "Edit token"') &&
           js[:body].include?('label: "Remove server"') &&
           js[:body].include?("closeDetailsOverlay(removeServer.closest") &&
           js[:body].include?("{ restoreFocus: true }"),
           "expected the peer menu to preserve refresh, token editing, destructive separation, and focus restoration")
    assert(js[:body].include?("Restart the local Remote server to enable ad hoc peer connections"),
           "expected stale broker errors to explain that the local Remote server must be restarted")
    assert(!js[:body].include?("Connect local peer"),
           "expected Settings to replace the URL-only peer form")
    assert(js[:body].include?('id="settings-push-notifications"'),
           "expected Settings to retain its push-notification controls")
    assert(js[:body].include?('data-scroll-settings-section="settings-push-notifications"') &&
           js[:body].include?('key === "settings"'),
           "expected the push shortcut to appear only in the Settings route menu")
    assert(js[:body].include?('label: "Settings"') &&
           js[:body].include?('attrs: "data-open-settings"') &&
           js[:body].include?('navigate({ type: "tab", tab: "settings" })'),
           "expected the global More menu to open Settings from its first action")
    assert(js[:body].include?('class="settings-section-nav ui-section-nav"') &&
           js[:body].include?('class="settings-section-panel ui-section-panel"') &&
           js[:body].include?('aria-current=') &&
           js[:body].include?("function syncSettingsSectionNav") &&
           css[:body].include?(".settings-section-nav-shell") &&
           css[:body].include?("flex-wrap: nowrap") &&
           css[:body].include?("overflow-x: auto"),
           "expected Settings to keep a sticky in-page section navigator with active-section feedback")
    assert(response[:body].include?("ui-detail-header__back") &&
           response[:body].include?("ui-detail-header__identity") &&
           response[:body].include?("ui-detail-header__title") &&
           response[:body].include?("ui-detail-header__metadata") &&
           response[:body].include?("ui-detail-header__actions") &&
           response[:body].include?("ui-detail-header__action") &&
           js[:body].include?('classList.toggle("ui-detail-header", subpage && !onboarding)'),
           "expected focused routes to activate the shared detail-header anatomy without changing shell behavior")
    assert(js[:body].include?('class="ui-searchable-collection"') &&
           js[:body].include?('class="search-box ui-search-field"') &&
           js[:body].include?('id="agent-results-summary" role="status"') &&
           js[:body].include?('aria-describedby="agent-results-summary"') &&
           js[:body].include?("ui-collection-group ui-surface"),
           "expected Agents to use the searchable collection and explicit result-feedback contract")
    assert(css[:body].include?("position: sticky") &&
           css[:body].include?("scroll-margin-top: calc(var(--app-header-height"),
           "expected Settings section jumps to remain visible below the sticky header and navigator")
    assert(js[:body].include?("function renderHiddenSettings"),
           "expected Settings screen to expose a dedicated Hidden settings page")
    assert(js[:body].include?('apiGet("/settings/hidden")'),
           "expected Hidden settings page to load hidden configuration")
    assert(js[:body].include?('apiPatch("/settings/hidden"'),
           "expected Hidden settings page to update hidden configuration")
    assert(js[:body].include?("data-open-hidden-settings"),
           "expected Settings More menu to link to Hidden settings")
    assert(js[:body].include?('"eyeOff"') && js[:body].include?('"slash"') && js[:body].include?('"eye"'),
           "expected Hidden settings to use hidden/inherit/visible icon toggle buttons")
    assert(js[:body].include?("Restart server"), "expected Settings More menu to expose Remote restart action")
    assert(js[:body].include?("data-restart-server"), "expected Settings More menu to expose Remote restart action")
    assert(js[:body].include?("Remote restart"),
           "expected Settings readiness to include Remote restart status")
    assert(js[:body].index("Automation readiness") < js[:body].index("Remote restart"),
           "expected Remote restart readiness to sit inside Automation readiness")
    assert(js[:body].index("Remote restart") < js[:body].index('<div class="section-label"><strong>Configuration</strong>'),
           "expected Remote restart readiness to render before Configuration")
    assert(js[:body].include?("Refresh harness catalogs"),
           "expected Settings More menu to expose harness catalog refresh")
    assert(js[:body].include?("data-refresh-harnesses"), "expected Settings to wire harness catalog refresh")
    assert(js[:body].include?("function renderHarnessDetails") &&
           js[:body].include?('class="harness-details"'),
           "expected Settings to expose collapsible harness detail rows")
    assert(js[:body].include?("state.harnessCatalogRefreshing") &&
           js[:body].include?('loading ? "loaderPinwheel" : "rotateCcw"') &&
           js[:body].include?('loading ? "disabled" : ""'),
           "expected harness refresh button to show loading state and disable while refreshing")
    assert(js[:body].include?('apiPost("/setup/harnesses/refresh"'),
           "expected Remote UI harness refresh action to call the refresh endpoint")
    assert(js[:body].include?("Harness refresh unsupported by the host; rechecked status"),
           "expected Remote UI harness refresh to tolerate older servers")
    assert(js[:body].include?("data-harness-catalog-form") &&
           js[:body].include?('name="models"') &&
           js[:body].include?('name="reasoning_efforts"') &&
           js[:body].include?("function saveHarnessCatalog") &&
           js[:body].include?('apiPatch(`/setup/harnesses/${encodeURIComponent(harness)}/catalog`') &&
           js[:body].include?("Harness catalog editing unsupported by the host"),
           "expected Settings to edit and save custom harness model catalogs")
    assert(js[:body].include?("harness-catalog-form ui-form-layout") &&
           js[:body].include?('data-ds-form="settings" data-harness-catalog-form=') &&
           js[:body].include?("One model ID per line. Discovered models remain available.") &&
           js[:body].include?("One reasoning-effort value per line.") &&
           js[:body].include?('data-loading="${saving ? "true" : "false"}"') &&
           js[:body].include?('aria-busy="${saving ? "true" : "false"}"'),
           "expected harness catalogs to use described shared fields and expose pending state")
    assert(js[:body].include?('class="harness-catalog-editor"') &&
           js[:body].include?('data-state-key="harness-catalog-editor:') &&
           js[:body].include?("configuredSummary") &&
           js[:body].include?('configuredSummary || "No custom values"') &&
           js[:body].include?('configuredCount ? `${configuredCount} configured` : "Optional"'),
           "expected custom harness values to stay collapsed behind a stateful toggle with a visible value summary")
    assert(js[:body].include?('data-testid="response-style-form"') &&
           js[:body].include?('data-testid="response-style-input"') &&
           js[:body].include?("function saveResponseStyle") &&
           js[:body].include?('apiPatch("/settings/response-style"'),
           "expected Settings to edit and save the global response style")
    assert(js[:body].include?('data-testid="response-style-summary"') &&
           js[:body].include?("Add response style") &&
           js[:body].include?("Edit response style") &&
           js[:body].include?('data-testid="response-style-excerpt"') &&
           js[:body].include?('data-testid="response-style-delete"') &&
           js[:body].include?('replace(/\\s+/g, " ")') &&
           js[:body].include?('iconSvg("squarePen")') &&
           js[:body].include?('iconSvg("trash2")') &&
           js[:body].include?('class="inline-icon-button ui-button" type="button" data-open-response-style') &&
           js[:body].include?("shared writing guidance") &&
           js[:body].include?("without changing the task or required output format"),
           "expected Settings to explain response style and show the correct add or edit action with an excerpt")
    assert(js[:body].include?("function deleteResponseStyle()") &&
           js[:body].include?('apiDelete("/settings/response-style")') &&
           js[:body].include?("Managed agents will stop receiving this writing guidance"),
           "expected configured response styles to expose a confirmed remove action")
    assert(js[:body].include?('["Agent key", agent.resource_key || agent.key]') &&
           js[:body].include?('["Server", serverDisplayName(resourceServer(agent.server_key))]') &&
           js[:body].include?('["Model / reasoning", `${agent.model || "default"} / ${agent.reasoning_effort || "default"}`]') &&
           !js[:body].include?('["Effort", agent.reasoning_effort') &&
           !js[:body].include?('["Model", agent.model') &&
           js[:body].include?('["Response style", responseStyleSourceLabel(agent.response_style_source)]') &&
           js[:body].include?("left.localeCompare(right)") &&
           !js[:body].include?('copyableKv("Exit", agent.last_exit_code'),
           "expected Conversation settings to show the generated key and response style source alphabetically")
    assert(js[:body].include?('id="agent-response-style"') &&
           js[:body].include?('name="response_style_mode"') &&
           js[:body].include?("Independent from Prompt Template") &&
           js[:body].include?("function agentResponseStyleMode") &&
           js[:body].include?("function applyAgentResponseStyleChoice") &&
           js[:body].include?('response_style_mode: String(formData.get("response_style_mode")'),
           "expected the agent form to select response style independently from Prompt Template")
    assert(js[:body].include?("if (!responseStyle.drafting)") &&
           js[:body].include?("data-cancel-response-style"),
           "expected the response style editor to stay collapsed until requested and support canceling")
    assert(css[:body].include?(".response-style-form") &&
           css[:body].include?("min-height: 180px") &&
           css[:body].include?("p.response-style-excerpt") &&
           css[:body].include?("color: var(--text)"),
           "expected the response style editor to have a readable responsive layout")
    assert(js[:body].include?('key === "settings"') &&
           js[:body].include?('label: "Recheck status"') &&
           js[:body].include?('label: "Push notifications"') &&
           js[:body].include?('label: "Settings"'),
           "expected the main More menu to separate global navigation from Settings-only actions")
    assert(js[:body].include?('label: "Refresh"') &&
           js[:body].include?("...(!server.local ? ["),
           "expected every server to refresh while local rows omit remote-only actions")
    assert(js[:body].include?("function restartRemoteServer"), "expected Remote UI to handle Remote restarts")
    assert(js[:body].include?('apiPost("/server/restart"'),
           "expected Remote UI restart action to call the restart endpoint")
    assert(js[:body].include?("function waitForRemoteRestart"),
           "expected Remote UI to poll until restart comes back online")
    assert(js[:body].include?("data-scheduler-action"),
           "expected Remote UI to expose scheduler daemon controls")
    assert(js[:body].include?('schedule?.message_source === "file"'),
           "expected inline schedules to avoid unavailable message-file requests")
    assert(js[:body].include?("calendarCheck2"),
           "expected Remote UI schedule surfaces to use the calendar-check-2 icon")
    assert(js[:body].include?("function agentListStatusIcon") &&
           js[:body].include?("function agentIdentityIcon") &&
           js[:body].include?('label: "Scheduled agent", role: "scheduled"') &&
           js[:body].include?("statusIcon || agentIdentityIcon(agent)"),
           "expected scheduled agent rows to preserve scheduling without replacing terminal status icons")
    assert(js[:body].include?("function scheduledAgentIconStatusClass") &&
           js[:body].include?("if (!schedule) return statusClass(agent);") &&
           js[:body].include?('if (scheduleStatus === "stopped") return "fail";') &&
           js[:body].include?('if (scheduleStatus === "paused"') &&
           js[:body].include?('status-mark ${escapeAttr(className)}'),
           "expected stopped and paused schedules to override associated agent icon colors")
    assert(js[:body].include?('class="schedule-details" data-state-key="schedule-now-details"'),
           "expected Remote UI schedule rows to be collapsed by default")
    assert(js[:body].include?("schedule-disclosure"),
           "expected collapsed schedule block to show a disclosure indicator")
    assert(js[:body].include?("function scheduleSectionRows"),
           "expected Schedule section rows to keep non-attention schedules visible")
    assert(!js[:body].include?("attention.length ? attention : upcomingSchedules().slice(0, 4)"),
           "expected interactive schedules not to filter out healthy schedule rows")
    assert(js[:body].include?('/schedules/daemon/${action}'),
           "expected Remote UI scheduler controls to call daemon endpoints")
    assert(js[:body].include?("data-schedule-action"),
           "expected Remote UI to expose schedule run/pause/resume controls")
    assert(js[:body].include?('label: "Run now"') &&
           js[:body].include?('attrs: `data-schedule-action="run" data-schedule-key="${escapeAttr(schedule.key)}"`') &&
           !js[:body].include?("schedule-run-button"),
           "expected schedule Run now controls to live only in each schedule context menu")
    assert(js[:body].include?("sportShoe"),
           "expected Remote UI Run now menu items to use Lucide sport-shoe")
    assert(js[:body].include?("function renderAgentScheduleMenu") &&
           js[:body].include?('data-header-schedule-menu') &&
           js[:body].include?('header-schedule-control ${scheduledAgentIconStatusClass(agent, schedule)}') &&
           js[:body].include?('label: "Run now"') &&
           js[:body].include?('const toggleAction = blocked ? "resume" : "pause"'),
           "expected scheduled agent headers to expose run and pause/resume controls")
    assert(js[:body].include?('label: "Remove schedule"') &&
           js[:body].include?("data-remove-agent-schedule") &&
           js[:body].include?("Schedule removed; conversation kept") &&
           js[:body].include?("The agent and its full session history will remain available"),
           "expected scheduled conversations to remove automation with confirmed history-preserving UX")
    assert(js[:body].include?("data-new-schedule"),
           "expected Remote UI to expose schedule creation")
    assert(js[:body].include?("${renderScheduleDaemonActions(daemon, schedules)}") &&
           js[:body].include?('data-overlay-key="schedule-daemon"') &&
           js[:body].include?('aria-label="Daemon actions"'),
           "expected daemon actions to share the New schedule toolbar behind a context menu")
    assert(js[:body].include?('label: "Restart daemon"') &&
           js[:body].include?('label: "Stop daemon"') &&
           !js[:body].include?('class="compact-actions schedule-daemon-actions"'),
           "expected restart and stop daemon controls to live only in the context menu")
    assert(js[:body].include?('label: "Loop session"') &&
           js[:body].include?("function renderAgentLoopForm") &&
           js[:body].include?('id="agent-loop-form"') &&
           js[:body].include?('apiPost(`/agents/${encodeURIComponent(agentKey)}/loop-schedule`, payload)'),
           "expected conversation context menus to create quick session loops")
    assert(js[:body].include?('id="session-loop-settings-form"') &&
           js[:body].include?('apiPatch("/settings/session-loops"') &&
           js[:body].include?("data-session-loop-template-row") &&
           js[:body].include?("session-loop-settings-actions") &&
           js[:body].include?('data-state-key="session-loop-template:${escapeAttr(stateKey)}:prompt"'),
           "expected General Settings to configure loop defaults and prompt templates")
    assert(css[:body].include?(".session-loop-settings-actions") &&
           css[:body].include?("var(--mobile-nav-height, 70px) + 24px"),
           "expected session loop settings save actions to remain reachable on mobile")
    assert(helpers_js[:body].include?('{ type: "agentLoop", segment: "loop", statePrefix: "agent-loop" }') &&
           helpers_js[:body].include?("function simpleAgentRouteValue"),
           "expected session loop forms to have a stable agent route")
    assert(js[:body].include?("state.setup?.config?.schedule_system_message_template"),
           "expected Remote UI schedule defaults to consume the backend-provided template")
    assert(js[:body].include?("data-edit-schedule") && js[:body].include?("data-delete-schedule"),
           "expected Remote UI schedule rows to expose edit and delete controls")
    assert(js[:body].include?("data-edit-schedule-message"),
           "expected file-backed schedule rows to expose message editing")
    assert(js[:body].include?("form.dataset.pendingFormKey") &&
           js[:body].include?("delete form.dataset.pendingFormKey"),
           "expected Remote UI pending forms to clear the original key after navigation")
    assert(js[:body].include?("function renderScheduleForm"),
           "expected Remote UI to render schedule create/edit forms")
    assert(js[:body].include?("function renderScheduleMessageForm"),
           "expected Remote UI to render schedule message file forms")
    assert(js[:body].include?("function ensureScheduleMessage"),
           "expected Remote UI to load schedule message markdown")
    assert(js[:body].include?('id="schedule-form"'),
           "expected Remote UI schedule forms to have a dedicated submit target")
    assert(js[:body].include?('id="schedule-message-form"'),
           "expected Remote UI schedule message forms to have a dedicated submit target")
    assert(js[:body].include?("function scheduleFormPayload"),
           "expected Remote UI to serialize schedule form payloads")
    assert(!js[:body].include?("schedule-overlap") &&
           !js[:body].include?("schedule-missed") &&
           !js[:body].include?('name="archive_previous_agent"') &&
           !js[:body].include?('name="enabled"'),
           "expected Remote UI schedule form to omit removed advanced scheduling options")
    assert(js[:body].include?('apiPost("/schedules", payload)'),
           "expected Remote UI to call the schedule create endpoint")
    assert(js[:body].include?('apiPatch(`/schedules/${encodeURIComponent(scheduleKey)}`, payload)'),
           "expected Remote UI to call the schedule update endpoint")
    assert(js[:body].include?('apiDelete(`/schedules/${encodeURIComponent(key)}`)'),
           "expected Remote UI to call the schedule delete endpoint")
    assert(js[:body].include?('apiGet(`/schedules/${encodeURIComponent(key)}/message`)'),
           "expected Remote UI to call the schedule message read endpoint")
    assert(js[:body].include?('apiPatch(`/schedules/${encodeURIComponent(scheduleKey)}/message`, payload)'),
           "expected Remote UI to call the schedule message update endpoint")
    assert(js[:body].include?('class="schedule-row-title"') &&
           js[:body].include?('statusBadge(titleFromKey(scheduleStatusLabel(schedule)), className)'),
           "expected Remote UI schedule status labels to render inline with the title")
    assert(js[:body].include?("const ends = schedule.ends_at") &&
           js[:body].include?("return `${project} / ${next}${ends} / ${humanizeCron(schedule.cron)}`;"),
           "expected Remote UI schedule rows to show optional loop expiry without last outcome")
    assert(!js[:body].include?("last ${schedule.last_status}"),
           "expected Remote UI schedule rows not to render last status text")
    assert(js[:body].include?("MagicDNS push requires Tailscale HTTPS"),
           "expected Remote UI to warn when MagicDNS is not HTTPS")
    assert(js[:body].include?("navigator.serviceWorker.register"),
           "expected Remote UI to register the service worker")
    assert(js[:body].include?("await navigator.serviceWorker.ready"),
           "expected push setup to wait for the active service worker")
    assert(js[:body].include?('push.subscribed === true') &&
           js[:body].include?('apiPost("/push/status", { endpoint: existing.endpoint })'),
           "expected push controls to track this browser instead of the global subscription count")
    assert(js[:body].include?("await existing.unsubscribe()") &&
           js[:body].include?("pushSubscriptionApplicationServerKey"),
           "expected push setup to replace expired or VAPID-mismatched browser subscriptions")
    assert(js[:body].include?("function renderAgentForm"),
           "expected Remote UI to render create/edit agent forms")
    assert(js[:body].include?("function renderOnboardingCliGuide") &&
           js[:body].include?("data-select-onboarding-cli") &&
           js[:body].include?("agent_cli_guides"),
           "expected onboarding to render selectable server-provided CLI installation guides")
    assert(js[:body].include?("No installation is needed.") &&
           js[:body].include?("aria-pressed") &&
           js[:body].include?("target=\"_blank\" rel=\"noreferrer\""),
           "expected onboarding CLI guidance to expose readiness, keyboard semantics, and safe official-doc links")
    assert(js[:body].include?("[data-select-onboarding-cli].selected") &&
           js[:body].include?("?.focus({ preventScroll: true })"),
           "expected onboarding CLI selection to retain keyboard focus after rendering")
    assert(!js[:body].include?('name="workspace"'),
           "expected Remote UI agent forms to omit editable workspace fields")
    assert(!js[:body].include?('formData.get("workspace")'),
           "expected Remote UI agent forms to let the server preserve/default workspace")
    assert(js[:body].include?("data-create-agent"),
           "expected Project detail to expose Add agent navigation")
    assert(js[:body].include?("function projectMoreMenuHtml"),
           "expected Project detail actions to render from the header More menu")
    assert(js[:body].include?('label: "Edit project"') && js[:body].include?("data-edit-project"),
           "expected Project More menu to expose edit navigation")
    assert(js[:body].include?('label: "See diff"') && js[:body].include?("function navigateProjectDiff"),
           "expected More menus to expose Project diff navigation")
    assert(js[:body].include?('label: "Browse workspace"') &&
           js[:body].include?("function renderProjectWorkspace") &&
           js[:body].include?("function ensureProjectWorkspacePreview"),
           "expected Project detail to expose the read-only workspace browser")
    assert(js[:body].include?("function performProjectWorkspaceRequest") &&
           js[:body].include?("requests[key] !== requestId"),
           "expected workspace navigation responses to be race-safe")
    assert(js[:body].include?('aria-label="Project workspace file browser"') &&
           js[:body].include?('aria-label="Workspace path"') &&
           js[:body].include?('class="workspace-text-preview" tabindex="0"'),
           "expected workspace browsing and previews to expose keyboard and screen-reader contracts")
    assert(css[:body].include?(".workspace-browser-grid") &&
           css[:body].include?("@media (max-width: 760px)"),
           "expected workspace browsing to use responsive desktop and mobile layouts")
    assert(helpers_js[:body].include?('type: "projectWorkspace"') &&
           helpers_js[:body].include?('params.set("file", route.file)') &&
           helpers_js[:body].include?('project-workspace:${route.key}:${route.path || ""}:${route.file || ""}'),
           "expected workspace directory and preview state to persist in browser history")
    assert(helpers_js[:body].include?('return { type: "projectForm", key: parts[1] };'),
           "expected Remote UI to parse Project edit routes")
    assert(js[:body].include?("function renderProjectForm"),
           "expected Remote UI to render Project edit forms")
    assert(js[:body].include?("Project Information"),
           "expected Project edit form to label read-only project metadata")
    assert(js[:body].include?('id="project-form"'),
           "expected Project edit form to use a dedicated form")
    assert(js[:body].include?('id="project-harness" name="agent"'),
           "expected Project edit form to expose default harness")
    assert(js[:body].include?("data-project-model-select"),
           "expected Project edit form to expose model choices")
    assert(!js[:body].include?('id="project-pr-url"'),
           "expected Project edit form to keep PR URL readonly")
    assert(!js[:body].include?('formData.get("pr_url")'),
           "expected Project edit form payload to omit PR URL")
    assert(js[:body].include?("function projectFormPayload"),
           "expected Project edit form to serialize project metadata")
    assert(js[:body].include?('apiPatch(`/projects/${encodeURIComponent(projectKey)}`'),
           "expected Project edit form to update projects through the API")
    assert(!js[:body].include?("Project editing opens in the TUI"),
           "expected Project detail to remove the old TUI-only edit notice")
    assert(js[:body].include?("data-edit-agent"),
           "expected Agent More menu to expose edit navigation")
    assert(js[:body].include?("data-archive-agent"),
           "expected Agent More menu to open archive choices")
    assert(js[:body].include?("Clone instead"),
           "expected archive choices to expose clone instead")
    assert(js[:body].include?("mode === \"clone\""),
           "expected Remote UI agent form to support clone mode")
    assert(js[:body].include?("els.headerMorePanel.addEventListener"),
           "expected Agent More menu actions to work from the fixed header panel")
    assert(js[:body].include?('route.type === "project" && route.backTo'),
           "expected Project Back to honor agent return crumbs")
    assert(js[:body].include?("apiPatch"),
           "expected Remote UI to update agents through the API")
    assert(js[:body].include?("function toggleSkillFlyout"), "expected Insert Skill to use a floating slash picker")
    assert(js[:body].include?("function refreshSkillAutocomplete"),
           "expected Remote UI to provide prompt skill autocomplete")
    assert(js[:body].include?("function ensureSkillsForProject"),
           "expected Remote UI autocomplete to load skills for form project/harness pairs")
    assert(js[:body].include?("skillAutocompleteToken(control, trigger)"),
           "expected Remote UI autocomplete to replace the active trigger token")
    assert(js[:body].include?("event.key === \"Enter\" || event.key === \"Tab\""),
           "expected Remote UI autocomplete to support keyboard selection")
    assert(js[:body].include?("data-skill-autocomplete-rescan"),
           "expected Remote UI autocomplete to expose a re-scan command")
    assert(js[:body].include?("ensureSkillsForProject(active.projectKey, active.harness, { force: true })"),
           "expected Remote UI autocomplete re-scan to refresh the skill cache")
    assert(js[:body].include?("function restoreSkillAutocompleteAfterRender"),
           "expected Remote UI autocomplete to persist across polling renders")
    assert(js[:body].include?("scrollSkillAutocompleteHighlightIntoView"),
           "expected Remote UI autocomplete arrows to scroll the highlighted item into view")
    assert(js[:body].include?("!event.target.closest(\"[data-skill-flyout]\")"),
           "expected Skill flyout to close when clicking outside it")
    assert(js[:body].include?("agentIsRunning(agent)"),
           "expected Send Prompt to render a running-only indicator")
    assert(js[:body].include?("iconSvg(\"loaderPinwheel\")"),
           "expected running agents to render the loader-pinwheel icon")
    assert(js[:body].include?("iconSvg(\"hourglass\")"),
           "expected polling refresh state to render a lucide hourglass icon")
    assert(js[:body].include?("state.refreshing = text === \"Refreshing\""),
           "expected polling refresh state to be tracked separately from header subtitles")
    assert(js[:body].include?("function renderHeaderSubtitle"),
           "expected refresh decoration to preserve the current route subtitle")
    assert(js[:body].include?("function agentHeaderLabel"),
           "expected Agent detail headers to combine project and harness labels")
    assert(js[:body].include?("agentHeaderLabel(agent)"),
           "expected Agent detail headers to show the selected harness beside the project")
    assert(js[:body].include?('data-toggle-skills aria-label="Insert skill" title="Insert skill">'),
           "expected Skill toggle to remain usable while the agent is running")
    assert(js[:body].include?("function agentComposerAction"),
           "expected Agent detail composer action to switch by running state")
    assert(js[:body].include?("function speechModeShortcutLabel"),
           "expected Remote UI to expose a platform-aware speech shortcut label")
    assert(js[:body].include?("function macPlatform"),
           "expected platform detection to be shared by speech and existing shortcut labels")
    assert(js[:body].include?("return `${platformShortcutModifier()}+Shift+.`;"),
           "expected speech mode to use Cmd/Ctrl+Shift+. rather than a browser-reserved shortcut")
    assert(js[:body].include?("function handleSpeechModeShortcut"),
           "expected a document-level speech-mode shortcut handler")
    assert(js[:body].include?("event.repeat || event.isComposing"),
           "expected speech shortcut to ignore held keys and IME composition")
    assert(js[:body].include?("isTextEntryFocused() && !document.activeElement?.closest?.(\"#composer\")"),
           "expected speech shortcut not to hijack other text inputs or contenteditable controls")
    assert(js[:body].include?("function speechTargetComposer"),
           "expected speech shortcut to select an eligible visible composer")
    assert(js[:body].include?("els.quickAgentDialog?.open || els.confirmationDialog?.open"),
           "expected speech shortcut to defer to open dialogs")
    assert(js[:body].include?("dialog[open], [role='dialog']"),
           "expected speech shortcut to defer to every other visible dialog")
    assert(js[:body].include?("function startSpeechMode(composer)"),
           "expected the visible Speech control and shortcut to share one activation path")
    assert(js[:body].include?("function updateSpeechModeControls"),
           "expected active Speech controls to update without waiting for a full render")
    assert(js[:body].include?("data-toggle-speech-mode"),
           "expected composers to expose a discoverable Speech mode control")
    assert(js[:body].include?("aria-keyshortcuts="),
           "expected Speech mode control to expose its shortcut to assistive technology")
    assert(js[:body].include?('type="submit" data-agent-key="${escapeAttr(agent.key)}">Queue</button>') &&
           js[:body].include?('class="agent-floating-pill stop-fab"') &&
           js[:body].include?('data-agent-action="stop" data-agent-key="${escapeAttr(agent.key)}"') &&
           js[:body].include?('iconSvg("square")'),
           "expected running agents to expose Queue in the composer and Stop in the top action row")
    assert(js[:body].include?("function renderPromptQueue") &&
           js[:body].include?('data-state-key="agent-prompt-queue:${escapeAttr(agent.key)}"'),
           "expected Agent detail to render a persistent expandable prompt queue")
    assert(js[:body].include?("data-edit-queued-prompt") && js[:body].include?("data-delete-queued-prompt") &&
           js[:body].include?("data-retry-prompt-queue"),
           "expected queued prompts to expose Edit, Delete, and failed-dispatch retry actions")
    assert(js[:body].include?('enterkeyhint="enter"'),
           "expected Agent composer textarea to hint newline-capable keyboards")
    assert(js[:body].include?('event.target?.id === "prompt-input"'),
           "expected Agent composer textarea to handle Enter submissions")
    assert(js[:body].include?("function touchKeyboardLikely"),
           "expected Agent composer Enter handling to detect touch keyboards")
    assert(js[:body].include?("event.metaKey || event.ctrlKey"),
           "expected Agent composer Enter handling to support explicit keyboard submits")
    assert(js[:body].include?("if (touchKeyboardLikely()) return;"),
           "expected Agent composer Enter handling to preserve mobile newlines")
    assert(js[:body].include?("event.shiftKey || event.isComposing"),
           "expected Agent composer Enter handling to preserve newlines and IME input")
    assert(js[:body].include?("form.requestSubmit(submitButton)"),
           "expected Agent composer Enter handling to submit through the form")
    assert(js[:body].include?("button?.dataset.agentKey || form.dataset.agentKey"),
           "expected keyboard prompt submits to resolve the agent key from the form")
    assert(js[:body].include?("iconSvg(\"squareSlash\")"), "expected Insert Skill to render a square slash SVG icon")
    assert(js[:body].include?("iconSvg(\"robot\")"), "expected Agent marks to render a robot SVG icon")
    assert(js[:body].include?("iconSvg(\"search\")"), "expected search controls to render an SVG icon")
    assert(js[:body].include?("iconSvg(\"scanText\")"), "expected Summary to render a scan-text SVG icon")
    assert(js[:body].include?("iconSvg(\"folder\")"), "expected Project marks to render a folder SVG icon")
    assert(js[:body].include?("function brandLogoHtml"), "expected HQ header mark to render the Remote UI logo")
    assert(js[:body].include?("function agentSwitcherShortcutLabel"),
           "expected the Remote UI to label the agent switcher shortcut by platform")
    assert(js[:body].include?('class="keyboard-shortcut-hint logo-shortcut-hint"'),
           "expected the Remote UI logo to render the agent switcher keyboard hint")
    assert(js[:body].include?("function setShortcutModifierActive"),
           "expected the Remote UI to track pressed shortcut modifier keys")
    assert(js[:body].include?('classList.toggle("shortcut-hints-visible", state.shortcutModifierActive)'),
           "expected the Remote UI logo shortcut hint to sync through logo rerenders")
    assert(js[:body].include?('window.addEventListener("blur", () => setShortcutModifierActive(false))'),
           "expected Remote UI shortcut hints to clear when the window loses focus")
    assert(js[:body].include?("function unreadAgents"),
           "expected the Remote UI to compute unread agents for the logo popup")
    assert(js[:body].include?("function quickSwitchAgents"),
           "expected the Remote UI logo popup to include all agents")
    assert(js[:body].include?("function compareQuickSwitchAgents"),
           "expected the Remote UI logo popup to sort unread agents first")
    assert(js[:body].include?("REMOTE_HELPERS.compareQuickSwitchAgents"),
           "expected the Remote UI logo popup to use the shared quick switch ordering")
    assert(js[:body].include?("function syncAppBadge"),
           "expected the Remote UI to sync unread agents to the PWA app badge")
    assert(js[:body].include?("navigator.setAppBadge"),
           "expected the Remote UI to use the Badging API when available")
    assert(js[:body].include?("navigator.clearAppBadge"),
           "expected the Remote UI to clear the PWA app badge when unread agents clear")
    assert(js[:body].include?("function toggleUnreadPanel"),
           "expected the Remote UI logo to toggle an agent switcher popup")
    assert(js[:body].include?("function openUnreadPanelFromKeyboard"),
           "expected the Remote UI logo switcher to open from the keyboard shortcut")
    assert(js[:body].include?("function handleUnreadPanelKeydown"),
           "expected the Remote UI logo switcher to support keyboard selection")
    assert(js[:body].include?("openSelectedSwitcherAgent"),
           "expected the Remote UI logo switcher to open the selected agent")
    assert(js[:body].include?('event.key.toLowerCase() === "k"'),
           "expected Cmd/Ctrl+K to trigger the Remote UI logo switcher")
    assert(js[:body].include?('navigate({ type: "tab", tab: "now" })'),
           "expected a second Remote UI logo click to navigate to Now")
    assert(js[:body].include?("function renderUnreadAgentsPanel"),
           "expected agents to render in a header popup")
    assert(js[:body].include?('id="unread-agent-search"') &&
           js[:body].include?("function filterQuickSwitchAgents") &&
           js[:body].include?("function focusUnreadPanelSearch"),
           "expected the agent switcher to focus and filter through a search field")
    assert(js[:body].include?("function clearUnreadPanelSearch") &&
           js[:body].include?('data-clear-unread-agent-search') &&
           js[:body].include?("if (state.unreadPanelQuery) clearUnreadPanelSearch();"),
           "expected Escape and the clear button to reset agent switcher search")
    assert(js[:body].include?('classList.toggle("unread-panel-open"'),
           "expected the Remote UI logo to track the open unread popup state")
    assert(js[:body].include?("els.mark.addEventListener(\"click\", toggleUnreadPanel)"),
           "expected the Remote UI header logo to open the unread agents popup")
    assert(js[:body].include?("function eventPathIncludes"),
           "expected the unread popup outside-click guard to survive logo re-rendering during clicks")
    assert(js[:body].include?("eventPathIncludes(event, els.mark)"),
           "expected the unread popup click guard to use the original event path for the logo")
    assert(js[:body].include?("els.mark.innerHTML = brandLogoHtml(unreadCount);"),
           "expected the Remote UI header mark to stay on the brand logo with unread state")
    assert(!js[:body].include?("function markHtml"),
           "expected page-specific icons to stay out of the header brand mark")
    assert(js[:body].include?("headerSubtitleIcon"),
           "expected header subtitle icon state to stay separate from the brand mark")
    assert(js[:body].include?("function headerSubtitleIconName"),
           "expected header subtitle icons to normalize legacy header mark aliases")
    assert(js[:body].include?('state.refreshing ? iconSvg("hourglass") : iconSvg(state.headerSubtitleIcon)'),
           "expected refresh to swap the subtitle icon without shifting the text")
    assert(js[:body].include?("function statusIcon"), "expected readiness marks to use SVG status icons")
    assert(js[:body].include?("data-agent-summary-page"), "expected Agent detail to expose a focused Summary page")
    assert(js[:body].include?("data-open-agent-summary"),
           "expected Agent summary shortcut to navigate to the focused Summary page")
    assert(js[:body].include?("function renderAgentSummaryView"),
           "expected Agent summary to render as its own view")
    assert(js[:body].include?("function runSummaryNavigation") &&
           js[:body].include?('aria-label="${label}"') &&
           js[:body].include?('title="${label}"'),
           "expected focused Summary pages to navigate between run summaries")
    assert(!js[:body].include?("function toggleAgentSummary"),
           "expected Summary to use route navigation instead of a dock toggle")
    assert(js[:body].include?("function renderAgentSummaryToggle"),
           "expected Summary toggle markup to be shared across agent views")
    assert(js[:body].include?('kind = "project-diff";') &&
           js[:body].include?('fullView: agentDetailViewMode(`${agent.key}:project-diff`) === "full"'),
           "expected agent dirty diffs to share the focused detail layout menu")
    assert(js[:body].include?("function renderAgentFloatingActions"),
           "expected Agent detail floating actions to be reusable")
    assert(!js[:body].include?("function closeAgentSummary"), "expected Summary page to avoid outside-click panel handling")
    assert(!js[:body].include?("Current activity"), "expected Current activity copy to move into Summary naming")
    assert(js[:body].include?("data-preserve-open"), "expected floating controls to preserve open state")
    assert(js[:body].include?("openElements"), "expected polling snapshots to preserve floating control state")
    assert(js[:body].include?("renderedViewHtml"),
           "expected polling renders to skip unchanged Remote UI view HTML")
    assert(js[:body].include?("preserveLiveEditor: true,") &&
           js[:body].include?("function liveEditorRefreshPlan") &&
           js[:body].include?("function reconcileViewAroundEditor"),
           "expected polling renders to reconcile around stable Conversation and inquiry forms")
    assert(js[:body].include?("replaceSiblingsAroundAnchor") &&
           js[:body].include?('data-agent-running="${running ? "true" : "false"}"'),
           "expected live editor reconciliation to preserve controls without hiding real agent state transitions")
    assert(js[:body].include?("scrollContainers"),
           "expected polling snapshots to preserve scroll positions for restored controls")
    assert(js[:body].include?("pageScroll"),
           "expected polling snapshots to preserve page scroll on same-route renders")
    assert(js[:body].include?('class="agent-detail-pane" aria-label="${escapeAttr(detailKind)}" data-preserve-scroll'),
           "expected split workspace detail panes to preserve local diff scroll across polling")
    assert(js[:body].include?('data-preserve-scroll data-preserve-poll-content data-state-key="agent-attachment:${escapeAttr(id)}"'),
           "expected embedded attachment viewers to preserve their split-pane scroll position")
    assert(js[:body].include?("preservePollContent: !options.force && !options.forceAttachment") &&
           js[:body].include?("function transplantPreservedPollContent") &&
           js[:body].include?("data-preserve-poll-content"),
           "expected scheduled polling to retain unchanged attachment content DOM")
    assert(js[:body].include?("REMOTE_HELPERS.reconcileAgentDetail(detail, agent)") &&
           js[:body].include?("focusedAgent?.detail_stale") &&
           js[:body].include?("await ensureAgentDetail(focusedAgent.key)"),
           "expected catalog revision changes to retain attachments while refreshing stale focused details")
    assert(js[:body].include?("function preserveWorkspaceDuringPoll") &&
           js[:body].include?("if (options.forceAttachment) return false") &&
           js[:body].include?("if (options.force && !options.preserveFocusedWorkspace) return false") &&
           js[:body].include?("function focusedWorkspacePreservedDuringPoll") &&
           js[:body].include?("function focusedWorkspacePollingSubtitle") &&
           js[:body].include?('"Paused",') &&
           js[:body].include?("agentProjectLabel(agent)") &&
           js[:body].include?("serverDisplayName(resourceServer(agent.server_key))") &&
           js[:body].include?("function syncFocusedWorkspaceCatalog") &&
           js[:body].include?('els.view.querySelector("#inquiry-form")') &&
           js[:body].include?("if (preservedInquiryAgent) state.agentDetails[inquiryAgentKey] = preservedInquiryAgent") &&
           js[:body].include?("const preserveCurrentWorkspace = routeChangedDuringRefresh || preserveWorkspaceDuringPoll(options)") &&
           js[:body].include?("if (!preserveCurrentWorkspace) await ensureRouteData(options)") &&
           js[:body].include?("syncFocusedWorkspaceCatalog(currentRoute)"),
           "expected focused workspace polling to reconcile catalog state without fetching or rendering route data")
    assert(js[:body].include?("state.preservePollContentDuringRender") &&
           js[:body].include?("replaceViewContent(html)"),
           "expected explicit attachment refreshes to replace preserved attachment content")
    assert(helpers_js[:body].include?("function controlScrollFor"),
           "expected polling snapshots to preserve prompt textarea scroll offsets")
    assert(js[:body].include?("function restorePageScroll"),
           "expected polling renders to restore PR diff and conversation page scroll")
    assert(js[:body].include?("state.prDiffExpandAll[agent.key] !== false"),
           "expected PR diff files to open by default")
    assert(js[:body].include?("const expand = state.prDiffExpandAll[key] === false"),
           "expected PR diff collapse-all control to toggle from the open default")
    assert(js[:body].include?("state.projectDiffExpandAll[diffKey] !== false"),
           "expected local project diff files to open by default")
    assert(js[:body].include?("data-toggle-project-diff-expand-all"),
           "expected local project diff views to expose a collapse-all control")
    assert(js[:body].include?("const expand = state.projectDiffExpandAll[key] === false"),
           "expected local project diff collapse-all control to toggle from the open default")
    assert(js[:body].include?("toggleProjectDiffExpandAllButton.innerHTML"),
           "expected local project diff collapse-all control to update in place without rerendering")
    assert(js[:body].include?("function syncPreservedOpenState"),
           "expected restored floating controls to update related button state")
    assert(js[:body].include?("const discovered = state.skills"),
           "expected discovered skills to take priority over stale per-agent skill snapshots")
    assert(!js[:body].include?("start-after-send"), "expected Send Prompt to start agents by default")
    assert(!js[:body].include?("Start run"), "expected Agent detail to omit redundant Start run")
    assert(js[:body].include?("function syncAgentDockLayout"),
           "expected Agent detail dock height to update page padding")
    assert(js[:body].include?("fullScreenComposerKeys") &&
           js[:body].include?("data-toggle-composer-full-screen") &&
           js[:body].include?("function setComposerFullScreen"),
           "expected Conversation composer to support full-screen editing across polling renders")
    assert(js[:body].include?('event.key === "Escape"') &&
           css[:body].include?(".composer-full-screen #prompt-input"),
           "expected the full-screen Conversation editor to provide keyboard exit and a viewport-filling prompt")
    assert(js[:body].include?('role="dialog" aria-modal="true"') &&
           js[:body].include?("function syncFullScreenComposerModal") &&
           js[:body].include?("element.inert = active"),
           "expected the full-screen Conversation editor to isolate an accessible modal")
    assert(!js[:body].include?("composer-full-screen-header") &&
           !js[:body].include?("composer-draft-status") &&
           js[:body].include?("composer-close-button"),
           "expected the full-screen Conversation editor to show only an X close control without explanatory chrome")
    assert(css[:body].include?(".composer-full-screen-button .ui-icon") &&
           css[:body].include?("place-items: center") &&
           css[:body].include?("border: 0"),
           "expected top-right composer controls to center their icons without borders")
    assert(js[:body].include?("function trapFullScreenComposerFocus") &&
           js[:body].include?("function queueComposerDraftSave") &&
           js[:body].include?('window.addEventListener("pagehide", flushComposerDraftSaves)'),
           "expected the full-screen Conversation editor to trap focus and save drafts continuously")
    assert(js[:body].include?("state.fullScreenComposerKeys.clear()") &&
           css[:body].include?("width: min(100%, 960px)") &&
           css[:body].include?("--composer-viewport-height"),
           "expected full-screen mode to clear on navigation and use a constrained visual-viewport layout")
    assert(js[:body].include?('["Session ID", agent.session_id || "n/a"]'),
           "expected Conversation settings to expose a copyable native session ID")
    assert(js[:body].include?("renderAgentWorkspace(agent, blocks, {") &&
           css[:body].include?(".agent-workspace.conversation-only"),
           "expected desktop conversations to keep the composer in the workspace flow")
    assert(css[:body].include?("grid-template-columns: 144px minmax(0, 1fr)") &&
           !css[:body].include?("left: calc(50% - 690px)"),
           "expected desktop primary navigation to use an uncropped shell column")
    assert(js[:body].include?('els.nav.classList.toggle("subpage-nav", subpage)') &&
           css[:body].include?(".bottom-nav.subpage-nav") &&
           css[:body].include?(".app-shell:has(> .bottom-nav:not(.hidden))"),
           "expected wide-screen primary navigation to persist across detail routes")
    assert(css[:body].include?("margin-top: calc(var(--safe-area-top) + 12px)") &&
           css[:body].include?("grid-row: 1 / span 2"),
           "expected the wide-screen sidebar to clear the page top border")
    assert(js[:body].include?('els.header.classList.remove("header-hidden")'),
           "expected detail header rendering to clear stale hidden state")
    assert(js[:body].include?("function syncDetailHeaderLayout"),
           "expected detail content padding to track header height")
    assert(!js[:body].include?("function updateDetailHeaderVisibility"),
           "expected detail header visibility to stay fixed instead of responding to scroll")
    assert(!js[:body].include?("detailFooterFocused"),
           "expected detail header to stay visible while the footer is focused")
    assert(js[:body].include?("data-go-recent"), "expected Agent conversation detail to show a Go to recent action")
    assert(js[:body].include?('!["summary", "attachment"].includes(detailKind)'),
           "expected Summary and Attachment views to omit Go to recent")
    assert(js[:body].include?("function updateGoRecentVisibility"),
           "expected Agent detail to hide Go to recent at the bottom")
    assert(js[:body].include?("function scrollConversationToRecent"),
           "expected Agent detail to scroll conversations to the recent sentinel")
    assert(js[:body].include?("function scrollAgentConversationToBottom"),
           "expected Agent detail to auto-scroll to the bottom after agent-page renders")
    assert(!js[:body].include?("preserveSummaryOnAutoScroll"),
           "expected Summary page routing to avoid preserving a docked Summary panel")
    assert(!js[:body].include?("openSummaryAfterAutoScroll"),
           "expected Agent detail scrolling to avoid reopening a docked Summary panel")
    assert(js[:body].include?("function shouldOpenSummaryForSucceededAgent"),
           "expected Agent detail to open the Summary page when the active agent succeeds")
    assert(js[:body].include?("!agentSucceeded(previous) && agentSucceeded(next)"),
           "expected Summary to open only on a success transition")
    assert(js[:body].include?('navigate({ type: "agentSummary", key: currentRoute.key });'),
           "expected successful agent transitions to navigate to the Summary page")
    assert(js[:body].include?("conversationTailMarkers"),
           "expected Agent detail to remember the latest conversation tail marker")
    assert(js[:body].include?("function markAgentReading"),
           "expected Agent detail to explicitly mark visible conversations as read")
    assert(js[:body].include?("function scheduleAgentReading"),
           "expected Agent detail to mark read from visible render state rather than data fetch")
    assert(js[:body].include?("readMarkTimer"),
           "expected Agent detail read marking to use a guarded dwell timer")
    assert(js[:body].include?("/reading"),
           "expected Agent detail read state to use the reading endpoint")
    assert(js[:body].include?('if (agent.unread) return "Unread";'),
           "expected unread agents to show unread as the visible status before final run status")
    assert(js[:body].scan('statusBadge("Unread", "need")').length >= 1,
           "expected agent list surfaces to render explicit Unread pills")
    assert(js[:body].include?("function shouldAutoScrollAgentConversation"),
           "expected Agent detail to auto-scroll only when conversation content changes")
    assert(js[:body].include?("function renderConversationBlocks"),
           "expected Agent detail to group internal conversation blocks before rendering")
    assert(js[:body].include?("function renderAgentAttachments"),
           "expected Agent detail to render saved attachments")
    assert(js[:body].include?("function dedupeAgentAttachments"),
           "expected Agent detail to dedupe saved attachments before rendering")
    assert(js[:body].include?("function attachmentDedupeKey"),
           "expected Agent detail to dedupe saved attachments by target")
    assert(js[:body].include?("function refreshAttachment"),
           "expected Attachment detail to support refreshing cached preview data")
    assert(js[:body].include?("function deleteAttachment"),
           "expected Attachment rows and detail to support deleting attachments")
    assert(js[:body].include?('const refresh = kind === "file" && id') &&
           js[:body].include?('label: "Refresh cache"') &&
           js[:body].include?("await ensureAttachment(id, true)"),
           "expected every file Attachment detail to expose a forced cache refresh action")
    assert(css[:body].include?(".agent-workspace-attachment.has-detail .agent-attachment-shell") &&
           css[:body].include?("grid-template-rows: auto minmax(0, 1fr)") &&
           js[:body].include?("function syncHeaderDetailViewRoute") &&
           js[:body].include?("setHeaderDetailView(agent && kind ? renderAgentDetailViewMenu(agent, kind)"),
           "expected Attachment navigation and viewer to use separate rows with the view menu in the page header")
    assert(js[:body].include?("data-delete-attachment"),
           "expected Attachment list and detail to expose delete actions")
    assert(js[:body].include?('label: kind === "file" ? "Copy absolute path" : "Copy link"') &&
           js[:body].include?('data-copy="${escapeAttr(target)}"'),
           "expected Attachment detail to expose explicit absolute-path and link copy actions")
    assert(js[:body].include?('data-attachment-viewer-menu') &&
           js[:body].include?('aria-label="Attachment actions"'),
           "expected Attachment detail utilities to use an accessible ellipsis menu")
    assert(js[:body].include?("function copyAttachmentContent") &&
           js[:body].include?("function copyAttachmentImageToClipboard"),
           "expected Attachment detail to copy supported attachment content")
    assert(js[:body].include?("data-copy-attachment-content"),
           "expected Attachment detail to expose a content copy action")
    assert(js[:body].include?("data-close-attachment-viewer-menu") &&
           js[:body].include?("function closeAttachmentViewerMenus"),
           "expected Attachment detail menu actions and outside clicks to close the menu")
    assert(js[:body].include?('label = "Copy image"') &&
           js[:body].include?('label = attachment.content_truncated ? "Copy preview" : "Copy content"'),
           "expected Attachment detail content copy actions to label images, full text, and truncated previews clearly")
    assert(js[:body].include?('showGrowl("Use download for binary files", "need")'),
           "expected binary attachment copy attempts to direct users to download")
    assert(js[:body].include?("function renderAttachmentToggle"),
           "expected Agent detail to expose attachments from a composer toggle")
    assert(js[:body].include?("function renderPendingAttachments"),
           "expected Agent detail to render pending prompt attachments before sending")
    assert(js[:body].include?("function pendingAttachmentPayloads"),
           "expected Remote UI to serialize prompt attachments into API payloads")
    assert(js[:body].include?("function pendingAttachmentDedupeKey"),
           "expected Remote UI pending attachments to dedupe repeated browser files")
    assert(js[:body].include?("state.pendingPromptAttachments[agentKey] = accepted.concat(pending);"),
           "expected Remote UI pending attachments to prepend newly added files")
    assert(js[:body].include?('els.view.addEventListener("paste"'),
           "expected Agent detail composer to listen for pasted attachment files")
    assert(js[:body].include?("function handleClipboardAttachmentPaste"),
           "expected Remote UI to route pasted clipboard files into pending attachments")
    assert(js[:body].include?("function clipboardAttachmentFiles"),
           "expected Remote UI to extract files from clipboard data")
    assert(js[:body].include?('els.view.addEventListener("dragover"'),
           "expected Agent detail composer to listen for dragged attachment files")
    assert(js[:body].include?("function handlePromptAttachmentDrop"),
           "expected Remote UI to route dropped files into pending attachments")
    assert(js[:body].include?("function dataTransferHasFiles"),
           "expected Remote UI to ignore non-file drag events")
    assert(js[:body].include?("Drop files to attach"),
           "expected Remote UI composer drop overlay to explain the action")
    assert(js[:body].include?("function clipboardAttachmentFilename"),
           "expected Remote UI to synthesize filenames for nameless clipboard blobs")
    assert(js[:body].include?("new File([file], filename"),
           "expected Remote UI to wrap nameless clipboard blobs with safe filenames")
    assert(js[:body].include?("data-add-prompt-attachment"),
           "expected Agent detail composer to expose a file picker trigger")
    assert(js[:body].include?("data-prompt-attachment-input"),
           "expected Agent detail composer to include a hidden file input")
    assert(!js[:body].include?("accept="),
           "expected Agent detail composer file input to allow any file type")
    assert(js[:body].include?("content_base64"),
           "expected Remote UI prompt attachments to submit base64 file content")
    assert(js[:body].include?("function renderMessageAttachments"),
           "expected chat messages to render their own attachment rows")
    assert(js[:body].include?("function formatJsonObjectMessage"),
           "expected Remote UI to parse JSON object user replies for display")
    assert(js[:body].include?("includeUserFeedback: inquiryResponseBlock(block)") &&
           js[:body].include?('entries.push(["user_feedback", null])'),
           "expected historical inquiry responses to show blank user feedback")
    assert(js[:body].include?("function inquiryResponseBlock"),
           "expected Remote UI to detect inquiry response messages")
    assert(js[:body].include?("function runSummaryNumber"),
           "expected Remote UI to label each run summary with its stable run number")
    assert(js[:body].include?('return iconSvg("badgeQuestionMark")'),
           "expected Remote UI inquiry responses to reuse the inquiry icon")
    assert(js[:body].include?("function humanizeJsonKey"),
           "expected Remote UI parsed replies to humanize JSON keys")
    assert(js[:body].include?("return words.toUpperCase();"),
           "expected Remote UI parsed reply keys to render as all-caps")
    assert(js[:body].include?('return inquiryResponseBlock(block) ? "user answers" : blockLabel(block);'),
           "expected Remote UI inquiry responses to use the user answers label")
    assert(js[:body].include?('class="parsed-json-key"'),
           "expected Remote UI parsed replies to style key labels")
    assert(js[:body].include?('class="parsed-json-value"'),
           "expected Remote UI parsed replies to italicize answer values")
    assert(js[:body].include?("escapeHtml(humanizeJsonKey(key))"),
           "expected Remote UI parsed reply keys to render without trailing punctuation")
    assert(js[:body].include?("JSON.stringify(value, null, 2)"),
           "expected Remote UI parsed replies to preserve non-string JSON values")
    assert(js[:body].include?("function renderAttachmentViewer"),
           "expected Remote UI to render attachment detail routes")
    assert(js[:body].include?("function renderAgentAttachmentView"),
           "expected Agent detail to render attachment views without losing the composer")
    assert(js[:body].include?("${renderAgentFloatingActions(agent)}"),
           "expected Agent detail attachment view to expose the Summary page shortcut")
    assert(js[:body].include?("renderAgentFloatingActions(agent, { recent: true })"),
           "expected Agent conversation view to keep the Go to recent shortcut")
    assert(js[:body].include?("function renderAttachmentNavigationDrawer"),
           "expected Agent detail attachment view to render a navigation drawer")
    assert(js[:body].include?('data-state-key="attachment-nav"'),
           "expected Attachment navigation drawer state to be restorable")
    assert(js[:body].include?('aria-current="page"'),
           "expected Attachment navigation to mark the current attachment")
    assert(js[:body].include?("function attachmentViewerHtml"),
           "expected Attachment viewer markup to be reusable inside Agent detail")
    assert(helpers_js[:body].include?('return { type: "agentAttachment", key: parts[1], attachmentId: parts[3] };'),
           "expected Remote UI to support in-agent attachment routes")
    assert(helpers_js[:body].include?('return { type: "agentSummary", key: parts[1], summaryId: parts[3] || "" };'),
           "expected Remote UI to support in-agent Summary routes")
    assert(helpers_js[:body].include?('const suffix = route.summaryId ? `/${encodeURIComponent(route.summaryId)}` : "";'),
           "expected Remote UI to generate in-agent Summary route hashes")
    assert(helpers_js[:body].include?('routeHash({ type: "agentAttachment", key: agentKey, attachmentId: id })'),
           "expected document attachments to open inside the owning Agent detail")
    assert(js[:body].include?("function formDraftRouteKey"),
           "expected composer drafts to survive switching between conversation and attachment views")
    assert(js[:body].include?("function saveAgentShellFormDrafts"),
           "expected focused composer drafts to be saved before attachment route switches")
    assert(js[:body].include?("Loading file preview") && js[:body].include?("Loading image"),
           "expected attachment views to use the Tycho loading state before preview data loads")
    assert(!js[:body].include?("Preview unavailable for this file."),
           "expected unsupported attachment formats to render download actions instead of preview messaging")
    assert(js[:body].include?("function renderAgentViewToggle"),
           "expected Agent detail attachment view to expose icon-only conversation switching")
    assert(js[:body].include?("data-open-agent"),
           "expected icon-only conversation switching to use Agent navigation")
    assert(!js[:body].include?("function renderAgentAttachmentToggle"),
           "expected attachment views to omit the old Conversation header")
    assert(js[:body].include?("function ensureAttachmentImage"),
           "expected Remote UI to fetch authenticated image blobs")
    assert(js[:body].include?("function apiBlob"),
           "expected Remote UI to support non-JSON attachment blob responses")
    assert(js[:body].include?("function downloadAttachmentFile"),
           "expected Remote UI to download attachments through authenticated fetch")
    assert(js[:body].include?("data-download-attachment"),
           "expected Remote UI attachment download controls to opt into authenticated downloads")
    assert(js[:body].include?('attrs: `data-download-attachment="${escapeAttr(id)}"') &&
           !js[:body].include?('<a class="icon-button attachment-viewer-icon-action" href="${escapeAttr(download)}" data-download-attachment='),
           "expected Remote UI attachment detail downloads to use background button handlers instead of navigational links")
    assert(js[:body].include?("event.preventDefault();") &&
           js[:body].include?("downloadAttachmentButton.dataset.downloadAttachment"),
           "expected Remote UI attachment download clicks to avoid unauthenticated navigation")
    assert(js[:body].include?("URL.createObjectURL"),
           "expected Remote UI to render fetched image blobs through object URLs")
    assert(js[:body].include?('class="attachment-image-viewer"'),
           "expected Remote UI to render image attachments as images")
    assert(helpers_js[:body].include?('const path = `/attachments/${encodeURIComponent(id)}/blob`;'),
           "expected Remote UI to load images from the attachment blob route")
    assert(helpers_js[:body].include?('return { type: "attachment", id: parts[1] };'),
           "expected Remote UI to support #attachment/:id routes")
    assert(js[:body].include?("function renderMarkdown"),
           "expected markdown attachments to render as markdown")
    assert(js[:body].include?("function prepareMarkdownCodeBlocks") &&
           js[:body].include?("function renderMarkdownCodeMenu"),
           "expected fenced Markdown code blocks to expose reusable action menus")
    assert(js[:body].include?("data-toggle-markdown-code-menu") &&
           js[:body].include?("data-close-markdown-code-menu"),
           "expected Markdown code menus to support isolated toggles and copy actions")
    assert(js[:body].include?("markdownMenuScope: `conversation:${index}:${blockStateToken(block)}`") &&
           js[:body].include?("menuScope: `attachment:${id}`"),
           "expected Markdown code menus to use their owning message or attachment as a stable scope")
    assert(js[:body].include?("renderMarkdown(content, { breaks: true, menuScope: `attachment:${id}` })") &&
           js[:body].include?("breaks: options.breaks === true"),
           "expected only markdown attachment call sites to opt into single-newline breaks")
    assert(js[:body].include?("function renderHtmlAttachment") &&
           js[:body].include?('sandbox="allow-popups allow-scripts"'),
           "expected HTML attachments to render in a script-capable sandbox")
    assert(js[:body].include?("function sandboxedHtmlDocument") &&
           js[:body].include?("\"form-action 'none'\"") &&
           js[:body].include?("\"object-src 'none'\""),
           "expected sandboxed HTML previews to include a restrictive content policy")
    assert(js[:body].include?("function renderRunSummaryMessageContent"),
           "expected run summaries to render as compact Conversation blocks")
    assert(js[:body].include?("function renderSummarySections") &&
           js[:body].include?('class="summary-sections" aria-label="Structured summary details"') &&
           js[:body].include?("block?.metadata?.summary_sections"),
           "expected every run-summary surface to render ordered rich summary blocks")
    assert(css[:body].include?(".summary-section-text") && css[:body].include?(".summary-section-attachment"),
           "expected rich summary text and attachments to have focused styling")
    assert(js[:body].include?('data-open-agent-summary="${escapeAttr(agentKey)}"'),
           "expected compact run summaries to link to the full Summary page")
    assert(js[:body].include?('block.role === "assistant"'),
           "expected assistant messages to render as markdown")
    assert(js[:body].include?("function renderAgentSummaryContent"),
           "expected Agent summary text to render as markdown")
    assert(js[:body].include?("function runSummaryDetailContent") &&
           js[:body].include?('excerpt === `${status}: ${firstLine}` ? detail : content'),
           "expected full Summary pages to remove duplicated status-prefixed excerpts")
    assert(js[:body].include?('viewerClassName: "markdown-viewer message-markdown-viewer"'),
           "expected chat markdown to use message-scoped markdown styling")
    assert(js[:body].include?('viewerClassName: "markdown-viewer agent-summary-markdown-viewer"'),
           "expected Agent summary markdown to use focused page styling")
    assert(js[:body].include?("function renderMarkdownRoute"),
           "expected markdown parser load completion to re-render active markdown routes")
    assert(js[:body].include?("CODE_LANGUAGE_BY_EXTENSION"),
           "expected text attachments to infer syntax languages from file extensions")
    assert(js[:body].include?("function renderCodeAttachment"),
           "expected text attachments to render with the code attachment viewer")
    assert(js[:body].include?("https://cdn.jsdelivr.net/npm/prismjs@"),
           "expected code highlighting to lazy-load Prism from a pinned CDN URL")
    assert(js[:body].include?("https://cdn.jsdelivr.net/npm/marked@"),
           "expected markdown rendering to lazy-load marked from a pinned CDN URL")
    assert(js[:body].include?("https://cdn.jsdelivr.net/npm/dompurify@"),
           "expected markdown rendering to sanitize parsed HTML with DOMPurify")
    assert(js[:body].include?("https://cdn.jsdelivr.net/npm/mermaid@11.15.0/") &&
           js[:body].include?("function prepareMarkdownCodeBlocks") &&
           js[:body].include?("function queueMermaidRendering"),
           "expected Mermaid code fences to lazy-load and render through a pinned CDN build")
    assert(js[:body].include?('securityLevel: "strict"'),
           "expected Mermaid rendering to use strict security mode")
    assert(js[:body].include?("function renderPlainTextMarkdown"),
           "expected markdown rendering to fall back to escaped plain text")
    assert(helpers_js[:body].include?('routeHash({ type: "attachment", id })'),
           "expected document attachments to open the attachment viewer")
    assert(js[:body].include?('target="_blank" rel="noreferrer"'),
           "expected link attachments to open in a new tab")
    assert(!js[:body].include?('const description = String(attachment?.description'),
           "expected attachment rows not to render descriptions")
    assert(js[:body].include?("function toggleAttachmentFlyout"),
           "expected Agent detail attachments to be toggleable")
    assert(js[:body].include?("aria-controls=\"agent-attachment-flyout\"") &&
           js[:body].include?("function handleAttachmentFlyoutKeydown") &&
           js[:body].include?("button.focus({ preventScroll: true })"),
           "expected attachment flyouts to retain named trigger and Escape focus behavior")
    assert(js[:body].include?("data-preserve-open data-state-key=\"agent-attachment-flyout\"") &&
           js[:body].include?("attachment-list\" data-preserve-scroll data-state-key=\"agent-attachment-flyout-list\""),
           "expected attachment flyout open state and list scroll state to persist independently")
    assert(js[:body].include?("!event.target.closest(\"[data-attachment-flyout]\")"),
           "expected Attachment flyout to close when clicking outside it")
    assert(js[:body].include?('aria-label="Upload file"') && js[:body].include?("iconSvg(\"upload\")"),
           "expected upload control to render the lucide upload SVG icon")
    assert(js[:body].include?('${iconSvg("paperclip")}<span class="attachment-count">'),
           "expected Attachment toggle to render a paperclip SVG icon")
    assert(js[:body].include?("function attachmentHref"),
           "expected Agent detail attachments to only link safe browser-openable targets")
    assert(js[:body].include?("iconSvg(\"fileText\")"),
           "expected document attachments to use the file-text SVG icon")
    assert(js[:body].include?("iconSvg(\"image\")"),
           "expected image attachments to use the image SVG icon")
    assert(js[:body].include?("iconSvg(\"link\")"),
           "expected link attachments to use the link SVG icon")
    assert(js[:body].include?("primaryConversationBlock"),
           "expected Agent detail to keep user and assistant messages visible")
    assert(js[:body].include?('block?.kind === "run_summary"'),
           "expected Agent detail to keep legacy run summary rendering compatible")
    assert(helpers_js[:body].include?("summaryId: parts[3] || \"\""),
           "expected Agent detail summary routes to support per-summary pages")
    assert(js[:body].include?("data-open-agent-summary-id"),
           "expected run summary rows to open their own full summary")
    assert(js[:body].include?("<span>Open</span>"),
           "expected run summary rows to use a compact Open label")
    assert(js[:body].include?("queueRunSummaryConversationScroll"),
           "expected per-summary pages to scroll the conversation to the opened summary")
    assert(js[:body].include?("pendingSummaryScrollId"),
           "expected per-summary conversation scrolling to be a one-shot click action")
    assert(js[:body].include?("consumePendingRunSummaryConversationScroll"),
           "expected polling renders not to re-scroll already-open summaries")
    assert(js[:body].include?("data-missing-summary-attachment"),
           "expected stale summary attachments to show a growl instead of navigating")
    assert(js[:body].include?("renderSummaryAttachmentMenu"),
           "expected Conversation summary attachments to use a menu trigger")
    assert(js[:body].include?("Choose summary attachment"),
           "expected Conversation summary attachment menus to be accessible")
    assert(js[:body].include?('data-state-key="summary-attachment-menu:${escapeAttr(summaryId)}"'),
           "expected Conversation summary attachment menus to preserve open state across polling")
    assert(js[:body].include?("function repositionOpenSummaryAttachmentMenus"),
           "expected restored summary attachment menus to recompute viewport-safe popover coordinates")
    assert(js[:body].include?("closeSummaryAttachmentMenus();"),
           "expected Summary attachment menus to close on outside clicks")
    assert(js[:body].include?("renderSummaryAttachmentList"),
           "expected detailed Summary pages to render attachment list blocks")
    assert(js[:body].include?('class="summary-attachment-download icon-button ui-button ui-icon-button"') &&
           js[:body].include?('data-download-filename="${escapeAttr(title || "attachment")}"'),
           "expected detailed Summary pages to download files without replacing their detail links")
    assert(js[:body].include?('kv("Est. Cost", sessionCostSnapshotText(summary.costSnapshot))'),
           "expected detailed Summary pages to render the finalized session-cost snapshot")
    assert(!js[:body].include?('kv("Completed", timeShort(summary.createdAt'),
           "expected detailed Summary pages to avoid repeating the header timestamp")
    assert(js[:body].include?('return "Untracked";'),
           "expected missing Summary cost snapshots to use compact copy")
    assert(js[:body].include?("function sessionCostSnapshotText") &&
           js[:body].include?('snapshot.coverage === "partial"'),
           "expected Summary cost formatting to distinguish partial tracking")
    assert(js[:body].include?("costSnapshot: block.metadata?.cost_snapshot || null"),
           "expected historical Summary pages to use their own cost snapshots")
    assert(js[:body].include?("Open attachment"),
           "expected Summary attachment menu items to remain individually accessible")
    assert(js[:body].include?("Attachment might have been removed."),
           "expected stale summary attachment growl copy")
    assert(js[:body].include?("<details class=\"message-group\""),
           "expected Agent detail internal groups to be collapsed by default")
    assert(js[:body].include?('block?.kind === "validation_retry"') &&
           js[:body].include?("function renderSystemEventBlock") &&
           js[:body].include?("function renderValidationRetryBlock") &&
           js[:body].include?('<span class="validation-retry-brand">TYCHO</span>'),
           "expected structured-output retries to render as collapsed Tycho system event blocks")
    assert(js[:body].include?("system-event-block validation-retry-block") &&
           css[:body].include?(".system-event-block.validation-retry-block") &&
           css[:body].include?(".validation-retry-errors"),
           "expected Tycho system event blocks to have compact expandable styling")
    assert(js[:body].include?("function renderCodexTurnCompletedContent"),
           "expected Codex turn completion summaries to render parsed metrics")
    assert(js[:body].include?("function agentUsageSummaryBlock") &&
           js[:body].include?('"result"'),
           "expected Claude result summaries to render parsed metrics")
    assert(js[:body].include?("function opencodeStepFinishBlock") &&
           js[:body].include?('"step_finish"'),
           "expected OpenCode step_finish summaries to render parsed metrics")
    assert(js[:body].include?("formatCurrencyMetric") &&
           js[:body].include?("formatDurationMetric"),
           "expected Claude result metrics to include cost and duration formatting")
    assert(js[:body].include?("formatCompactMetricNumber"),
           "expected Codex usage metrics to use compact number formatting")
    assert(js[:body].include?("codexTurnCompletedCopyText") &&
           js[:body].include?('`${metric.copyLabel}: ${metric.fullValue}`'),
           "expected Codex turn completion copy text to include full metric labels")
    assert(js[:body].include?("return metrics.filter(Boolean);"),
           "expected usage summary metrics to discard unavailable optional metrics before copy text rendering")
    assert(js[:body].include?("iconSvg(\"squareUserRound\")"),
           "expected user chat labels to render the square-user-round icon")
    assert(js[:body].include?("iconSvg(\"botMessageSquare\")"),
           "expected assistant chat labels to render the bot-message-square icon")
    assert(js[:body].include?("checkCheck") &&
           js[:body].include?('return iconSvg("checkCheck")'),
           "expected usage completion labels to render the Lucide check-check icon")
    assert(js[:body].include?("iconSvg(\"hammer\")"),
           "expected tool chat labels to render the hammer icon")
    assert(js[:body].include?('icon: "hardHat"') &&
           js[:body].include?('data-agent-role="${role}"') &&
           js[:body].include?('label: "Orchestrator"'),
           "expected orchestrator names to render an accessible hard-hat role icon")
    assert(js[:body].include?('icon: "hammer"') &&
           js[:body].include?('label: "Subagent"'),
           "expected delegated subagent names to render an accessible hammer role icon")
    assert(js[:body].include?('icon: "shieldUser"') &&
           js[:body].include?('label: "Taken-over subagent"'),
           "expected taken-over subagent names to render an accessible shield-user role icon")
    assert(css[:body].include?(".agent-name-inline") &&
           css[:body].include?("display: inline-flex;"),
           "expected delegation role icons to remain inline with agent names")
    assert(css[:body].include?(".agent-name-role-icon.subagent {\n  color: var(--accent);") &&
           css[:body].include?(".agent-name-role-icon.takeover {\n  color: var(--warning);"),
           "expected agent-controlled roles to be purple and user takeover roles to be orange")
    assert(js[:body].include?("options.agentTitle") &&
           js[:body].include?("els.title.innerHTML = agentNameHtml(options.agentTitle);"),
           "expected Conversation headers to render agent role icons")
    assert(js[:body].include?("function agentReferenceNameHtml") &&
           js[:body].include?("renderAgentReference(reference, { embedded: true, relationshipRole })"),
           "expected connected-agent references to render delegation role icons")
    assert(js[:body].include?("function parentAgentMessageAuthor") &&
           js[:body].include?('parentAgentMessage(block) ? "parent-agent-message"') &&
           js[:body].include?('if (parentAgentMessage(block)) return iconSvg("hardHat")'),
           "expected parent-authored user messages to show the signing agent")
    assert(css[:body].include?(".message.user.parent-agent-message .message-role") &&
           css[:body].include?("text-transform: none;"),
           "expected parent-authored messages to retain the right-aligned user treatment with an agent signature")
    assert(js[:body].include?('class="switcher-agent-title-line">${agentNameHtml(agent, state.unreadPanelQuery)}${linkedSymbol}') &&
           js[:body].include?('aria-label="Show linked agents"') &&
           !js[:body].include?('${iconSvg("link")}<span>${escapeHtml(String(linkedCount))}</span>'),
           "expected Quick Agents to place a count-free linked control beside the agent name")
    assert(js[:body].include?("function replaceView"), "expected UI JavaScript to centralize view replacement")
    assert(js[:body].include?("FORM_DRAFT_STORAGE_PREFIX"),
           "expected Remote UI to persist blurred text form drafts")
    assert(js[:body].include?("function formDraftStorageKey"),
           "expected Remote UI draft storage to use dedicated form keys")
    assert(js[:body].include?("routeStateKey(parseRoute())"),
           "expected Remote UI form drafts to be scoped by route")
    assert(js[:body].include?("form.dataset.inquiryId"),
           "expected Remote UI inquiry drafts to be scoped by inquiry id")
    assert(js[:body].include?('els.view.addEventListener("focusout"'),
           "expected Remote UI to save text form drafts on blur")
    assert(js[:body].include?("restoreFormDrafts();"),
           "expected Remote UI to restore form drafts after rendering")
    assert(js[:body].include?("function setFormPending"),
           "expected non-composer Remote UI forms to disable controls while requests are pending")
    assert(js[:body].include?("pendingComposerKeys"),
           "expected Remote UI chat composer sending state to survive optimistic conversation re-renders")
    assert(js[:body].include?("agentComposerRunning(findAgent(key))") &&
           js[:body].include?('type="submit" data-agent-key="${escapeAttr(agent.key)}">Queue</button>'),
           "expected an in-flight first prompt to switch immediately to an enabled queue composer")
    assert(js[:body].include?("OPTIMISTIC_PROMPT_QUEUE_STORAGE_PREFIX") &&
           js[:body].include?("addOptimisticPromptQueueEntry") &&
           js[:body].include?("reconcileOptimisticPromptQueue(agent)"),
           "expected optimistic queued prompts to persist locally until server reconciliation")
    assert(js[:body].include?("if (!queueing) setComposerSending(form, true);") &&
           js[:body].include?('const pendingMessageId = queueing ? "" : addPendingConversationMessage'),
           "expected Remote UI to clear ordinary prompts before optimistic rendering and omit queued prompts from conversation")
    assert(js[:body].include?("pendingConversationMessages"),
           "expected Remote UI to render optimistic pending chat messages")
    assert(js[:body].include?("pull_request_contexts: pullRequestContexts") &&
           js[:body].include?("removePendingConversationMessage(key, pendingMessageId, { render: false });"),
           "expected Remote UI to remove optimistic chat before refreshing server-backed conversation")
    assert(js[:body].include?("loadingConversations"),
           "expected Remote UI to track conversation loading per agent")
    assert(js[:body].include?("state.loadingConversation = Object.keys(state.loadingConversations).length > 0;"),
           "expected Remote UI per-agent conversation loading to preserve the global loadingConversation flag")
    assert(js[:body].include?("function conversationLoadingState"),
           "expected Remote UI to render a loading state before empty conversations are fetched")
    assert(js[:body].include?("function tychoLoadingState"),
           "expected Remote UI loading states to share the pulsating Tycho logo")
    assert(js[:body].include?("function emptyState") &&
           js[:body].include?('data-state="${escapeAttr(stateName)}"'),
           "expected empty states to expose a stable state contract without live-region semantics")
    assert(js[:body].include?("function feedbackMessage") &&
           js[:body].include?('options.announce === "assertive"') &&
           js[:body].include?('options.announce === "polite"'),
           "expected feedback messages to separate visual intent from announcement timing")
    assert(js[:body].include?('data-state="loading" role="status" aria-live="polite" aria-atomic="true"'),
           "expected loading states to announce progress once as a polite atomic status")
    assert(js[:body].include?('feedbackMessage("Diff unavailable", diff.error, {') &&
           js[:body].include?('announce: "assertive"'),
           "expected asynchronous diff failures to use assertive feedback semantics")
    assert(js[:body].include?("Loading conversation"),
           "expected Remote UI conversation loading copy to avoid showing an empty state while fetching")
    assert(js[:body].include?("Loading pull requests") &&
           js[:body].include?("Loading PR diff") &&
           js[:body].include?("Loading diff"),
           "expected PR and local diff loading states to use the Tycho loading state")
    assert(js[:body].include?('class="message-send-status">sending...</div>'),
           "expected Remote UI pending chat status copy to stay concise")
    assert(js[:body].include?("clearFormDraft(form)"),
           "expected Remote UI to clear submitted or cancelled form drafts")
    assert(js[:body].include?("function syncMarkdownHeadingAnchors"),
           "expected Remote UI to add stable anchors to rendered Markdown headings")
    assert(js[:body].include?("function handleMarkdownAnchorClick"),
           "expected Remote UI to intercept Markdown attachment hash links")
    assert(js[:body].include?('.markdown-viewer a[href^=\\"#\\"]'),
           "expected Remote UI to scope in-document hash link handling to Markdown viewers")
    assert(js[:body].include?("history.replaceState(null, \"\", routeHash(route))"),
           "expected Markdown hash links to preserve the attachment route")
    assert(js[:body].include?('const TOP_TABS = ["now", "agents", "settings"];'),
           "expected Remote UI to keep the paused review inbox out of top-level navigation")
    assert(!response[:body].include?('data-tab="reviews"'),
           "expected Remote UI to hide the paused review inbox")
    assert(!helpers_js[:body].include?('parts[0] === "reviews"'),
           "expected legacy review inbox hashes to fall back to Now without fetching review data")
    assert(helpers_js[:body].include?('if (parts[0] === "search" || parts[0] === "projects") return { type: "tab", tab: "agents" };'),
           "expected legacy Search and Projects hashes to land on Agents")
    assert(helpers_js[:body].include?('return "#settings/hidden";'),
           "expected Hidden settings to use the Settings route")
    assert(js[:body].include?('setHeader("Settings"'),
           "expected Setup screen to be labeled Settings")
    assert(js[:body].include?("function agentProjectGroups"),
           "expected Agents tab to render project groups in sorted order")
    assert(js[:body].include?("function renderGroupedAgentLedger") &&
           !js[:body].include?("agent-group-count"),
           "expected Agents tab project sorting to omit project agent counts")
    assert(js[:body].include?("function serverHealthIconBadge") &&
           js[:body].include?('iconName = server?.status === "online" && !server?.stale ? "wifi" : "wifiOff"') &&
           js[:body].include?("serverIdentityBadge(project || agents[0], { compactHealth: true })"),
           "expected Agents tab project groups to show compact Wi-Fi health icons")
    assert(js[:body].include?('class="summary-card attention attention-summary"') &&
           js[:body].include?('class="attention-summary-copy"') &&
           js[:body].include?('>Answer next</button>') &&
           js[:body].include?('aria-label="Answer ${escapeAttr(waiting[0]?.name || "next agent")}"') &&
           !js[:body].include?("Answer paused agents first.") &&
           !css[:body].include?(".big-number") &&
           css[:body].include?(".attention-summary-action"),
           "expected Now to use a compact waiting-attention header")
    now_section_order = ["${nowSection}", "${unreadSection}", "${runningSection}", "${scheduleSection}"]
      .map { |section| js[:body].index(section) }
    assert(now_section_order.none?(&:nil?) && now_section_order == now_section_order.sort,
           "expected Schedules to render after every agent list on Now")
    assert(js[:body].include?("const FORM_POLL_QUIET_MS = 3_000;") &&
           js[:body].include?("function deferPollAfterFormInput") &&
           js[:body].include?('target.closest("form")') &&
           js[:body].include?('document.addEventListener("input", deferPollAfterFormInput, true)') &&
           js[:body].include?("quietRemaining > 0 && !options.force"),
           "expected form typing to defer automatic polling for three seconds")
    assert(js[:body].include?("function fullScreenEditorOpen") &&
           js[:body].include?("if (fullScreenEditorOpen()) return;") &&
           js[:body].include?("if (fullScreenEditorOpen() && !options.force) return;") &&
           js[:body].scan("state.fullScreenComposerKeys.delete(key);\n  schedule();").length >= 1 &&
           js[:body].scan("state.fullScreenInquiryKeys.delete(key);\n  schedule();").length >= 1,
           "expected full-screen Conversation and inquiry forms to pause automatic polling")
    activity_poll = js[:body][/async function pollAgentActivity\(\).*?^}/m]
    assert(activity_poll && !activity_poll.include?("fullScreenEditorOpen"),
           "expected logo activity polling to continue while full-screen editors are open")
    assert(js[:body].include?('class="card agent-summary-card') &&
           js[:body].include?("serverIdentityBadge(agent, { compactHealth: true })") &&
           js[:body].include?('class="agent-card-status"') &&
           js[:body].include?("agentListSubtextHtml(agent)") &&
           js[:body].include?('class="card-copy agent-card-excerpt"') &&
           css[:body].include?(".agent-card-excerpt") &&
           css[:body].include?("font-style: italic"),
           "expected Now agent cards to align server health with status and separate excerpts")
    assert(js[:body].include?("agent-group-project-title") &&
           js[:body].include?('iconSvg("folder")'),
           "expected compact project headers to show an unboxed folder icon beside the project name")
    assert(js[:body].include?("function compareAgentProjectKeys"),
           "expected Agents tab group sorting to compare project display names")
    assert(helpers_js[:body].include?("function compareAgentsByName"),
           "expected Agents tab to sort agents alphabetically within each project group")
    assert(js[:body].include?("rankMatchingAgents(serverFilteredAgents(), query, compareAgentsForCurrentSort)"),
           "expected Agents tab filtering to use ranked agent search")
    assert(!js[:body].include?("No managed agents"),
           "expected Agents tab to omit redundant zero-agent empty rows")
    assert(js[:body].include?("agent-group-create"),
           "expected Agents tab to keep zero-agent projects reachable from the group header")
    assert(js[:body].include?('class="sr-only">New agent</span>'),
           "expected compact per-project create controls to retain an accessible text label")
    assert(js[:body].include?("data-toggle-bulk-archive"),
           "expected Agents tab toolbar to expose bulk archive selection mode")
    assert(js[:body].include?("data-run-bulk-archive"),
           "expected Agents tab bulk menu to expose bulk archive submission")
    assert(js[:body].include?("data-cancel-bulk-archive"),
           "expected Agents tab bulk menu to expose selection cancellation")
    assert(!js[:body].include?("agent-bulk-trigger"),
           "expected Agents tab bulk actions to avoid a separate ellipsis trigger")
    assert(js[:body].include?('const path = resourceApiPath(serverKey, "/agents/archive")') &&
           js[:body].include?("agents.map(resourceRawKey)"),
           "expected Remote UI to group bulk archive calls by owner server")
    assert(js[:body].include?("function agentArchiveable"),
           "expected Remote UI to guard running agents from bulk archives")
    assert(js[:body].include?("function relativeTimeShort"),
           "expected Remote UI list metadata to use compact relative times")
    assert(js[:body].include?("function relativeTimeBucket"),
           "expected Remote UI list metadata to bucket relative times by recency")
    assert(js[:body].include?("function relativeTimeHtml"),
           "expected Remote UI list metadata to color only relative time tokens")
    assert(js[:body].include?("function agentListSubtextHtml"),
           "expected Agents tab rows to build dedicated list subtitles")
    assert(js[:body].include?('class="relative-time ${escapeAttr(bucket)}"'),
           "expected Remote UI agent subtitles to render colorable relative time spans")
    assert(!js[:body].include?("function renderSearch"),
           "expected Search tab rendering to be removed")
    assert(!js[:body].include?("function renderProjects"),
           "expected Projects tab rendering to be removed")
    assert(!js[:body].include?("${statusLabel(agent)} / ${agentMeta(agent)}"),
           "expected Agents tab rows to omit status from subtext")
    assert(!js[:body].include?("agent.project_key, agent.agent, agent.template_key"),
           "expected Remote UI list metadata to omit agent template keys")
    assert(!js[:body].include?('agent.template_key || "template"'),
           "expected Remote UI agent cards to omit agent template keys")
    direct_view_writes = js[:body].scan(/els\.view\.innerHTML\s*=\s*(?!\s*html\b)/)
    assert(direct_view_writes.empty?, "expected page renderers to use replaceView so polling preserves form state")
    assert(!js[:body].include?("detail.open === detail.hasAttribute"),
           "expected details state preservation to avoid reflected open-attribute comparison")

    favicon_request = HQ::RemoteServer.const_get(:Request).new(
      method: "GET",
      path: "/favicon.ico",
      headers: {},
      body: ""
    )
    assert(server.send(:ui_request?, favicon_request), "expected favicon to be recognized as a UI route")
    favicon = server.send(:route_ui, "/favicon.ico")
    assert(favicon[:content_type].include?("image/png"), "expected favicon to return the PNG logo")
    assert(favicon[:body].byteslice(0, 8) == "\x89PNG\r\n\x1A\n".b, "expected favicon body to be a PNG")

    logo = server.send(:route_ui, "/remote-logo.png")
    assert(logo[:content_type].include?("image/png"), "expected Remote UI logo route to return PNG")
    assert(logo[:body].bytesize.positive?, "expected Remote UI logo route to return image bytes")

    horizontal_logo = server.send(:route_ui, "/remote-logo-horizontal.png")
    assert(horizontal_logo[:content_type].include?("image/png"), "expected Remote UI horizontal logo route to return PNG")
    assert(horizontal_logo[:body].bytesize.positive?, "expected Remote UI horizontal logo route to return image bytes")

    manifest_request = HQ::RemoteServer.const_get(:Request).new(
      method: "GET",
      path: "/manifest.webmanifest",
      headers: {},
      body: ""
    )
    assert(server.send(:ui_request?, manifest_request), "expected manifest to be recognized as a UI route")
    manifest = server.send(:route_ui, "/manifest.webmanifest")
    assert(manifest[:content_type].include?("application/manifest+json"),
           "expected manifest route to return a web app manifest")
    parsed_manifest = JSON.parse(manifest[:body])
    assert(parsed_manifest["name"] == "Tycho - Factorio for Agents",
           "expected manifest name to match the Remote UI page title")
    assert(parsed_manifest["short_name"] == "Tycho", "expected manifest short name to use Tycho")
    assert(parsed_manifest["display"] == "standalone", "expected manifest to install as a standalone PWA")
    assert(parsed_manifest["id"] == "/", "expected manifest id to use the Remote UI root")
    assert(parsed_manifest["start_url"] == "/", "expected manifest to start at the Remote UI root")
    assert(parsed_manifest["theme_color"] == "#282a36", "expected manifest to match the Remote UI theme")
    assert(parsed_manifest["icons"].any? { |icon| icon["sizes"] == "192x192" },
           "expected manifest to expose a 192px icon")
    assert(parsed_manifest["icons"].any? { |icon| icon["sizes"] == "512x512" },
           "expected manifest to expose a 512px icon")
    assert(parsed_manifest["icons"].any? { |icon| icon["purpose"].to_s.include?("maskable") },
           "expected manifest to expose a maskable icon")

    apple_icon = server.send(:route_ui, "/apple-touch-icon.png")
    assert(apple_icon[:content_type].include?("image/png"), "expected Apple touch icon route to return PNG")
    pwa_icon = server.send(:route_ui, "/pwa-icon-192.png")
    assert(pwa_icon[:content_type].include?("image/png"), "expected PWA icon route to return PNG")
  end

  def assert_write_http_keeps_keyword_body_compatibility
    server = HQ::RemoteServer.new(logger: Logger.new(StringIO.new), output: StringIO.new)
    client = StringIO.new

    server.send(:write_http, client, 401, error: "Unauthorized")

    response = client.string
    assert(response.include?("HTTP/1.1 401 Unauthorized"), "expected keyword body response to include status")
    assert(response.include?('"error": "Unauthorized"'), "expected keyword body response to include JSON error")
  end

  def assert_server_prints_public_url
    output = StringIO.new
    logger = Logger.new(StringIO.new)
    server = HQ::RemoteServer.new(public_url: "http://hq.tailnet.test:7373/", logger: logger, output: output)

    server.send(:log_server, "Remote UI available at http://hq.tailnet.test:7373/")

    line = output.string
    assert(line.include?("Remote UI available at http://hq.tailnet.test:7373/"),
           "expected console log to include public UI URL")
  end

  def assert_server_prints_startup_messages
    output = StringIO.new
    logger = Logger.new(StringIO.new)
    server = HQ::RemoteServer.new(startup_messages: ["Tailscale detected; using MagicDNS hq.tailnet.test"],
                                  logger: logger, output: output)

    server.instance_variable_get(:@startup_messages).each { |message| server.send(:log_server, message) }

    line = output.string
    assert(line.include?("[Remote]"), "expected startup messages to use Remote prefix")
    assert(line.include?("Tailscale detected; using MagicDNS hq.tailnet.test"),
           "expected startup messages to include Tailscale notice")
  end

  def assert_server_prints_public_url_qr
    output = StringIO.new
    logger = Logger.new(StringIO.new)
    server = HQ::RemoteServer.new(public_url: "http://hq.tailnet.test:7373/", logger: logger, output: output)

    server.send(:log_server, "Scan this QR code to open HQ Remote")
    output.puts
    output.puts(HQ::TerminalQR.render("http://hq.tailnet.test:7373/"))

    rendered = output.string
    assert(rendered.include?("Scan this QR code to open HQ Remote"), "expected QR scan instruction")
    assert(rendered.include?("Remote\n\n"), "expected blank line before terminal QR")
    assert(rendered.include?("▀"), "expected terminal QR half-block characters")
  end

  def assert_server_daemonizes_after_startup_to_log
    Dir.mktmpdir("hq-remote-daemon-test") do |dir|
      output = StringIO.new
      logger = Logger.new(StringIO.new)
      daemonized = []
      log_path = File.join(dir, "remote_server_daemon.log")
      server = HQ::RemoteServer.new(
        logger: logger,
        output: output,
        daemon_log_path: log_path,
        daemonizer: ->(nochdir, noclose) { daemonized << [nochdir, noclose] }
      )

      server.send(:daemonize_after_startup!)

      assert(daemonized == [[true, false]], "expected server to detach without changing cwd")
      assert(output.string.include?("Remote server daemonizing; logs at #{log_path}"),
             "expected startup output to show daemon log path")
      assert(File.read(log_path).include?("Remote server daemon started with PID"),
             "expected daemon output to continue in the daemon log")
    end
  end

  class RecordingPushNotifier
    attr_reader :payloads

    def initialize
      @payloads = []
    end

    def config
      {
        configured: true,
        public_key: "test-public-key",
        subject: "mailto:test@example.invalid",
        subscription_count: 1
      }
    end

    def send_payload!(payload, **_options)
      @payloads << payload
      { sent: 1, failed: 0, attempted: 1 }
    end

    def send_test!(endpoint: nil)
      { sent: endpoint.to_s.empty? ? 0 : 1, failed: 0, attempted: endpoint.to_s.empty? ? 0 : 1 }
    end
  end

  def stale_running_agent(key:, name:, workspace:, started_at:, structured_result: nil)
    log_path = File.join(HQ::AGENT_LOGS_DIR, "#{key}.raw.log")
    File.write(log_path, stale_agent_log(started_at, structured_result))
    HQ::ManagedAgent.new(
      key: key,
      name: name,
      project_key: "web",
      template_key: "default",
      workspace: workspace,
      prompt: "Work on the task.",
      started_at: started_at,
      pid: 999_999,
      log_path: log_path,
      runs: [
        HQ::ManagedAgent::AgentRun.new(
          started_at: started_at,
          status: "running",
          log_path: log_path
        )
      ]
    )
  end

  def hidden_test_agent(key, project_key, workspace)
    HQ::ManagedAgent.new(
      key: key,
      name: key,
      project_key: project_key,
      template_key: "custom",
      workspace: workspace,
      prompt: "Work on #{project_key}.",
      agent: "codex"
    )
  end

  def stale_agent_log(started_at, structured_result)
    lines = ["=== [#{started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ==="]
    lines << JSON.generate(structured_result) if structured_result
    "#{lines.join("\n")}\n"
  end

  def registry_for(dir, workspace)
    config_path = File.join(dir, "hq.yml")
    prompts_path = File.join(dir, "system_prompts.yml")
    File.write(config_path, <<~YAML)
      custom_harnesses:
        - key: claude-wrapper
          adapter: claude
          execution_command: claude-wrapper
      projects:
        - key: web
          name: Web
          path: #{workspace}
    YAML
    File.write(prompts_path, <<~YAML)
      custom: Default prompt.
    YAML
    HQ::Registry.new(path: config_path, system_prompts_path: prompts_path)
  end

  def with_remote_temp_store
    Dir.mktmpdir("hq-remote-test") do |dir|
      old_agents_file = replace_constant(HQ, :AGENTS_FILE, File.join(dir, "managed_agents.json"))
      old_delegations_file = replace_constant(HQ, :DELEGATIONS_FILE, File.join(dir, "agent_delegations.json"))
      old_server_identity_file = replace_constant(HQ, :SERVER_IDENTITY_FILE, File.join(dir, "server_identity.json"))
      old_usage_metrics_file = replace_constant(HQ, :USAGE_METRICS_FILE, File.join(dir, "usage_metrics.json"))
      old_schedules_file = replace_constant(HQ, :SCHEDULES_FILE, File.join(dir, "config", "schedules.yml"))
      old_schedules_state_file = replace_constant(HQ, :SCHEDULES_STATE_FILE, File.join(dir, "schedules.json"))
      old_scheduler_daemon_file = replace_constant(HQ, :SCHEDULER_DAEMON_FILE, File.join(dir, "scheduler_daemon.json"))
      old_user_schedules_dir = replace_constant(HQ, :USER_SCHEDULES_DIR, File.join(dir, "schedules"))
      old_logs_dir = replace_constant(HQ, :AGENT_LOGS_DIR, File.join(dir, "agents"))
      old_archive_dir = replace_constant(HQ, :AGENT_ARCHIVE_DIR, File.join(dir, "agents", "archive"))
      old_project_logs_dir = replace_constant(HQ, :PROJECT_LOGS_DIR, File.join(dir, "projects"))
      old_project_archive_dir = replace_constant(HQ, :PROJECT_ARCHIVE_DIR, File.join(dir, "projects", "archived"))
      old_push_file = replace_constant(HQ, :PUSH_SUBSCRIPTIONS_FILE, File.join(dir, "push_subscriptions.json"))
      old_push_notifications_file = replace_constant(HQ, :PUSH_NOTIFICATIONS_FILE,
                                                     File.join(dir, "push_notifications.json"))
      old_vapid_file = replace_constant(HQ, :WEB_PUSH_VAPID_FILE, File.join(dir, "web_push_vapid.json"))
      old_process_detection = ENV["TYCHO_DISABLE_SCHEDULE_PROCESS_DETECTION"]
      ENV["TYCHO_DISABLE_SCHEDULE_PROCESS_DETECTION"] = "1"

      FileUtils.mkdir_p(HQ::AGENT_LOGS_DIR)
      FileUtils.mkdir_p(HQ::AGENT_ARCHIVE_DIR)
      FileUtils.mkdir_p(HQ::PROJECT_LOGS_DIR)
      FileUtils.mkdir_p(HQ::PROJECT_ARCHIVE_DIR)
      FileUtils.mkdir_p(File.dirname(HQ::SCHEDULES_FILE))
      FileUtils.mkdir_p(HQ::USER_SCHEDULES_DIR)
      yield dir
    ensure
      replace_constant(HQ, :AGENTS_FILE, old_agents_file) if old_agents_file
      replace_constant(HQ, :DELEGATIONS_FILE, old_delegations_file) if old_delegations_file
      replace_constant(HQ, :SERVER_IDENTITY_FILE, old_server_identity_file) if old_server_identity_file
      replace_constant(HQ, :USAGE_METRICS_FILE, old_usage_metrics_file) if old_usage_metrics_file
      replace_constant(HQ, :SCHEDULES_FILE, old_schedules_file) if old_schedules_file
      replace_constant(HQ, :SCHEDULES_STATE_FILE, old_schedules_state_file) if old_schedules_state_file
      replace_constant(HQ, :SCHEDULER_DAEMON_FILE, old_scheduler_daemon_file) if old_scheduler_daemon_file
      replace_constant(HQ, :USER_SCHEDULES_DIR, old_user_schedules_dir) if old_user_schedules_dir
      replace_constant(HQ, :AGENT_LOGS_DIR, old_logs_dir) if old_logs_dir
      replace_constant(HQ, :AGENT_ARCHIVE_DIR, old_archive_dir) if old_archive_dir
      replace_constant(HQ, :PROJECT_LOGS_DIR, old_project_logs_dir) if old_project_logs_dir
      replace_constant(HQ, :PROJECT_ARCHIVE_DIR, old_project_archive_dir) if old_project_archive_dir
      replace_constant(HQ, :PUSH_SUBSCRIPTIONS_FILE, old_push_file) if old_push_file
      replace_constant(HQ, :PUSH_NOTIFICATIONS_FILE, old_push_notifications_file) if old_push_notifications_file
      replace_constant(HQ, :WEB_PUSH_VAPID_FILE, old_vapid_file) if old_vapid_file
      if old_process_detection
        ENV["TYCHO_DISABLE_SCHEDULE_PROCESS_DETECTION"] = old_process_detection
      else
        ENV.delete("TYCHO_DISABLE_SCHEDULE_PROCESS_DETECTION")
      end
    end
  end

  def registry_for_project(dir, workspace)
    config_path = File.join(dir, "hq.yml")
    prompts_path = File.join(dir, "system_prompts.yml")
    File.write(config_path, <<~YAML)
      custom_harnesses:
        - key: claude-wrapper
          adapter: claude
          execution_command: claude-wrapper
      projects:
        - key: web
          name: Web
          group: Core
          path: #{workspace}
          pr_url: https://github.com/example/web/pull/123
    YAML
    File.write(prompts_path, <<~YAML)
      custom: Default prompt for %{project_key}.
    YAML
    HQ::Registry.new(path: config_path, system_prompts_path: prompts_path)
  end

  def write_project_workspace(workspace)
    FileUtils.mkdir_p(workspace)
  end

  def with_fixture_http_server(handler)
    tcp = TCPServer.new("127.0.0.1", 0)
    port = tcp.addr[1]
    stop = false
    thread = Thread.new do
      until stop
        begin
          client = tcp.accept
        rescue IOError, Errno::EBADF
          break
        end

        begin
          request = read_fixture_http_request(client)
          response = handler.call(request)
          write_fixture_http_response(client, response)
        rescue StandardError => e
          write_fixture_http_response(
            client,
            status: 500,
            content_type: "application/json",
            body: JSON.generate(error: e.message)
          )
        ensure
          client&.close
        end
      end
    end

    yield "http://127.0.0.1:#{port}"
  ensure
    stop = true
    tcp&.close
    thread&.join(1)
    thread&.kill if thread&.alive?
  end

  def read_fixture_http_request(client)
    request_line = client.gets&.strip
    method, raw_path = request_line.to_s.split(/\s+/, 3)
    headers = {}
    while (line = client.gets)
      line = line.chomp
      break if line.empty?

      name, value = line.split(":", 2)
      headers[name.to_s.downcase] = value.to_s.strip unless name.to_s.empty?
    end
    body = client.read(headers["content-length"].to_i).to_s
    path, query = raw_path.to_s.split("?", 2)
    {
      method: method.to_s.upcase,
      path: path.to_s,
      query: query.to_s,
      headers: headers,
      body: body
    }
  end

  def write_fixture_http_response(client, response)
    status = response.fetch(:status)
    body = response.fetch(:body, "").to_s
    content_type = response.fetch(:content_type, "application/json")
    client.write "HTTP/1.1 #{status} OK\r\n"
    client.write "Content-Type: #{content_type}\r\n"
    client.write "Content-Length: #{body.bytesize}\r\n"
    response.fetch(:headers, {}).each do |name, value|
      client.write "#{name}: #{value}\r\n"
    end
    client.write "Connection: close\r\n"
    client.write "\r\n"
    client.write body
  end

  def git!(workspace, *args)
    return if system("git", "-C", workspace, *args, out: File::NULL, err: File::NULL)

    raise "git #{args.join(" ")} failed"
  end

  def with_stubbed_agent_start
    original = HQ::ManagedAgent.instance_method(:start!)
    HQ::ManagedAgent.define_method(:start!) do
      now = Time.now
      FileUtils.mkdir_p(File.dirname(raw_log_path))
      File.write(raw_log_path, "prompt=#{send(:prompt_for_execution)}\n")
      @started_at = now
      @finished_at = now
      @last_exit_code = 0
      @pid = nil
      @runs << HQ::ManagedAgent::AgentRun.new(
        started_at: now,
        finished_at: now,
        exit_code: 0,
        status: "succeeded",
        log_path: raw_log_path,
        command: "stubbed"
      )
      self
    end
    yield
  ensure
    HQ::ManagedAgent.define_method(:start!, original)
  end

  def with_stubbed_agent_start_error(message)
    original = HQ::ManagedAgent.instance_method(:start!)
    HQ::ManagedAgent.define_method(:start!) { raise message }
    yield
  ensure
    HQ::ManagedAgent.define_method(:start!, original)
  end

  def write_test_executable(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, path)
  end

  def write_opencode_with_table_output(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~SH)
      #!/bin/sh
      if [ "$1" = "models" ]; then
        printf 'Provider MODEL\\n'
        printf 'opencode/model-test\\n'
        exit 0
      fi
      if [ "$1" = "auth" ] && [ "$2" = "list" ]; then
        printf 'Provider Status\\n'
        printf '\\342\\224\\200\\342\\224\\200\\n'
        printf 'anthropic logged-in\\n'
        exit 0
      fi
      exit 0
    SH
    File.chmod(0o755, path)
  end

  def with_env_values(values)
    old_values = {}
    had_keys = {}
    values.each_key do |key|
      had_keys[key] = ENV.key?(key)
      old_values[key] = ENV[key]
    end
    values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    values.each_key do |key|
      had_keys[key] ? ENV[key] = old_values[key] : ENV.delete(key)
    end
  end

  def write_archived_config(dir)
    File.write(File.join(dir, HQ::Registry::DEFAULT_ARCHIVED_BASENAME), <<~YAML)
      projects:
        - key: archived
          name: Archived
          path: #{File.join(dir, "archived")}
    YAML
  end

  def wait_for_agent_terminal_status(service, key, timeout: 15.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      payload = service.agent(key)
      return payload if %w[succeeded failed stopped blocked].include?(payload[:status].to_s)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise "expected agent #{key} to finish within #{timeout}s" if now >= deadline

      sleep 0.05
    end
  end

  def assert_server_prints_request_logs
    output = StringIO.new
    logger = Logger.new(StringIO.new)
    server = HQ::RemoteServer.new(logger: logger, output: output)
    request = HQ::RemoteServer.const_get(:Request).new(
      method: "GET",
      path: "/agents",
      headers: {},
      body: ""
    )

    server.send(:log_request, request, 200, Process.clock_gettime(Process::CLOCK_MONOTONIC))

    line = output.string
    assert(line.include?("[Remote]"), "expected console log to include Remote prefix")
    assert(line.include?("GET /agents 200"), "expected console log to include request method, path, and status")
    assert(line.include?("ms"), "expected console log to include duration")
  end

  class FakeScheduleDaemonSupervisor
    attr_reader :calls

    def initialize
      @calls = []
    end

    def start!(interval:, dry_run:)
      @calls << [:start, interval, dry_run]
      {
        started: true,
        daemon: {
          status: "starting",
          interval: interval,
          dry_run: dry_run
        }
      }
    end

    def stop!
      @calls << [:stop]
      {
        stopped: true,
        daemon: {
          status: "stopped"
        }
      }
    end

    def restart!(interval:, dry_run:)
      @calls << [:restart, interval, dry_run]
      {
        restarted: true,
        daemon: {
          status: "starting",
          interval: interval,
          dry_run: dry_run
        }
      }
    end
  end

  class FakeGitHubReviewClient
    attr_reader :requests, :review_posts
    attr_accessor :head_sha

    def initialize
      @requests = []
      @head_sha = "head"
      @review_posts = 0
    end

    def enabled?
      true
    end

    def capability
      { enabled: true, api_url: "https://api.github.test" }
    end

    def get_json(path, **)
      @requests << [:get_json, path]
      HQ::GitHubAPIClient::Response.new(
        status: 200,
        body: {
          "title" => "Shared PR",
          "body" => "Review this change.",
          "html_url" => "https://github.com/example/web/pull/123",
          "state" => "open",
          "draft" => false,
          "mergeable" => true,
          "mergeable_state" => "clean",
          "user" => { "login" => "author" },
          "base" => { "sha" => "base", "ref" => "main" },
          "head" => { "sha" => @head_sha, "ref" => "feature" },
          "changed_files" => 1,
          "updated_at" => "2026-07-28T00:00:00Z"
        },
        headers: {},
        rate_limit: { remaining: 100 },
        not_modified: false
      )
    end

    def get_text(path, **)
      @requests << [:get_text, path]
      HQ::GitHubAPIClient::Response.new(
        status: 200,
        body: "diff --git a/app.rb b/app.rb\n--- a/app.rb\n+++ b/app.rb\n@@ -1 +1 @@\n-old\n+new\n",
        headers: {},
        not_modified: false
      )
    end

    def paginate(path, **)
      @requests << [:paginate, path]
      [[], nil]
    end

    def post_json(path, _payload, **)
      @requests << [:post_json, path]
      if path.end_with?("/pulls/123/reviews")
        @review_posts += 1
        return HQ::GitHubAPIClient::Response.new(
          status: 200,
          body: { "id" => 9001, "html_url" => "https://github.com/example/web/pull/123#pullrequestreview-9001" },
          headers: {},
          not_modified: false
        )
      end

      HQ::GitHubAPIClient::Response.new(
        status: 200,
        body: {
          "data" => {
            "repository" => {
              "pullRequest" => {
                "reviewDecision" => nil,
                "reviewThreads" => { "nodes" => [] },
                "commits" => { "nodes" => [] }
              }
            }
          }
        },
        headers: {},
        not_modified: false
      )
    end
  end

  class BlockingGitHubDiffClient
    attr_reader :metadata_started, :metadata_requests, :diff_requests

    def initialize
      @metadata_started = Queue.new
      @lock = Mutex.new
      @condition = ConditionVariable.new
      @released = false
      @metadata_requests = 0
      @diff_requests = 0
    end

    def enabled?
      true
    end

    def get_json(_path, **)
      @metadata_requests += 1
      @metadata_started << true
      @lock.synchronize { @condition.wait(@lock) until @released }
      HQ::GitHubAPIClient::Response.new(
        status: 200,
        body: {
          "title" => "Shared PR",
          "html_url" => "https://github.com/example/web/pull/123",
          "head" => { "sha" => "head", "ref" => "feature" },
          "base" => { "sha" => "base", "ref" => "main" }
        },
        headers: {},
        not_modified: false
      )
    end

    def get_text(_path, accept:, **)
      @diff_requests += 1
      HQ::GitHubAPIClient::Response.new(
        status: 200,
        body: <<~DIFF,
          diff --git a/app.rb b/app.rb
          --- a/app.rb
          +++ b/app.rb
          @@ -1 +1 @@
          -old
          +new
        DIFF
        headers: {},
        not_modified: false
      )
    end

    def release!
      @lock.synchronize do
        @released = true
        @condition.broadcast
      end
    end
  end

  class CountingPullRequestDiffStore < HQ::PullRequestDiff::Store
    attr_reader :all_calls

    def initialize(path)
      super
      @all_calls = 0
    end

    def all
      @all_calls += 1
      super
    end
  end

  class FakeUnavailableGitHubClient
    def enabled?
      true
    end

    def get_json(*)
      raise HQ::GitHubAPIClient::Error.new("GitHub metadata unavailable", status: 503)
    end
  end

  class FakeGitHubAuthClient
    def enabled?
      false
    end

    def capability
      {
        enabled: false,
        available: true,
        source: "none",
        app: { configured: true, authenticated: false },
        gh: { available: true, authenticated: true }
      }
    end

    def start_device_flow
      {
        id: "login-id",
        user_code: "ABCD-EFGH",
        verification_uri: "https://github.com/login/device",
        interval: 5,
        expires_at: "2026-07-29T10:00:00Z"
      }
    end

    def poll_device_flow(id)
      raise "unexpected login id" unless id == "login-id"

      { status: "authenticated", account: "octocat" }
    end

    def logout
      { enabled: true, available: true, source: "gh" }
    end
  end

  def assert(condition, message)
    raise message unless condition
  end

  def replace_constant(mod, name, value)
    old = mod.const_get(name)
    mod.send(:remove_const, name)
    mod.const_set(name, value)
    old
  end
end

RemoteServerTest.run! if $PROGRAM_NAME == __FILE__
