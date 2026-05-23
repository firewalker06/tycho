# frozen_string_literal: true

require "fileutils"

TEST_LOGS_ROOT = File.expand_path("../logs/test", __dir__)
ENV["TYCHO_LOGS_ROOT"] = TEST_LOGS_ROOT
ENV["TYCHO_GLAMOUR_SYNC"] = "1"
FileUtils.rm_rf(TEST_LOGS_ROOT)
FileUtils.mkdir_p(TEST_LOGS_ROOT)

require_relative "../lib/hq/app"
require_relative "../lib/hq/cli"
require "tmpdir"

module RenderingTest
  module_function

  WEB_PROJECT_ICON = "\u{f059f}"
  FOLDER_PROJECT_ICON = "\u{f07b}"
  CURSOR_MARKER = HQ::UI::Rendering::Styles::MARKERS[:cursor]
  UNREAD_MARKER = HQ::UI::Rendering::Styles::MARKERS[:unread]

  def run!
    old_config_path = ENV["TYCHO_CONFIG_PATH"]
    fixture_dir = Dir.mktmpdir("hq-rendering-config-test")
    ENV["TYCHO_CONFIG_PATH"] = write_rendering_config_fixture(fixture_dir)

    original_fetch = HQ::VersionLookup.method(:fetch_latest_gem_version)
    HQ::VersionLookup.singleton_class.send(:define_method, :fetch_latest_gem_version) do |gem_name|
      { "kamal" => "2.11.0", "rails" => "8.1.3" }[gem_name]
    end

    original_load = HQ::AgentStore.instance_method(:load)
    original_save = HQ::AgentStore.instance_method(:save)
    HQ::AgentStore.define_method(:load) { [] }
    HQ::AgentStore.define_method(:save) { |_agents| nil }

    assert_main_screen_keeps_header_visible
    assert_loading_screen_renders_hq_logotype
    assert_app_boot_refreshes_project_metadata
    assert_missing_config_opens_new_project_form
    assert_concurrent_project_metadata_uses_each_dotenv
    assert_project_without_proxy_host_is_not_healthchecked
    assert_main_screen_shows_detail_panel_and_footer
    assert_empty_project_state_mentions_new_project_shortcut
    assert_empty_agent_state_mentions_new_agent_shortcut
    assert_terminal_shortcut_is_ctrl_g_and_global
    assert_interactive_agent_terminal_shortcut_is_ctrl_t
    assert_overlay_replaces_detail_when_open
    assert_rendered_lines_fit_screen_width
    assert_list_sidebar_renders_agent_names
    assert_list_sidebar_renders_project_status_icons
    assert_list_sidebar_scrolls_to_selected_agent
    assert_failed_project_action_with_healthy_app_renders_warning_status
    assert_agent_unread_cursor_and_chat_clear
    assert_finished_agent_poll_marks_unread
    assert_exited_agent_poll_marks_unread_after_status_turns_idle
    assert_omnisearch_empty_query_lists_unread_agents
    assert_omnisearch_reindexes_when_unread_agent_appears
    assert_omnisearch_fuzzy_selects_project
    assert_omnisearch_matches_multi_rune_agent_query
    assert_omnisearch_matches_agent_project_name
    assert_omnisearch_query_changes_select_first_result
    assert_omnisearch_treats_alphabetical_hotkeys_as_query_text
    assert_omnisearch_only_opens_from_visible_sidebar
    assert_list_sidebar_hides_when_toggled_off
    assert_detail_overlay_opens_full_screen
    assert_agent_detail_omits_conversation_and_recent_runs
    assert_agent_detail_renders_project_git_metadata
    assert_project_detail_renders_log_locations
    assert_project_detail_renders_last_action_status
    assert_projects_list_renders_group_rows
    assert_log_overlay_renders_in_right_panel
    assert_project_log_shortcut_opens_action_log
    assert_chat_screen_renders_transcript_and_composer
    assert_chat_section_labels_use_tag_backgrounds
    assert_chat_attachments_render_compact_and_overlay
    assert_chat_user_message_detail_includes_attachments
    assert_chat_expands_tool_messages
    assert_chat_collapses_tool_messages
    assert_chat_load_selects_latest_block
    assert_chat_load_bottom_aligns_latest_block
    assert_summary_enter_opens_scrollable_layer
    assert_chat_groups_consecutive_message_headers
    assert_chat_formats_json_user_replies_as_key_value_blocks
    assert_chat_composer_wraps_long_prompt
    assert_chat_composer_wraps_on_word_boundary
    assert_text_inputs_preserve_multi_rune_paste
    assert_raw_paste_buffer_is_not_truncated
    assert_running_chat_hides_live_output_and_keeps_pending_prompt
    assert_structured_result_overrides_fallback_summary_and_status
    assert_structured_result_persists_attachments
    assert_input_required_result_renders_structured_inquiry
    assert_multi_field_inquiry_shows_one_field_at_a_time
    assert_multi_select_inquiry_renders_checkbox_picker
    assert_inquiry_form_requires_review_step_before_submit
    assert_inquiry_form_submission_serializes_json
    assert_composed_prompt_includes_compact_tool_summaries_from_memory
    assert_agent_chat_log_projects_from_memory_without_raw_log
    assert_agent_raw_log_shortcut_displays_full_file
    assert_codex_failed_run_error_appears_in_chat_log
    assert_failed_run_summary_from_memory_appears_in_chat_log
    assert_chat_q_only_closes_from_content_focus
    assert_chat_content_focus_scrolls_with_arrow_keys
    assert_chat_block_selection_scrolls_with_large_messages
    assert_agent_editor_renders_template_and_harness_choices
    assert_web_project_icon_renders_for_project_contexts
    assert_non_app_project_uses_folder_icon
    assert_project_archive_moves_config_logs_and_agents
    assert_failed_kamal_action_log_marks_action_failed
    assert_create_agent_keeps_project_tool_system_prompt
    assert_create_and_run_raw_log_includes_project_tool_system_prompt
    assert_create_agent_starts_immediately_and_uses_selected_harness
    assert_create_agent_without_run_opens_chat_but_does_not_start
    assert_clone_agent_uses_fresh_state_and_defaults_to_archive
    assert_clone_agent_can_keep_old_agent
    assert_custom_claude_harness_builds_configured_command
    assert_claude_schema_is_compact_json
    assert_agent_session_id_persists_and_renders
    assert_claude_resume_uses_incremental_prompt
    assert_codex_session_id_is_captured_from_log
    assert_failed_claude_run_does_not_reuse_previous_structured_result
    assert_codex_agent_message_unwraps_structured_payload
    assert_glamour_worker_renders_sample_markdown
    puts "rendering_test: ok"
  ensure
    if defined?(original_fetch) && original_fetch
      HQ::VersionLookup.singleton_class.send(:define_method, :fetch_latest_gem_version) do |gem_name|
        original_fetch.call(gem_name)
      end
    end
    HQ::AgentStore.define_method(:load, original_load) if defined?(original_load) && original_load
    HQ::AgentStore.define_method(:save, original_save) if defined?(original_save) && original_save
    ENV["TYCHO_CONFIG_PATH"] = old_config_path if defined?(old_config_path)
    FileUtils.rm_rf(fixture_dir) if defined?(fixture_dir)
    FileUtils.rm_rf(TEST_LOGS_ROOT)
  end

  def write_rendering_config_fixture(dir)
    %w[hq warehouse demo-web].each do |name|
      FileUtils.mkdir_p(File.join(dir, name))
    end

    config_path = File.join(dir, "hq.yml")
    File.write(config_path, <<~YAML)
      custom_harnesses:
        - key: claude-wrapper
          adapter: claude
          execution_command:
            - /usr/local/bin/claude-wrapper
      projects:
        - key: hq
          name: hq
          group: Personal
          path: #{File.join(dir, "hq")}
          apps: false
        - key: warehouse
          name: warehouse
          group: Personal
          path: #{File.join(dir, "warehouse")}
          apps: true
        - key: demo-web
          name: Demo Web
          group: Example
          path: #{File.join(dir, "demo-web")}
          apps: false
    YAML

    File.write(File.join(dir, "system_prompts.yml"), <<~YAML)
      custom: Test custom prompt for %{project_key}.
      implementer: Implement inside %{workspace}.
      reviewer: Review %{project_name}.
    YAML

    config_path
  end

  def assert_main_screen_keeps_header_visible
    output = render_main_screen(:agents, width: 120, height: 30)
    lines = output.lines.map(&:chomp)

    assert(lines.length <= 30, "expected output to fit within 30 lines, got #{lines.length}")
    assert(lines[0].include?("HQ - Ops Cockpit"), "expected title on first line")
    assert(lines[1].include?("1. Agents"), "expected agents tab on second line")
    assert(lines[1].include?("2. Projects"), "expected projects tab on second line")
    assert(lines[1].include?("Latest:"), "expected latest versions on second line")
    assert(lines[1].include?("2.11.0"), "expected kamal version text on second line")
    assert(lines[1].include?("8.1.3"), "expected rails version text on second line")
  end

  def assert_loading_screen_renders_hq_logotype
    app = app_with_default_agent(width: 120, height: 30)
    app.instance_variable_set(:@loading, true)
    app.instance_variable_set(:@last_refresh, nil)
    app.instance_variable_set(:@progress_done, 1)
    app.instance_variable_set(:@progress_total, 3)
    app.instance_variable_get(:@progress).width = 36

    plain = Bubbles::ANSI.strip(app.view)

    assert(plain.include?("██╗  ██╗ ██████╗"), "expected loading screen to render the HQ logotype")
    assert(!plain.include?("Mission Grid"), "expected loading screen to omit logo option labels")
    assert(!plain.include?("+---+---+"), "expected loading screen to omit the mission grid icon")
  end

  def assert_app_boot_refreshes_project_metadata
    old_config_path = ENV["TYCHO_CONFIG_PATH"]

    Dir.mktmpdir("hq-app-boot-metadata-test") do |dir|
      project_path = File.join(dir, "demo")
      FileUtils.mkdir_p(project_path)
      File.write(File.join(project_path, "Gemfile.lock"), <<~LOCK)
        GEM
          specs:
            kamal (2.8.1)
            rails (8.0.2)
      LOCK
      config_path = File.join(dir, "hq.yml")
      File.write(config_path, <<~YAML)
        projects:
          - key: demo
            name: Demo
            path: #{project_path}
            apps: false
      YAML

      ENV["TYCHO_CONFIG_PATH"] = config_path
      app = HQ::App.new
      project = app.instance_variable_get(:@projects).fetch(0)

      assert(project.kamal_version == "2.8.1", "expected Kamal version to load during app boot")
      assert(project.rails_version == "8.0.2", "expected Rails version to load during app boot")
      assert(app.instance_variable_get(:@loading) == false, "expected App.new to render the main UI before async refresh")
    end
  ensure
    ENV["TYCHO_CONFIG_PATH"] = old_config_path
  end

  def assert_missing_config_opens_new_project_form
    old_config_path = ENV["TYCHO_CONFIG_PATH"]
    old_system_prompts_path = ENV["TYCHO_SYSTEM_PROMPTS_PATH"]

    Dir.mktmpdir("hq-empty-onboarding-test") do |dir|
      config_path = File.join(dir, "config", "hq.yml")
      ENV["TYCHO_CONFIG_PATH"] = config_path
      ENV["TYCHO_SYSTEM_PROMPTS_PATH"] = File.join(dir, "config", "system_prompts.yml")

      app = HQ::App.new
      config = YAML.load_file(config_path)

      assert(File.exist?(config_path), "expected missing project config to be created")
      assert(config["projects"] == [], "expected created project config to contain an empty projects list")
      assert(app.instance_variable_get(:@projects).empty?, "expected no projects to load from empty config")
      assert(app.instance_variable_get(:@screen) == :projects, "expected empty config boot to select Projects")
      assert(app.instance_variable_get(:@sidebar)&.fetch(:kind) == :project_editor,
             "expected empty config boot to open the project editor")
      assert(app.instance_variable_get(:@project_editor), "expected project editor instance to be initialized")
    end
  ensure
    ENV["TYCHO_CONFIG_PATH"] = old_config_path
    if old_system_prompts_path
      ENV["TYCHO_SYSTEM_PROMPTS_PATH"] = old_system_prompts_path
    else
      ENV.delete("TYCHO_SYSTEM_PROMPTS_PATH")
    end
  end

  def assert_project_without_proxy_host_is_not_healthchecked
    Dir.mktmpdir("hq-host-health-test") do |dir|
      project_path = File.join(dir, "host-only")
      FileUtils.mkdir_p(File.join(project_path, "config"))
      File.write(File.join(project_path, "config", "deploy.yml"), <<~YAML)
        service: host-only
        image: host-only
        servers:
          web:
            hosts:
              - 10.0.0.42
            proxy: false
      YAML
      project = HQ::AppProject.new(
        HQ::ProjectConfig.new(
          key: "host-only",
          name: "Host Only",
          group: "Tests",
          path: project_path,
          apps: true,
          agent_templates: []
        )
      )
      project.refresh_metadata!

      original_new = Net::HTTP.method(:new)
      fake_http = Class.new do
        attr_accessor :use_ssl, :open_timeout, :read_timeout, :keep_alive_timeout
        attr_reader :host, :port, :paths

        def initialize(host, port)
          @host = host
          @port = port
          @paths = []
        end

        def start
          yield self
        end

        def head(path)
          @paths << path
          Struct.new(:code).new("200")
        end
      end
      created = []
      Net::HTTP.singleton_class.define_method(:new) do |host, port|
        fake_http.new(host, port).tap { |http| created << http }
      end

      project.check_health!

      assert(project.health_status == "not checked", "expected host-only project without proxy.host to be neutral")
      assert(project.app_status == "unknown", "expected host-only project without proxy.host to have unknown app status")
      assert(created.empty?, "expected host-only project without proxy.host not to issue HTTP checks")
    ensure
      Net::HTTP.define_singleton_method(:new) { |*args| original_new.call(*args) } if original_new
    end
  end

  def assert_concurrent_project_metadata_uses_each_dotenv
    Dir.mktmpdir("hq-concurrent-deploy-config-test") do |dir|
      projects = %w[one two].map do |name|
        path = File.join(dir, name)
        FileUtils.mkdir_p(File.join(path, "config"))
        File.write(File.join(path, ".env"), "PROXY_HOST=#{name}.example.test\n")
        File.write(File.join(path, "config", "deploy.yml"), <<~YAML)
          service: #{name}
          image: #{name}
          servers:
            web:
              hosts:
                - 127.0.0.1
          proxy:
            ssl: true
            host: <%= ENV.fetch("PROXY_HOST") %>
        YAML
        HQ::AppProject.new(
          HQ::ProjectConfig.new(
            key: name,
            name: name,
            group: "Tests",
            path: path,
            apps: true,
            agent_templates: []
          )
        )
      end

      20.times do
        projects.map { |project| Thread.new { project.refresh_metadata! } }.each(&:join)
      end

      assert(projects.map(&:proxy_host) == %w[one.example.test two.example.test],
             "expected concurrent deploy config parsing to keep each project's dotenv isolated")
    end
  end

  def assert_main_screen_shows_detail_panel_and_footer
    output = render_main_screen(:agents, width: 120, height: 30)
    lines = output.lines.map(&:chomp)
    last_non_empty = lines.reverse.find { |line| !line.strip.empty? }

    assert(output.include?("Started") || output.include?("No managed agent selected"), "expected detail panel content")
    assert(last_non_empty&.include?("⇥/1-3: switch"), "expected footer hint on final visible line")
    assert(output.include?("⌃B:"), "expected footer to advertise sidebar toggle")
    assert(output.include?("⌃G: term"), "expected footer to advertise terminal shortcut")
    wide_output = render_main_screen(:agents, width: 180, height: 30)
    assert(wide_output.include?("⌃T: agent term"), "expected footer to advertise interactive agent terminal shortcut")
    assert(wide_output.include?("c/C: chat/clone"), "expected footer to advertise agent clone shortcut")
  end

  def assert_empty_project_state_mentions_new_project_shortcut
    app = app_with_default_agent(width: 120, height: 30)
    app.instance_variable_set(:@projects, [])
    app.instance_variable_set(:@agents, [])
    app.instance_variable_set(:@screen, :projects)
    app.send(:apply_window_size, 120, 30)

    plain = Bubbles::ANSI.strip(app.view)

    assert(plain.include?("No projects configured."), "expected empty project list text")
    assert(plain.include?("No project selected"), "expected empty project detail text")
    assert(plain.include?("Press N to create"), "expected empty project state to mention new-project shortcut")
  end

  def assert_empty_agent_state_mentions_new_agent_shortcut
    app = app_with_default_agent(width: 120, height: 30)
    app.instance_variable_set(:@agents, [])
    app.instance_variable_set(:@screen, :agents)
    app.send(:apply_window_size, 120, 30)

    plain = Bubbles::ANSI.strip(app.view)

    assert(plain.include?("No managed agents yet."), "expected empty agent list text")
    assert(plain.include?("No managed agents are available."), "expected empty agent detail text")
    assert(plain.include?("Press 2, select a project, then n"),
           "expected empty agent state to mention new-agent shortcut")
  end

  def assert_terminal_shortcut_is_ctrl_g_and_global
    Dir.mktmpdir("hq-terminal-shortcut-test") do |dir|
      app = app_with_default_agent(width: 120, height: 30)
      app.instance_variable_set(:@screen, :agents)
      agent = app.instance_variable_get(:@agents).fetch(0)
      agent.instance_variable_set(:@workspace, dir)

      opened_dirs = []
      app.define_singleton_method(:spawn_terminal_window) { |target_dir| opened_dirs << target_dir }

      app.send(:handle_key, "g")
      assert(opened_dirs.empty?, "expected plain g not to open a terminal")

      app.update(ctrl_g_message)
      assert(opened_dirs == [dir], "expected ctrl+g to open the selected agent workspace")

      app.send(:open_agent_chat_form)
      app.update(ctrl_g_message)
      assert(opened_dirs == [dir, dir], "expected ctrl+g to work while a sidebar form is open")
    end
  end

  def assert_interactive_agent_terminal_shortcut_is_ctrl_t
    Dir.mktmpdir("hq-agent-terminal-shortcut-test") do |dir|
      app = app_with_default_agent(width: 120, height: 30)
      app.instance_variable_set(:@screen, :agents)
      agent = app.instance_variable_get(:@agents).fetch(0)
      agent.instance_variable_set(:@workspace, dir)
      agent.instance_variable_set(:@agent, "codex")
      agent.instance_variable_set(:@session_id, "019db38a-99ca-7109-9f26-be991d1a4708")
      codex_executable = agent.send(:codex_executable)
      unless executable_available_for_test?(codex_executable)
        puts "rendering_test: skipped ctrl+t Codex harness check (#{codex_executable} unavailable)"
        return
      end

      opened = []
      app.define_singleton_method(:spawn_terminal_window) do |target_dir, command: nil|
        opened << [target_dir, command]
      end

      app.update(ctrl_t_message)

      assert(opened.length == 1, "expected ctrl+t to open one interactive terminal")
      target_dir, command = opened.fetch(0)
      assert(target_dir == dir, "expected ctrl+t to use selected agent workspace")
      assert(command.include?(codex_executable), "expected ctrl+t command to launch Codex")
      assert(command.include?("resume 019db38a-99ca-7109-9f26-be991d1a4708"),
             "expected ctrl+t command to resume the selected Codex session")
    end
  end

  def assert_overlay_replaces_detail_when_open
    app = build_chat_app(width: 120, height: 30)
    plain = Bubbles::ANSI.strip(app.view)

    assert(plain.include?("warehouse custom"), "expected chat overlay content to render")
    assert(plain.include?("Send a message..."), "expected chat composer in right panel")
  end

  def assert_rendered_lines_fit_screen_width
    width = 120
    output = render_main_screen(:agents, width:, height: 30)

    output.lines.map(&:chomp).each_with_index do |line, index|
      visible = visible_width(line.rstrip)
      assert(visible <= width,
             "expected line #{index + 1} to fit within #{width} columns, got #{visible}: #{line.inspect}")
    end
  end

  def assert_list_sidebar_renders_agent_names
    output = render_main_screen(:agents, width: 120, height: 30)
    plain = Bubbles::ANSI.strip(output)

    assert(plain.include?("Agents"), "expected list sidebar title for agents tab")
    assert(plain.include?("warehouse custom"), "expected agent name in list sidebar")
    assert(!plain.include?("/Users/.../warehouse/"), "expected list sidebar to omit compact workspace path")
  end

  def assert_list_sidebar_renders_project_status_icons
    output = render_main_screen(:projects, width: 120, height: 30)
    plain = Bubbles::ANSI.strip(output)

    assert(plain.include?("Projects"), "expected list sidebar title for projects tab")
    assert(plain.include?("warehouse"), "expected project name in list sidebar")
    assert(plain.include?("Status:"), "expected project list sidebar to include status legend")
    project_line = plain.lines.find { |line| line.include?("warehouse") }.to_s
    assert(project_line.include?("") || project_line.include?("") || project_line.include?(""),
           "expected project row to include a status icon")
  end

  def assert_list_sidebar_scrolls_to_selected_agent
    app = app_with_default_agent(width: 120, height: 18)
    project = app.instance_variable_get(:@projects).first
    agents = 24.times.map do |index|
      HQ::ManagedAgent.new(
        key: "scroll-agent-#{index}",
        name: "Scroll Agent #{index}",
        project_key: project.key,
        template_key: "custom",
        workspace: project.path,
        prompt: "Test",
        finished_at: Time.parse("2026-04-05 17:56:00"),
        last_exit_code: 0
      )
    end
    app.instance_variable_set(:@agents, agents)
    app.instance_variable_get(:@selected)[:agents] = 22

    plain = Bubbles::ANSI.strip(app.view)

    selected_line = plain.lines.find { |line| line.include?("Scroll Agent 22") && line.include?(CURSOR_MARKER) }.to_s
    assert(!selected_line.empty?,
           "expected overflowing list sidebar to render the selected agent")
    assert(!plain.include?("Scroll Agent 0"),
           "expected overflowing list sidebar to scroll early agents out of view")
  end

  def assert_failed_project_action_with_healthy_app_renders_warning_status
    project = HQ::AppProject.new(
      HQ::ProjectConfig.new(
        key: "healthy-failed-action",
        name: "Healthy Failed Action",
        group: "Tests",
        path: "/tmp",
        apps: true,
        agent_templates: []
      )
    )
    project.instance_variable_set(:@health_status, "healthy")
    project.instance_variable_set(:@app_status, "running")
    result = { success: false, action: :deploy, at: Time.now, log_path: "/tmp/action.log" }

    badge = HQ::UI::Rendering::ProjectStatusBadge.for(project, action: nil, result: result, steady: :health)

    assert(badge.style_key == :warning, "expected failed action with healthy app to render as warning")
    assert(badge.text == "! deploy", "expected failed action with healthy app to use warning result text")
    assert(HQ::UI::Rendering::ProjectStatusBadge.result_active?(result.merge(at: Time.now - 299)),
           "expected failed action result to remain active for the longer failure window")
    assert(!HQ::UI::Rendering::ProjectStatusBadge.result_active?(result.merge(at: Time.now - 301)),
           "expected failed action result to expire after the failure window")
  end

  def assert_agent_unread_cursor_and_chat_clear
    app = app_with_default_agent(width: 120, height: 30)
    first_agent = app.instance_variable_get(:@agents).first
    project = app.instance_variable_get(:@projects).find { |item| item.key == first_agent.project_key }
    unread_agent = HQ::ManagedAgent.new(
      key: "warehouse-agent-unread",
      name: "warehouse unread",
      project_key: first_agent.project_key,
      template_key: "custom",
      workspace: project.path,
      prompt: "Test",
      finished_at: Time.parse("2026-04-05 17:56:00"),
      last_exit_code: 0,
      unread: true
    )
    app.instance_variable_set(:@agents, [first_agent, unread_agent])
    app.instance_variable_get(:@selected)[:agents] = 0
    plain = Bubbles::ANSI.strip(app.view)
    unread_line = plain.lines.find { |line| line.include?("warehouse unread") }.to_s

    assert(unread_line.include?("  #{UNREAD_MARKER} "), "expected unread non-selected agent to use unread marker")

    app.instance_variable_get(:@selected)[:agents] = 1
    plain = Bubbles::ANSI.strip(app.view)
    selected_unread_line = plain.lines.find { |line| line.include?("#{CURSOR_MARKER}#{UNREAD_MARKER}") && line.include?("warehouse unread") }.to_s
    assert(selected_unread_line.include?(" #{CURSOR_MARKER}#{UNREAD_MARKER} "), "expected selected unread agent to keep cursor and unread marker")

    app.send(:open_agent_chat_form)

    assert(!unread_agent.unread?, "expected opening chat to clear unread state")
  end

  def assert_finished_agent_poll_marks_unread
    app = app_with_default_agent(width: 120, height: 30)
    agent = app.instance_variable_get(:@agents).first
    agent.define_singleton_method(:status) { @fake_status || "running" }
    agent.define_singleton_method(:poll!) { @fake_status = "succeeded" }
    agent.define_singleton_method(:build_summary!) { nil }

    app.send(:poll_agents!)

    assert(agent.unread?, "expected unseen agent to become unread when a run finishes")
  end

  def assert_exited_agent_poll_marks_unread_after_status_turns_idle
    app = app_with_default_agent(width: 120, height: 30)
    agent = app.instance_variable_get(:@agents).first
    agent.instance_variable_set(:@pid, 999_999)
    agent.instance_variable_set(:@last_exit_code, nil)
    agent.instance_variable_set(:@started_at, Time.now)
    agent.instance_variable_set(
      :@runs,
      [
        HQ::ManagedAgent::AgentRun.new(
          started_at: Time.now,
          status: "running",
          log_path: agent.log_path
        )
      ]
    )

    assert(agent.status == "idle", "expected dead pid to render as idle before poll finalizes the run")

    app.send(:poll_agents!)

    assert(agent.unread?, "expected exited agent to become unread even when status was already non-running")
  end

  def assert_omnisearch_empty_query_lists_unread_agents
    app = app_with_default_agent(width: 120, height: 30)
    project = app.instance_variable_get(:@projects).first
    read_agent = HQ::ManagedAgent.new(
      key: "read-agent",
      name: "read agent",
      project_key: project.key,
      template_key: "custom",
      workspace: project.path,
      prompt: "Read",
      unread: false
    )
    unread_agent = HQ::ManagedAgent.new(
      key: "unread-agent",
      name: "unread agent",
      project_key: project.key,
      template_key: "custom",
      workspace: project.path,
      prompt: "Unread",
      unread: true
    )
    app.instance_variable_set(:@agents, [read_agent, unread_agent])
    app.instance_variable_get(:@selected)[:agents] = 0

    open_omnisearch(app)

    omnisearch = app.instance_variable_get(:@omnisearch)
    labels = omnisearch.results.map(&:label)
    plain = Bubbles::ANSI.strip(app.view)

    assert(labels == ["unread agent"], "expected empty Omnisearch to list only unread agents, got #{labels.inspect}")
    assert(plain.include?("Omnisearch"), "expected Omnisearch overlay to render")
    assert(plain.include?("unread agent"), "expected unread agent in Omnisearch overlay")
  end

  def assert_omnisearch_reindexes_when_unread_agent_appears
    app = app_with_default_agent(width: 120, height: 30)
    project = app.instance_variable_get(:@projects).first
    agent = HQ::ManagedAgent.new(
      key: "late-unread-agent",
      name: "Late Unread Agent",
      project_key: project.key,
      template_key: "custom",
      workspace: project.path,
      prompt: "Late",
      unread: false
    )
    app.instance_variable_set(:@agents, [agent])
    app.instance_variable_get(:@selected)[:agents] = 0

    open_omnisearch(app)
    assert(app.instance_variable_get(:@omnisearch).results.empty?,
           "expected no default unread results before the agent becomes unread")

    agent.mark_unread!
    app.update(HQ::ActionPollMessage.new)

    labels = app.instance_variable_get(:@omnisearch).results.map(&:label)

    assert(labels == ["Late Unread Agent"],
           "expected open Omnisearch to reindex when an unread agent appears, got #{labels.inspect}")
  end

  def assert_omnisearch_fuzzy_selects_project
    app = app_with_default_agent(width: 120, height: 30)
    app.instance_variable_set(:@screen, :agents)
    open_omnisearch(app)
    app.update(key_message("d"))
    app.update(key_message("w"))
    app.update(enter_message)

    selected_project = app.send(:selected_project)

    assert(app.instance_variable_get(:@screen) == :projects, "expected Omnisearch project result to switch to Projects")
    assert(selected_project&.key == "demo-web",
           "expected fuzzy query 'dw' to select Demo Web, got #{selected_project&.key.inspect}")
    assert(app.instance_variable_get(:@omnisearch).nil?, "expected Omnisearch to close after selecting a result")
  end

  def assert_omnisearch_matches_multi_rune_agent_query
    app = app_with_default_agent(width: 120, height: 30)
    project = app.instance_variable_get(:@projects).first
    address_agent = HQ::ManagedAgent.new(
      key: "address-reviews-agent",
      name: "Address Reviews",
      project_key: project.key,
      template_key: "custom",
      workspace: project.path,
      prompt: "Address reviews"
    )
    app.instance_variable_set(:@agents, [address_agent])
    app.instance_variable_get(:@selected)[:agents] = 0

    open_omnisearch(app)
    app.update(paste_key_message("add"))

    labels = app.instance_variable_get(:@omnisearch).results.map(&:label)
    plain = Bubbles::ANSI.strip(app.view)

    assert(labels.include?("Address Reviews"),
           "expected multi-rune query 'add' to match Address Reviews, got #{labels.inspect}")
    assert(plain.include?("Address Reviews"), "expected rendered Omnisearch results to include Address Reviews")
    assert(plain.include?("Address Reviews • #{project.name}"),
           "expected rendered agent result to include its project name")
    assert(!plain.include?("No matches"), "expected rendered Omnisearch results not to show No matches")
  end

  def assert_omnisearch_matches_agent_project_name
    app = app_with_default_agent(width: 120, height: 30)
    project = app.instance_variable_get(:@projects).find { |item| item.key == "demo-web" }
    agent = HQ::ManagedAgent.new(
      key: "demo-web-address-reviews",
      name: "Address Reviews",
      project_key: project.key,
      template_key: "custom",
      workspace: project.path,
      prompt: "Address reviews"
    )
    app.instance_variable_set(:@agents, [agent])
    app.instance_variable_get(:@selected)[:agents] = 0

    open_omnisearch(app)
    app.update(paste_key_message("demo"))

    labels = app.instance_variable_get(:@omnisearch).results.map(&:label)
    plain = Bubbles::ANSI.strip(app.view)

    assert(labels.include?("Address Reviews"),
           "expected project-name query to include matching agent, got #{labels.inspect}")
    assert(plain.include?("Address Reviews • Demo Web"),
           "expected rendered agent result to include project name for project-name search")
  end

  def assert_omnisearch_query_changes_select_first_result
    app = app_with_default_agent(width: 120, height: 30)
    project = app.instance_variable_get(:@projects).first
    agents = [
      HQ::ManagedAgent.new(
        key: "alpha-address",
        name: "Address Reviews Alpha",
        project_key: project.key,
        template_key: "custom",
        workspace: project.path,
        prompt: "Alpha",
        unread: true
      ),
      HQ::ManagedAgent.new(
        key: "beta-address",
        name: "Address Reviews Beta",
        project_key: project.key,
        template_key: "custom",
        workspace: project.path,
        prompt: "Beta",
        unread: true
      )
    ]
    app.instance_variable_set(:@agents, agents)
    app.instance_variable_get(:@selected)[:agents] = 0

    open_omnisearch(app)
    app.update(Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_DOWN))
    app.update(paste_key_message("add"))

    omnisearch = app.instance_variable_get(:@omnisearch)

    assert(omnisearch.selected_index == 0,
           "expected query changes to highlight first result, got #{omnisearch.selected_index}")
    assert(omnisearch.selected_item&.label == "Address Reviews Alpha",
           "expected first sorted result to be selected, got #{omnisearch.selected_item&.label.inspect}")
  end

  def assert_omnisearch_treats_alphabetical_hotkeys_as_query_text
    app = app_with_default_agent(width: 120, height: 30)
    open_omnisearch(app)

    app.update(key_message("q"))
    omnisearch = app.instance_variable_get(:@omnisearch)
    assert(!omnisearch.nil?, "expected q to stay inside Omnisearch instead of closing it")
    assert(omnisearch.query == "q", "expected q to append to the Omnisearch query, got #{omnisearch.query.inspect}")

    app.update(key_message("j"))
    app.update(key_message("k"))
    assert(omnisearch.query == "qjk", "expected j/k to append to the Omnisearch query, got #{omnisearch.query.inspect}")
  end

  def assert_omnisearch_only_opens_from_visible_sidebar
    app = app_with_default_agent(width: 120, height: 30)
    app.send(:toggle_sidebar)
    app.update(Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_SPACE))
    app.update(HQ::OmnisearchIndexMessage.new)

    assert(app.instance_variable_get(:@omnisearch).nil?, "expected Omnisearch not to open when sidebar is hidden")
  end

  def assert_list_sidebar_hides_when_toggled_off
    app = app_with_default_agent(width: 120, height: 30)
    app.instance_variable_set(:@screen, :agents)
    app.send(:toggle_sidebar)
    output = app.view
    plain = Bubbles::ANSI.strip(output)

    assert(!plain.include?("Agents\n"), "expected list sidebar title to disappear when hidden")
    assert(plain.include?("Started"), "expected detail panel to still render when sidebar hidden")
    assert(plain.include?("⌃B: show sidebar"), "expected footer to invite showing the sidebar")
  end

  def assert_projects_list_renders_group_rows
    output = render_main_screen(:projects, width: 120, height: 30)
    plain = Bubbles::ANSI.strip(output)

    assert(plain.include?(" Personal "), "expected project group row in list sidebar")
    assert(plain.include?("warehouse"), "expected project name below group row")
  end

  def assert_detail_overlay_opens_full_screen
    app = app_with_default_agent(width: 120, height: 30)
    app.instance_variable_set(:@screen, :agents)
    app.send(:open_detail_view)
    output = app.view
    plain = Bubbles::ANSI.strip(output)

    assert(plain.include?("Agent Detail"), "expected detail overlay title")
    assert(plain.include?("Started"), "expected detail overlay body")
    assert(plain.include?("esc/q/v: close"), "expected detail overlay hint")
  end

  def assert_agent_detail_omits_conversation_and_recent_runs
    app = build_chat_app
    detail = app.send(:current_detail_text)

    assert(!detail.include?("Conversation:"), "expected agent detail to defer transcript details to the log view")
    assert(!detail.include?("Recent Runs:"), "expected agent detail to defer run history to the log view")
    assert(detail.include?("Raw Log"), "expected agent detail to keep the log path visible")
  end

  def assert_agent_detail_renders_project_git_metadata
    app = build_chat_app
    agent = app.send(:selected_agent)
    project = app.send(:project_for_key, agent.project_key)
    project.instance_variable_set(:@branch, "feature/hq-agent-detail")
    project.instance_variable_set(:@commit_hash, "abc1234")
    project.instance_variable_set(:@dirty_files, 2)

    detail = app.send(:current_detail_text)
    plain = Bubbles::ANSI.strip(detail)

    assert(plain.include?(project.name), "expected agent detail to show linked project")
    assert(plain.include?("feature/hq-agent-detail"), "expected agent detail to show project branch")
    assert(plain.include?("abc1234"), "expected agent detail to show project commit")
    assert(plain.include?("2 dirty"), "expected agent detail to show project dirty state")
  end

  def assert_project_detail_renders_log_locations
    app = app_with_default_agent(width: 120, height: 30)
    app.instance_variable_set(:@screen, :projects)
    plain = Bubbles::ANSI.strip(app.send(:project_detail_text))

    assert(plain.include?("Log Dir"), "expected project detail to label project log directory")
    assert(plain.include?("Action Log"), "expected project detail to label action log path")
  end

  def assert_project_detail_renders_last_action_status
    app = app_with_default_agent(width: 120, height: 30)
    app.instance_variable_set(:@screen, :projects)
    project = app.send(:selected_project)
    app.instance_variable_get(:@action_results)[project.key] = {
      success: false,
      action: :deploy,
      action_label: "deploying",
      at: Time.now,
      log_path: project.action_log_path
    }

    detail = app.send(:project_detail_text)

    plain = Bubbles::ANSI.strip(detail)
    assert(plain.include?("Last Action"), "expected project detail to label last action")
    assert(plain.include?("deploying - failed"),
           "expected project detail to show last action result")
  end

  def assert_detail_sidebar_renders_in_split_layout
    app = app_with_default_agent(width: 120, height: 30)
    app.instance_variable_set(:@screen, :agents)
    app.send(:open_detail_view)
    output = app.view

    assert(output.include?("Agent Detail"), "expected detail sidebar title")
    assert(output.include?("Agent:"), "expected detail sidebar body")
    assert(output.include?("esc: close"), "expected detail sidebar hint")
  end

  def assert_log_overlay_renders_in_right_panel
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "app.log")
      File.write(log_path, "line one\nline two\n")

      app = HQ::App.new
      app.send(:apply_window_size, 120, 30)
      app.send(:open_sidebar_text, kind: :project_log, title: "App Log") { File.read(log_path) }
      output = app.view
      viewport = app.instance_variable_get(:@sidebar_viewport)

      assert(output.include?("App Log"), "expected log overlay title")
      assert(viewport.is_a?(HQ::UI::LogViewer), "expected project logs to use the log viewer")
      assert(output.include?("line one"), "expected log overlay content")
      assert(output.include?("line 1/"), "expected log overlay status line")

      %i[chat_log healthcheck_log].each do |kind|
        app.send(:open_sidebar_text, kind:, title: kind.to_s) { "one\ntwo\n" }
        assert(app.instance_variable_get(:@sidebar_viewport).is_a?(HQ::UI::LogViewer),
               "expected #{kind} to use the log viewer")
      end
    end
  end

  def assert_project_log_shortcut_opens_action_log
    app = app_with_default_agent(width: 120, height: 30)
    app.instance_variable_set(:@screen, :projects)
    project = app.send(:selected_project)
    FileUtils.mkdir_p(project.log_dir)
    File.write(project.action_log_path, "deploy output\n")

    app.send(:handle_key, "l")
    output = Bubbles::ANSI.strip(app.view)

    assert(output.include?("Action Log"), "expected l on Projects to open the selected project's action log")
    assert(app.instance_variable_get(:@sidebar_viewport).is_a?(HQ::UI::LogViewer),
           "expected action logs to use the log viewer")
    assert(output.include?("deploy output"), "expected project action.log content")
    assert(!output.include?("Agent Chat Log"), "expected Projects log shortcut not to open an agent chat log")
  end

  def assert_agent_raw_log_shortcut_displays_full_file
    app = app_with_default_agent(width: 120, height: 30)
    app.instance_variable_set(:@screen, :agents)
    agent = app.send(:selected_agent)
    long_line = "x" * 650
    FileUtils.mkdir_p(File.dirname(agent.raw_log_path))
    File.write(agent.raw_log_path, ["first raw line", long_line, "last raw line"].join("\n"))

    app.send(:handle_key, "L")
    output = Bubbles::ANSI.strip(app.view)
    viewport = app.instance_variable_get(:@sidebar_viewport)
    rendered = viewport.view
    content = app.instance_variable_get(:@sidebar_viewport).content

    assert(output.include?("Agent Raw Log"), "expected L on Agents to open the selected agent raw log")
    assert(viewport.is_a?(HQ::UI::LogViewer), "expected raw logs to use the log viewer")
    assert(content.include?("first raw line"), "expected raw log to include the beginning of the file")
    assert(content.include?(long_line), "expected raw log to preserve long lines without shortening")
    assert(content.include?("last raw line"), "expected raw log to include the end of the file")
    assert(!content.include?("truncated"), "expected raw log to render without truncation banners")
    assert(!rendered.include?(long_line), "expected raw log viewport to clip long visible lines")

    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RIGHT))
    assert(viewport.x_offset.positive?, "expected raw log viewport to support horizontal panning")
  end

  def assert_chat_screen_renders_transcript_and_composer
    output = render_chat_screen(width: 120, height: 30)
    plain_output = Bubbles::ANSI.strip(output)
    assert(plain_output.include?("warehouse custom"), "expected agent name in chat sidebar")
    assert(plain_output.include?("warehouse"), "expected project name in chat sidebar")
    assert(plain_output.include?("That one came through too."), "expected assistant summary in transcript")
    assert(plain_output.include?("success"), "expected current state summary line")
    assert(plain_output.include?("Send a message..."), "expected chat composer placeholder")
    assert(plain_output.include?("⇥: focus sections"), "expected chat focus hint")
    assert(plain_output.include?("\u{f0636}Enter/⌃J newline"), "expected chat prompt hint")
  end

  def assert_chat_section_labels_use_tag_backgrounds
    app = build_chat_app(width: 120, height: 30)
    border_color = app.send(:chat_screen_border_color)

    label_style = app.send(:chat_section_label_style)
    focused_label_style = app.send(:chat_section_label_focused_style)

    assert(label_style.get_background == border_color,
           "expected chat section labels to use the chat border color as their background")
    assert(label_style.get_foreground == app.send(:best_contrast_text_color, border_color),
           "expected chat section labels to choose the highest-contrast foreground")
    assert(focused_label_style.get_background == HQ::UI::Rendering::Styles::COLORS[:accent],
           "expected focused chat section labels to use the accent background")
    assert(focused_label_style.get_foreground == HQ::UI::Rendering::Styles::COLORS[:text_inverse],
           "expected focused chat section labels to use dark text on the bright accent background")
    assert(app.send(:best_contrast_text_color, "#DDCD5F") == HQ::UI::Rendering::Styles::COLORS[:text_inverse],
           "expected bright yellow chat labels to use dark text")
    assert(app.send(:best_contrast_text_color, "#645FDD") == HQ::UI::Rendering::Styles::COLORS[:text],
           "expected dark purple chat labels to use light text")

    divider = Bubbles::ANSI.strip(app.send(:chat_section_divider, label: "Conversation"))
    focused_divider = Bubbles::ANSI.strip(app.send(:chat_section_divider, label: "Compose", focused: true))
    assert(divider.include?(" Conversation "), "expected chat section labels to render as padded tags")
    assert(focused_divider.include?(" #{CURSOR_MARKER} Compose "), "expected focused chat section labels to render with the cursor marker")
  end

  def assert_chat_attachments_render_compact_and_overlay
    app = build_chat_app(width: 120, height: 30)
    agent = app.instance_variable_get(:@agents).first
    memory = HQ::AgentMemory.new(agent)
    memory.append_attachment!(
      {
        "kind" => "link",
        "title" => "PR #1234: bugfixing some log",
        "url" => "https://github.com/example/app/pull/1234",
        "description" => "Generated implementation PR."
      },
      created_at: Time.parse("2026-04-05 17:57:00")
    )
    document_path = File.join(agent.workspace, "docs/attachments-plan.md")
    FileUtils.mkdir_p(File.dirname(document_path))
    File.write(document_path, "# Attachment plan\n")
    memory.append_attachment!(
      {
        "kind" => "document",
        "title" => "Plan for attachment feature",
        "url" => document_path
      },
      created_at: Time.parse("2026-04-05 17:58:00")
    )
    image_path = File.join(agent.workspace, "tmp/plan.png")
    FileUtils.mkdir_p(File.dirname(image_path))
    File.binwrite(image_path, "png")
    memory.append_attachment!(
      {
        "kind" => "image",
        "title" => "Infographic for a plan",
        "url" => image_path
      },
      created_at: Time.parse("2026-04-05 17:59:00")
    )

    app.send(:sync_agent_chat_workspace!)
    plain = Bubbles::ANSI.strip(app.view)
    assert(plain.include?("\u{F0219} 2 \uF0C1 1"), "expected chat conversation header to show compact attachment counts")
    assert(plain.include?("⌃A: attachments"), "expected chat hint to expose the attachments hotkey")

    app.send(:handle_sidebar, ctrl_a_message)
    form = app.instance_variable_get(:@agent_chat_form)
    expanded = Bubbles::ANSI.strip(app.view)
    assert(form.attachments_detail_open?, "expected ctrl+a to open the attachments overlay")
    assert(expanded.include?("Attachments"), "expected attachments overlay title")
    assert(expanded.include?("PR #1234: bugfixing some log"), "expected link attachment title")
    assert(!expanded.include?("Generated implementation PR."), "expected attachment descriptions to stay hidden")
    assert(!expanded.include?("https://github.com/example/app/pull/1234"), "expected attachment targets to stay hidden")
    assert(expanded.include?("Plan for attachment feature"), "expected document attachment title")
    assert(expanded.include?("Infographic for a plan"), "expected image attachment title")
    assert(form.selected_attachment_index.zero?, "expected first attachment to be selected")

    opened = []
    app.define_singleton_method(:spawn_detached) { |*command| opened << command }
    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_DOWN))
    assert(form.selected_attachment_index == 1, "expected down to select the next attachment")
    app.send(:handle_sidebar, enter_message)
    assert(opened == [["open", document_path]], "expected enter to open the selected attachment target")

    app.send(:handle_sidebar, ctrl_a_message)
    assert(!form.attachments_detail_open?, "expected ctrl+a to close the attachments overlay")
  end

  def assert_chat_user_message_detail_includes_attachments
    app = build_chat_app(width: 120, height: 30)
    agent = app.instance_variable_get(:@agents).first
    attachment_path = File.join(agent.workspace, "docs/uploaded-notes.md")
    FileUtils.mkdir_p(File.dirname(attachment_path))
    File.write(attachment_path, "# Uploaded notes\n")
    HQ::AgentMemory.new(agent).append_user_message!(
      "Review the uploaded context.",
      created_at: Time.parse("2026-04-05 17:59:00"),
      attachments: [
        {
          "kind" => "document",
          "title" => "uploaded-notes.md",
          "url" => attachment_path,
          "size_bytes" => 123
        }
      ]
    )

    app.send(:sync_agent_chat_workspace!)
    form = app.instance_variable_get(:@agent_chat_form)
    user_index = form.conversation_blocks.index do |block|
      block[:detail_title] == "User Message" && block[:preview].to_s.include?("Review the uploaded context.")
    end
    raise "expected a user message block with uploaded context" unless user_index

    while form.selected_block_index != user_index
      app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RIGHT))
    end
    form.open_selected_block
    detail = Bubbles::ANSI.strip(form.block_viewport.content)

    assert(detail.include?("Review the uploaded context."), "expected user detail to include uploaded message text")
    assert(detail.include?("Attachments"), "expected user detail to label message attachments")
    assert(detail.include?("uploaded-notes.md"), "expected user detail to include uploaded attachment title")
  end

  def assert_running_chat_hides_live_output_and_keeps_pending_prompt
    app = build_running_chat_app(width: 120, height: 30)
    form = app.instance_variable_get(:@agent_chat_form)
    output = app.view

    assert(form.conversation_blocks.any? { |block| block[:preview].to_s.include?("Please verify this while it runs.") },
           "expected pending submitted prompt in transcript blocks")
    assert(output.include?("Tool Call Group"), "expected running chat to show collapsed tool group")
    assert(output.include?("1 tool call, 1 result: Bash"), "expected running chat to summarize grouped tools")
    assert(!output.include?("LIVE OUTPUT"), "expected running chat to hide live output block")
  end

  def assert_chat_expands_tool_messages
    lines = live_tool_run_lines
    conversation, system = HQ::Parser.parse_stream(lines, agent_type: "claude")
    blocks = HQ::Parser.compose_chat_blocks(conversation, system)
    app = build_running_chat_app(width: 120, height: 50)
    form = app.instance_variable_get(:@agent_chat_form)

    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_TAB))
    tool_index = form.conversation_blocks.index { |block| block[:kind] == :tool_group }
    raise "expected a selectable tool group block" unless tool_index

    while form.selected_block_index != tool_index
      app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RIGHT))
    end
    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_ENTER))
    output = Bubbles::ANSI.strip(app.view)

    assert(blocks.any? { |b| b.kind == :tool_call && b.tool_name == "Bash" && b.content.include?("Check login page") },
           "expected parser blocks to include expanded tool call")
    assert(blocks.any? { |b| b.kind == :tool_result && b.content == "200" },
           "expected parser blocks to include expanded tool result")
    assert(form.block_detail_open?, "expected enter on the selected tool group to open block detail")
    assert(!output.include?("Bash"), "expected opened tool detail to omit tool labels")
    assert(output.include?('curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/login'),
           "expected full tool command in chat transcript")
    assert(!output.include?("last: Bash"), "expected chat transcript to avoid collapsed tool summary")
  end

  def assert_chat_collapses_tool_messages
    app = build_running_chat_app(width: 120, height: 30)
    form = app.instance_variable_get(:@agent_chat_form)
    output = Bubbles::ANSI.strip(app.view)

    assert(!form.block_detail_open?, "expected grouped tool calls to start as a closed block")
    assert(!output.include?("[SYSTEM]"), "expected conversation block list to hide system prompt blocks")
    assert(!output.include?("[Summary]"), "expected conversation block list to hide run summary blocks")
    assert(output.include?("Tool Call Group"), "expected collapsed tool group label to remain visible")
    assert(output.include?("1 tool call, 1 result: Bash"),
           "expected collapsed tool group to show a compact summary")
    assert(!output.include?('curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/login'),
           "expected collapsed chat transcript to hide full tool command")
    conversation_header = output.lines.find { |line| line.include?("Conversation") }.to_s
    assert(conversation_header.include?("≡") && conversation_header.include?("◧"),
           "expected conversation header to show compact block diagnostics")
    assert(!conversation_header.include?("▦"), "expected block position icon to use the line-count glyph")

    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_TAB))
    assert(form.content_focused?, "expected tab to focus the transcript viewport")
    focused_output = Bubbles::ANSI.strip(app.view)
    focused_header = focused_output.lines.find { |line| line.include?("Conversation") }.to_s
    assert(focused_header.include?("#{CURSOR_MARKER} Conversation"),
           "expected focused conversation section to use the shared cursor marker")
    focused_footer = focused_output.lines.last.to_s
    assert(!focused_footer.include?("Block") && !focused_footer.include?("visible"),
           "expected block diagnostics to stay out of the focused chat footer hint")
    tool_index = form.conversation_blocks.index { |block| block[:kind] == :tool_group }
    raise "expected a selectable tool group block" unless tool_index
    selected_tool_label = Bubbles::ANSI.strip(app.send(:styled_chat_block_label, form.conversation_blocks[tool_index], selected: true))
    assert(selected_tool_label.include?("#{CURSOR_MARKER} Tool Call Group"), "expected selected chat block to use the shared cursor marker")
    assert(!selected_tool_label.include?("› Tool Call Group"), "expected selected chat block to avoid the old arrow marker")

    assert(form.selected_block_index == tool_index, "expected chat to anchor on the latest block")
    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_LEFT))
    assert(form.selected_block_index == tool_index - 1, "expected left to navigate to the previous block")
    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RIGHT))
    assert(form.selected_block_index == tool_index, "expected right to navigate to the next block")
    app.send(:handle_sidebar, key_message(","))
    assert(form.selected_block_index == tool_index - 1, "expected comma to navigate to the previous block")
    app.send(:handle_sidebar, key_message("."))
    assert(form.selected_block_index == tool_index, "expected period to navigate to the next block")
    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_UP))
    assert(form.selected_block_index == tool_index - 1, "expected up to navigate to the previous block")
    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_DOWN))
    assert(form.selected_block_index == tool_index, "expected down to navigate to the next block")
    app.send(:handle_sidebar, key_message("k"))
    assert(form.selected_block_index == tool_index - 1, "expected k to navigate to the previous block")
    app.send(:handle_sidebar, key_message("j"))
    assert(form.selected_block_index == tool_index, "expected j to navigate to the next block")

    assert(form.selected_block_index == tool_index, "expected right to navigate to the tool group block")
    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_ENTER))
    expanded = Bubbles::ANSI.strip(app.view)
    assert(form.block_detail_open?, "expected enter to open selected block detail")
    assert(expanded.include?('curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/login'),
           "expected expanded chat transcript to restore full tool command")
    assert(expanded.include?("Summary"), "expected block detail layer to preserve the summary section")
    assert(expanded.include?("Compose"), "expected block detail layer to preserve the compose section")
    detail_header = expanded.lines.find { |line| line.include?("Tool Calls") }.to_s
    assert(detail_header.include?("≡") && detail_header.include?("◧"),
           "expected opened block detail header to show compact diagnostics")
    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_LEFT))
    previous_detail = Bubbles::ANSI.strip(app.view)
    assert(form.block_detail_open?, "expected left in block detail to keep detail open")
    assert(form.selected_block_index == tool_index - 1, "expected left in block detail to select the previous block")
    assert(!previous_detail.include?('curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/login'),
           "expected block detail content to refresh after selecting previous block")
    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RIGHT))
    next_detail = Bubbles::ANSI.strip(app.view)
    assert(form.selected_block_index == tool_index, "expected right in block detail to select the next block")
    assert(next_detail.include?('curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/login'),
           "expected block detail content to refresh after selecting next block")

    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_ENTER))
    assert(!form.block_detail_open?, "expected enter to close an open block detail")
  end

  def assert_chat_load_selects_latest_block
    app = build_running_chat_app(width: 120, height: 50)
    form = app.instance_variable_get(:@agent_chat_form)

    assert(form.selected_block_index == form.conversation_blocks.length - 1,
           "expected chat load to select the latest conversation block")
  end

  def assert_chat_load_bottom_aligns_latest_block
    agent = HQ::ManagedAgent.new(
      key: "scroll-agent",
      name: "Scroll Agent",
      project_key: "hq",
      template_key: "custom",
      workspace: "/tmp",
      prompt: "Test"
    )
    form = HQ::UI::AgentChatForm.new(agent, width: 80, body_height: 25)
    height = form.viewport.height
    blocks = [
      { label: "A", line_offset: 0, line_height: 5 },
      { label: "B", line_offset: 6, line_height: height - 5 },
      { label: "C", line_offset: height + 2, line_height: 4 }
    ]
    content = Array.new(height + 8, "line").join("\n")

    form.sync_blocks(blocks, content)
    assert(form.selected_block_index == 2, "expected first chat sync to select the newest block")
    assert(form.viewport.y_offset == 6, "expected newest block to be bottom-aligned in the viewport")

    form.select_previous_block
    assert(form.selected_block_index == 1, "expected previous block selection")
    assert(form.viewport.y_offset == 6, "expected fully visible previous block to keep the viewport anchored")

    form.select_previous_block
    assert(form.selected_block_index == 0, "expected previous block selection")
    assert(form.viewport.y_offset.zero?, "expected partially cropped previous block to align to the top")
  end

  def assert_summary_enter_opens_scrollable_layer
    app = build_chat_app(width: 120, height: 30)
    agent = app.instance_variable_get(:@agents).first
    agent.summary = [
      "Summary first line.",
      "Summary second line that should only appear in the opened summary layer."
    ].join("\n")

    output = Bubbles::ANSI.strip(app.view)
    assert(output.include?("Summary first line."), "expected collapsed summary to show the first line")
    assert(!output.include?("Summary second line"), "expected collapsed summary to stay one line")

    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_TAB))
    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_TAB))
    form = app.instance_variable_get(:@agent_chat_form)
    assert(form.summary_focused?, "expected second tab to focus the summary section")

    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_ENTER))
    expanded = Bubbles::ANSI.strip(app.view)
    assert(form.summary_detail_open?, "expected enter on summary focus to open summary detail")
    assert(!expanded.include?("enter/esc closes this layer"), "expected summary detail to omit redundant layer help")
    assert(expanded.include?("Summary second line"), "expected summary detail to show full summary text")
  end

  def assert_chat_groups_consecutive_message_headers
    Dir.mktmpdir do |dir|
      agent = HQ::ManagedAgent.new(
        key: "grouped-chat-agent",
        name: "grouped custom",
        project_key: "warehouse",
        template_key: "custom",
        workspace: dir,
        prompt: "Test",
        agent: "claude",
        log_path: File.join(dir, "grouped.raw.log"),
        created_at: Time.parse("2026-05-01 10:00:00")
      )

      memory = HQ::AgentMemory.new(agent)
      memory.append_assistant_message!("First assistant chunk.", created_at: Time.parse("2026-05-01 10:01:00"))
      memory.append_assistant_message!("Second assistant chunk.", created_at: Time.parse("2026-05-01 10:01:05"))
      memory.append_user_message!("First user prompt.", created_at: Time.parse("2026-05-01 10:02:00"))
      memory.append_user_message!("Second user prompt.", created_at: Time.parse("2026-05-01 10:02:05"))
      memory.append_tool_summary!("List files", tool_name: "exec", created_at: Time.parse("2026-05-01 10:03:00"))
      memory.append_tool_summary!("Read status", tool_name: "file_change", created_at: Time.parse("2026-05-01 10:03:05"))
      memory.append_tool_summary!("Generic tool", tool_name: "tool", created_at: Time.parse("2026-05-01 10:03:10"))

      app = HQ::App.new
      app.send(:apply_window_size, 120, 40)
      output = Bubbles::ANSI.strip(app.send(:agent_chat_content, agent))

      assert(output.scan("grouped custom").length == 1, "expected grouped assistant messages to show one name tag")
      assert(output.scan("You").length == 1, "expected grouped user messages to show one name tag")
      assert(output.include?("Tool Call Group"), "expected grouped tool calls to show one collapsed tool label")
      assert(output.include?("3 tool calls: exec, file_change"), "expected grouped tool calls to hide generic tool names")
      assert(output.include?("First assistant chunk."), "expected first assistant body to remain visible")
      assert(output.include?("First user prompt."), "expected first user body to remain visible")
      assert(output.lines.none? { |line| line.include?("[grouped custom]") && line.include?("First assistant chunk.") },
             "expected chat block labels and message previews to render on separate lines")
      assert(output.include?("Second assistant chunk."), "expected second assistant body to remain visible")
      assert(output.include?("Second user prompt."), "expected second user body to remain visible")
      assert(!output.include?("List files"), "expected first tool body to be hidden while collapsed")
      assert(!output.include?("Read status"), "expected second tool body to be hidden while collapsed")

      app.instance_variable_set(:@agent_chat_form,
                                HQ::UI::AgentChatForm.new(agent, width: app.send(:sidebar_component_width),
                                                                 body_height: app.send(:sidebar_component_body_height)))
      app.send(:agent_chat_content, agent)
      form = app.instance_variable_get(:@agent_chat_form)
      assistant_index = form.conversation_blocks.index do |block|
        block[:kind] == :message && block[:label] == "grouped custom"
      end
      raise "expected a selectable assistant block" unless assistant_index

      while form.selected_block_index != assistant_index
        form.select_next_block
      end
      form.open_selected_block
      assistant_detail = Bubbles::ANSI.strip(form.block_viewport.view)
      assert(!assistant_detail.include?("grouped custom"), "expected opened assistant detail to omit redundant label")
      assert(assistant_detail.include?("First assistant chunk."), "expected first assistant body in block detail")
      assert(assistant_detail.include?("Second assistant chunk."), "expected second assistant body in block detail")
      form.close_block_detail

      tool_index = form.conversation_blocks.index { |block| block[:kind] == :tool_group }
      raise "expected a selectable grouped tool block" unless tool_index

      while form.selected_block_index != tool_index
        form.select_next_block
      end
      form.open_selected_block
      expanded = Bubbles::ANSI.strip(form.block_viewport.view)

      assert(!expanded.include?("exec"), "expected opened grouped tool calls to omit tool labels")
      assert(!expanded.include?("Tool result"), "expected opened grouped tool calls to omit result labels")
      assert(expanded.include?("List files"), "expected first tool body to render after opening")
      assert(expanded.include?("Read status"), "expected second tool body to render after opening")
    end
  end

  def assert_chat_formats_json_user_replies_as_key_value_blocks
    app = HQ::App.new
    app.send(:apply_window_size, 120, 40)
    json = JSON.pretty_generate(
      "title_direction" => "Will Your AI Workflow Get Clearer or Noisier?",
      "abstract_option" => "A",
      "free_feedback" => nil
    )

    rendered = Bubbles::ANSI.strip(app.send(:render_user_detail, json))

    assert(rendered.include?("TITLE DIRECTION\nWill Your AI Workflow Get Clearer or Noisier?"),
           "expected JSON user replies to render title_direction as an all-caps humanized key/value block")
    assert(rendered.include?("ABSTRACT OPTION\nA"),
           "expected JSON user replies to render abstract_option as an all-caps humanized key/value block")
    assert(rendered.include?("FREE FEEDBACK\nnull"),
           "expected JSON user replies to preserve null values")
    assert(!rendered.include?('"title_direction"'), "expected parsed user replies to omit raw JSON keys")
    assert(!rendered.include?("{"), "expected parsed user replies to omit raw JSON braces")
  end

  def assert_chat_composer_wraps_long_prompt
    prompt = "Wrap this composer input across the available width so it does not overflow horizontally in chat rendering."
    app = build_chat_app(width: 90, height: 30, prompt:)
    composer = app.instance_variable_get(:@agent_chat_form).composer
    output = Bubbles::ANSI.strip(app.view)

    assert(composer.input_view.lines.length >= 2, "expected long chat prompt to wrap across multiple lines")
    assert(output.include?("rendering."), "expected wrapped prompt tail to render in the chat view")

    composer.input_view.lines.map(&:chomp).each_with_index do |line, index|
      visible = visible_width(line.rstrip)
      assert(visible <= composer.width,
             "expected wrapped composer line #{index + 1} to fit within the composer width, got #{visible}: #{line.inspect}")
    end
  end

  def assert_chat_composer_wraps_on_word_boundary
    composer = HQ::UI::ChatComposer.new(width: 12, height: 4)
    composer.value = "alpha beta gamma"
    composer.blur_input

    lines = composer.input_view.lines.map { |line| Bubbles::ANSI.strip(line.chomp) }

    assert(lines.length >= 2, "expected composer to wrap onto a second line")
    assert(lines[0].rstrip == "alpha beta", "expected first wrapped line to keep the last full word intact")
    assert(lines[1].lstrip.start_with?("gamma"), "expected next wrapped word to move to the following line")
  end

  def assert_text_inputs_preserve_multi_rune_paste
    composer = HQ::UI::ChatComposer.new(width: 40, height: 4)
    composer.update_input(paste_key_message("Pasted chat text"))
    assert(composer.value == "Pasted chat text", "expected chat composer to keep all pasted text")

    app = HQ::App.new
    projects = app.instance_variable_get(:@projects)
    project = projects.find { |item| item.key == "warehouse" } || projects.first
    raise "expected at least one project for paste test" unless project

    app.instance_variable_set(:@screen, :projects)
    app.instance_variable_get(:@selected)[:projects] = projects.index(project) || 0
    app.send(:open_agent_editor_for_selected_project)

    editor = app.instance_variable_get(:@agent_editor)
    editor.name_input.value = ""
    editor.instance_variable_set(:@field_index, editor.name_field_index)
    editor.name_input.focus
    app.send(:handle_agent_editor, paste_key_message("Pasted Agent Name"))
    assert(editor.name_input.value == "Pasted Agent Name", "expected text input to keep all pasted text")

    editor.prompt_input.value = ""
    editor.instance_variable_set(:@field_index, editor.prompt_field_index)
    editor.prompt_input.focus
    app.send(:handle_agent_editor, paste_key_message("line one\nline two"))
    assert(editor.prompt_input.value == "line one\nline two", "expected text area to keep multiline pasted text")

    assert(File.executable?(File.expand_path("../bin/tycho", __dir__)),
           "expected bin/tycho to be executable")
    assert(File.read(File.expand_path("../lib/hq/cli.rb", __dir__)).include?("bracketed_paste: true"),
           "expected app startup to enable bracketed paste")
    assert(HQ::CLI.restart_command(["--debug"], File.expand_path("../bin/tycho", __dir__)).first.end_with?("/bin/tycho"),
           "expected restart to prefer the bin/tycho executable")
    assert(File.read(File.expand_path("../lib/hq/cli.rb", __dir__)).include?('Process.setproctitle("tycho")'),
           "expected app startup to set a readable process title")
    assert(File.read(File.expand_path("../bin/tycho", __dir__)).include?("TYCHO_PROCESS_NAME_BOOTSTRAPPED"),
           "expected bin/tycho to re-exec through a tycho-named runtime on macOS")
  end

  def assert_raw_paste_buffer_is_not_truncated
    sample = "lib/hq/ui/components/chat_composer.rb"
    events, paste_buffer = HQ::BubbleteaInput.parse_raw(sample)

    assert(paste_buffer.nil?, "expected sample paste to parse without pending bracketed paste state")
    assert(events.map { |event| event["name"] }.join == sample,
           "expected raw pasted sample to preserve every character")

    bracketed = "#{HQ::BubbleteaInput::BRACKETED_PASTE_START}#{sample}#{HQ::BubbleteaInput::BRACKETED_PASTE_END}"
    paste_events, = HQ::BubbleteaInput.parse_raw(bracketed)
    message = Bubbletea.parse_event(paste_events.first)
    composer = HQ::UI::ChatComposer.new(width: 80, height: 4)
    composer.update_input(message)

    assert(composer.value == sample, "expected bracketed pasted sample to reach the composer intact")
  end

  def assert_structured_result_overrides_fallback_summary_and_status
    run = HQ::ManagedAgent::AgentRun.new(
      started_at: Time.parse("2026-04-05 17:55:00"),
      finished_at: Time.parse("2026-04-05 17:56:00"),
      exit_code: 0,
      status: "succeeded"
    )
    agent = HQ::ManagedAgent.new(
      key: "structured-agent-test",
      name: "structured agent",
      project_key: "warehouse",
      template_key: "custom",
      workspace: "/Users/example/Code/warehouse",
      prompt: "Test",
      runs: [run],
      last_exit_code: 0,
      finished_at: Time.parse("2026-04-05 17:56:00")
    )
    agent.structured_result = { "status" => "partial", "summary" => "structured summary" }
    agent.summary = "structured summary"

    assert(agent.last_result_label == "partial", "expected structured status to override fallback result label")
    assert(agent.last_summary == "structured summary", "expected structured summary to override fallback summary")
  end

  def assert_structured_result_persists_attachments
    Dir.mktmpdir do |dir|
      started_at = Time.parse("2026-04-06 10:00:00")
      finished_at = Time.parse("2026-04-06 10:01:00")
      log_path = File.join(dir, "attachment-agent.raw.log")
      structured_output = {
        "status" => "success",
        "summary" => "Created review artifacts.",
        "inquiry" => nil,
        "attachments" => [
          {
            "kind" => "pr",
            "title" => "PR #1234: bugfixing some log",
            "url" => "https://github.com/example/app/pull/1234",
            "description" => "Generated implementation PR."
          },
          {
            "kind" => "markdown",
            "title" => "Plan for attachment feature",
            "url" => File.join(dir, "attachments-plan.md"),
            "description" => nil
          },
          {
            "kind" => "photo",
            "title" => "Infographic for a plan",
            "url" => File.join(dir, "plan.png"),
            "description" => ""
          }
        ]
      }
      File.write(File.join(dir, "attachments-plan.md"), "# Plan\n")
      File.binwrite(File.join(dir, "plan.png"), "png")
      File.write(log_path, [
        "=== [#{started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ===",
        "workspace=#{dir}",
        "prompt=Test attachments",
        JSON.generate("type" => "result", "structured_output" => structured_output)
      ].join("\n"))

      agent = HQ::ManagedAgent.new(
        key: "attachment-agent",
        name: "attachment agent",
        project_key: "warehouse",
        template_key: "custom",
        workspace: dir,
        prompt: "Test attachments",
        agent: "claude",
        log_path: log_path,
        created_at: started_at - 1,
        started_at: started_at,
        last_exit_code: 0,
        runs: [
          HQ::ManagedAgent::AgentRun.new(
            started_at: started_at,
            status: "running",
            log_path: log_path
          )
        ]
      )
      agent.instance_variable_set(:@finished_at, finished_at)
      agent.instance_variable_set(:@last_exit_code, 0)

      agent.send(:finalize_latest_run!)

      attachments = agent.attachments
      assert(attachments.map { |item| item["type"] } == %w[link file file],
             "expected attachment types to normalize for compact rendering, got #{attachments.inspect}")
      assert(attachments.map { |item| item["kind"] } == %w[link document image],
             "expected attachment kinds to normalize for compact rendering, got #{attachments.inspect}")
      assert(attachments.map { |item| item["title"] }.include?("PR #1234: bugfixing some log"),
             "expected PR attachment title to persist")
      assert(File.exist?(agent.attachments_path), "expected attachments to persist outside rebuildable memory")
      memory_events = HQ::AgentMemory.new(agent).events
      assert(memory_events.any? { |event| event["type"] == "attachment" },
             "expected finalized run to write attachment events to memory")
      run_summary = memory_events.reverse.find { |event| event["type"] == "run_summary" }
      assert(run_summary&.dig("metadata", "attachments").is_a?(Array),
             "expected run summary metadata to keep structured attachments")

      HQ::AgentChatLog.new(agent).rebuild_memory_from_raw_log!
      rebuilt_attachments = agent.attachments
      assert(rebuilt_attachments.map { |item| item["title"] }.include?("PR #1234: bugfixing some log"),
             "expected attachments to survive memory rebuilds")
      rebuilt_events = HQ::AgentMemory.new(agent).events
      assert(rebuilt_events.any? { |event| event["type"] == "attachment" },
             "expected memory rebuild to restore attachment events from durable attachments")
    end
  end

  def assert_input_required_result_renders_structured_inquiry
    app = build_input_required_chat_app(width: 120, height: 30)
    form = app.instance_variable_get(:@agent_chat_form).inquiry_form
    output = app.view
    plain_output = Bubbles::ANSI.strip(output)

    assert(form.answer_fields.map(&:input_type) == %w[multiline text],
           "expected field-based inquiry normalization to preserve multiline/text input types")
    assert(plain_output.include?("awaiting input"), "expected result label to reflect awaiting input")
    assert(plain_output.include?("Question 1/3:"),
           "expected inquiry box to show question progress including review step")
    assert(plain_output.include?("Short Reflection"), "expected inquiry field label")
    assert(plain_output.include?("A few sentences about what stood out"), "expected inquiry field description")
    assert(plain_output.include?("required"), "expected required field metadata")
    assert(!plain_output.include?("Reply in the composer below to continue this agent run."),
           "expected old inquiry transcript card to be removed")
    assert(plain_output.include?("awaiting input"), "expected transcript footer to use effective current state")
    assert(plain_output.include?("⇥: focus sections"), "expected inquiry mode to allow focus switching")
    assert(plain_output.include?("enter: next"), "expected inquiry-specific prompt hint")
    assert(plain_output.include?("⌃P: prev"), "expected inquiry-specific prev-field hint")
  end

  def assert_multi_field_inquiry_shows_one_field_at_a_time
    app = build_multi_field_inquiry_chat_app
    agent = app.instance_variable_get(:@agents).first
    form = app.instance_variable_get(:@agent_chat_form).inquiry_form

    inquiry = agent.latest_inquiry
    assert(inquiry.is_a?(Hash), "expected latest_inquiry to be present")
    schema = inquiry["requested_schema"]
    assert(schema.is_a?(Hash) && schema["properties"].is_a?(Hash),
           "expected normalized inquiry to carry requested_schema properties")
    assert(schema["properties"].keys == %w[new_feature area has_tests priority additional_context],
           "expected requested_schema to preserve field order from the persisted agent state")

    expected_keys = %w[new_feature area has_tests priority additional_context]
    assert(form.answer_fields.length == 5,
           "expected all 5 inquiry answer fields to be loaded into the form, got #{form.answer_fields.length}")
    assert(form.answer_fields.map(&:key) == expected_keys,
           "expected inquiry form to hydrate fields from requested_schema in original order, got #{form.answer_fields.map(&:key).inspect}")
    assert(form.answer_fields.map(&:input_type) == %w[boolean select boolean select text],
           "expected requested_schema to map to boolean/select/text input types")
    assert(form.answer_fields.map(&:required) == [true, true, true, true, false],
           "expected requested_schema 'required' list to mark the first four fields required")
    assert(form.answer_fields[1].options == [
      "Meetup Scheduling", "Admin Panel", "Discord Notifications",
      "Typefully Webhook", "Deployment / Infrastructure", "Other"
    ], "expected enum values to carry over as select options")
    assert(form.fields.length == 6,
           "expected inquiry form to append a review step as the last field, got #{form.fields.length}")
    assert(form.fields.last.input_type == "review",
           "expected the appended step to be a review field")

    plain = Bubbles::ANSI.strip(app.view)

    assert(plain.include?("Question 1/6:"),
           "expected chat form to render inquiry progress in box (including review step)")
    assert(plain.include?("Are you looking to add a new"),
           "expected first field label to render in inquiry box")
    assert(plain.include?("Whether this request involves building"),
           "expected first field description")

    later_field_labels = [
      "Which area of the application",
      "Should this include tests",
      "What is the priority level",
      "Any additional context?"
    ]
    later_field_labels.each do |label|
      assert(!plain.include?(label),
             "expected chat form to hide later inquiry field #{label.inspect} while only the current field is shown")
    end

    assert(!plain.include?("Meetup Scheduling"), "expected select options for non-current fields to stay hidden")
    assert(!plain.include?("Critical - blocking other work"),
           "expected select options for non-current fields to stay hidden")

    form.next_field
    app.send(:sync_agent_chat_workspace!)
    plain_second = Bubbles::ANSI.strip(app.view)
    assert(plain_second.include?("Question 2/6:"),
           "expected next_field to advance progress indicator to the second question")
    assert(plain_second.include?("Which area of the application"),
           "expected second field label to render in inquiry box")
    assert(!plain_second.include?("Are you looking to add a new"),
           "expected previous field label to disappear once focus advances")
    assert(plain_second.include?("Meetup Scheduling"),
           "expected the focused select field's picker to show its options inside the inquiry box")

    select_field = form.current_field
    assert(select_field.input.is_a?(HQ::UI::OptionPicker),
           "expected select field to use the OptionPicker widget")
    ["Meetup Scheduling", "Admin Panel", "Discord Notifications", "Typefully Webhook"].each do |option|
      assert(plain_second.include?(option),
             "expected select field to render option row #{option.inspect}")
    end

    down = Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_DOWN)
    form.update_input(down)
    form.update_input(down)
    app.send(:sync_agent_chat_workspace!)
    plain_selected = Bubbles::ANSI.strip(app.view)
    assert(select_field.input.value == "Admin Panel",
           "expected two down-key presses to select 'Admin Panel', got #{select_field.input.value.inspect}")
    assert(plain_selected.include?("#{HQ::UI::OptionPicker::MARKER} Admin Panel"),
           "expected the selected option to render with the picker marker")

    form.previous_field
    form.current_field.input.update(Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_DOWN))
    assert(form.current_field.input.value == "Yes",
           "expected boolean field to expose Yes/No options via the picker")
  end

  def assert_multi_select_inquiry_renders_checkbox_picker
    app = build_multi_select_inquiry_chat_app
    form = app.instance_variable_get(:@agent_chat_form).inquiry_form

    assert(form.answer_fields.map(&:input_type) == %w[multi_select select text],
           "expected field-based inquiry normalization to preserve multi_select/select/text types")

    plain = Bubbles::ANSI.strip(app.view)
    assert(plain.include?("Question 1/4:"), "expected inquiry progress to include the review step")
    assert(plain.include?("Banter picks"), "expected multi-select label to render")
    assert(plain.include?("[ ] Use recommendation"), "expected multi-select options to render as checkboxes")
    assert(plain.include?("[ ] A"), "expected multi-select picker to show option A")

    down = Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_DOWN)
    space = Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_SPACE)
    form.update_input(space)
    form.update_input(down)
    form.update_input(down)
    form.update_input(space)
    app.send(:sync_agent_chat_workspace!)

    assert(form.current_field.input.value == ["Use recommendation", "B"],
           "expected space to toggle multiple options in order, got #{form.current_field.input.value.inspect}")

    plain_selected = Bubbles::ANSI.strip(app.view)
    assert(plain_selected.include?("[x] Use recommendation"),
           "expected selected multi-select option to render with a checked box")
    assert(plain_selected.include?("[x] B"),
           "expected later selected option to render with a checked box")

    form.next_field
    form.current_field.input.update(down)
    form.next_field
    form.current_field.input.value = "Keep the tone playful."
    form.next_field
    form.current_field.input.value = HQ::UI::InquiryForm::REVIEW_SUBMIT

    content = JSON.parse(form.content)
    assert(content["banter_selection"] == ["Use recommendation", "B"],
           "expected multi-select inquiry submission to serialize an array")

    review = Bubbles::ANSI.strip(app.tap { |value| value.send(:sync_agent_chat_workspace!) }.view)
    assert(review.include?("Banter picks: Use recommendation, B"),
           "expected review step to summarize selected multi-select options")
  end

  def assert_inquiry_form_requires_review_step_before_submit
    app = build_multi_field_inquiry_chat_app
    agent = app.instance_variable_get(:@agents).first
    submissions = 0
    agent.define_singleton_method(:add_user_message!) { |_| submissions += 1 }
    agent.define_singleton_method(:start!) { nil }
    app.define_singleton_method(:save_agents!) { nil }

    form = app.instance_variable_get(:@agent_chat_form).inquiry_form
    down = Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_DOWN)
    form.current_field.input.update(down)
    form.next_field
    form.current_field.input.update(down)

    app.send(:save_agent_chat_form)
    assert(submissions.zero?,
           "expected save to refuse while a required field is still empty, got #{submissions} submissions")
    assert(form.error_message.to_s.include?("is required") || form.error_message.to_s.include?("review step"),
           "expected save to surface a validation or review hint, got #{form.error_message.inspect}")

    # validate() jumped focus to the first missing required field (has_tests, index 2);
    # handle_inquiry_enter then advances one step from there.
    assert(form.field_index == 2,
           "expected failed save to park focus on the first missing required field, got field_index=#{form.field_index}")
    app.send(:handle_inquiry_enter)
    assert(form.field_index == 3,
           "expected enter on the parked field to advance to the next answer field, got field_index=#{form.field_index}")
    assert(submissions.zero?, "expected enter on an answer field to never submit, got #{submissions} submissions")

    form.previous_field
    form.current_field.input.update(down) # has_tests
    form.next_field
    form.current_field.input.update(down) # priority
    form.next_field
    assert(form.fields[4].key == "additional_context", "expected to land on the optional text field")
    form.next_field
    assert(form.review?, "expected to reach the review step after cycling through all answer fields")

    plain_review = Bubbles::ANSI.strip(app.tap { |a| a.send(:sync_agent_chat_workspace!) }.view)
    assert(plain_review.include?("Review & submit"), "expected review step title on the chat form")
    assert(plain_review.include?("Are you looking to add a new"),
           "expected review step to list the first question and its picked answer")
    assert(plain_review.include?("Meetup Scheduling"),
           "expected review step to list the second picked answer")

    app.send(:handle_inquiry_enter)
    assert(submissions.zero?,
           "expected enter on the review step without picking Submit to refuse submission, got #{submissions}")
    assert(form.error_message.to_s.include?("Submit"),
           "expected review-step hint to mention Submit, got #{form.error_message.inspect}")

    form.current_field.input.update(down) # picks Submit
    assert(form.submit_ready?, "expected Submit to mark the form as ready once all required answers are filled")
    app.send(:handle_inquiry_enter)
    assert(submissions == 1, "expected exactly one submission after picking Submit, got #{submissions}")
  end

  def assert_inquiry_form_submission_serializes_json
    app = build_input_required_chat_app
    agent = app.instance_variable_get(:@agents).first
    agent.define_singleton_method(:start!) { @started = true }

    form = app.instance_variable_get(:@agent_chat_form).inquiry_form
    form.current_field.input.value = "Draft today's journal"
    form.next_field
    form.current_field.input.value = "Focus on the sunroof repair."
    form.next_field
    assert(form.review?, "expected form to land on the review step after both answers are filled")
    form.current_field.input.value = HQ::UI::InquiryForm::REVIEW_SUBMIT
    assert(form.submit_ready?, "expected the review step with Submit selected to mark the form ready to submit")

    app.send(:save_agent_chat_form)

    last_message = agent.conversation_messages.last
    assert(last_message.role == "user", "expected form submission to append a user message")
    assert(last_message.content.include?("\"reflection\": \"Draft today's journal\""),
           "expected required field in serialized JSON")
    assert(last_message.content.include?("\"context\": \"Focus on the sunroof repair.\""),
           "expected multiline field in serialized JSON")

    app.send(:agent_chat_content, agent)
    chat_form = app.instance_variable_get(:@agent_chat_form)
    user_index = chat_form.conversation_blocks.rindex { |block| block[:inquiry_response] }
    raise "expected a selectable submitted user answers block" unless user_index
    inquiry_block = chat_form.conversation_blocks[user_index]
    assert(inquiry_block[:label].include?("User Answers"),
           "expected inquiry responses to use a branded user answers label")
    assert(inquiry_block[:label].include?(HQ::UI::Rendering::Styles::STATUS_ICONS[:awaiting_input]),
           "expected inquiry responses to reuse the inquiry icon")

    while chat_form.selected_block_index != user_index
      chat_form.select_next_block
    end
    chat_form.open_selected_block
    plain_rendered = Bubbles::ANSI.strip(chat_form.block_viewport.view).lines.map(&:rstrip).join("\n")
    assert(plain_rendered.include?("REFLECTION\nDraft today's journal"),
           "expected rendered chat message to use key/value blocks")
    assert(plain_rendered.include?("CONTEXT\nFocus on the sunroof repair."),
           "expected rendered chat message to label optional JSON fields")
    assert(!plain_rendered.include?("\"reflection\""), "expected rendered chat message to avoid raw JSON formatting")
    assert(agent.latest_inquiry.nil?, "expected inquiry state to clear after submitting a response")
    assert(!app.instance_variable_get(:@agent_chat_form).inquiry_active?,
           "expected inquiry form to close once a response is submitted")
  end

  def assert_composed_prompt_includes_compact_tool_summaries_from_memory
    Dir.mktmpdir do |dir|
      started_at = Time.parse("2026-04-13 09:15:00")
      finished_at = Time.parse("2026-04-13 09:16:00")
      log_path = File.join(dir, "agent.raw.log")

      assistant_event = {
        "type" => "assistant",
        "message" => {
          "role" => "assistant",
          "content" => [
            {
              "type" => "tool_use",
              "id" => "toolu_check_login",
              "name" => "Bash",
              "input" => {
                "description" => "Check login page",
                "command" => 'curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/login'
              }
            }
          ]
        }
      }
      message_event = {
        "type" => "item.completed",
        "item" => {
          "type" => "agent_message",
          "text" => "I checked the login page and it returned 200."
        }
      }
      result_event = {
        "type" => "result",
        "structured_output" => {
          "status" => "success",
          "summary" => "Checked login page successfully."
        }
      }

      File.write(log_path, [
        "=== [#{started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ===",
        "workspace=#{dir}",
        "prompt=SYSTEM:",
        "Inspect the app.",
        "USER:",
        "Please verify the login page.",
        "",
        JSON.generate(assistant_event),
        JSON.generate(message_event),
        JSON.generate(result_event)
      ].join("\n"))

      agent = HQ::ManagedAgent.new(
        key: "memory-prompt-agent",
        name: "memory prompt",
        project_key: "warehouse",
        template_key: "custom",
        workspace: dir,
        prompt: "Inspect the app.",
        agent: "claude",
        log_path: log_path,
        created_at: Time.parse("2026-04-13 09:14:00"),
        started_at: started_at,
        last_exit_code: 0,
        runs: [
          HQ::ManagedAgent::AgentRun.new(
            started_at: started_at,
            status: "running",
            log_path: log_path
          )
        ],
        messages: [
          HQ::ManagedAgent::AgentMessage.new(role: "system", content: "Inspect the app.",
                                             created_at: Time.parse("2026-04-13 09:14:00")),
          HQ::ManagedAgent::AgentMessage.new(role: "user", content: "Please verify the login page.",
                                             created_at: started_at)
        ]
      )

      agent.instance_variable_set(:@finished_at, finished_at)
      agent.instance_variable_set(:@last_exit_code, 0)
      agent.send(:finalize_latest_run!)

      prompt = agent.send(:composed_prompt)
      assert(File.exist?(agent.memory_path), "expected finalized runs to persist canonical memory")
      assert(prompt.include?("tool: Bash: Check login page"),
             "expected prompt assembly to include the compact Bash tool summary")
      assert(prompt.include?("ASSISTANT:\nI checked the login page and it returned 200."),
             "expected prompt assembly to carry forward the assistant reply from memory")
    end
  end

  def assert_agent_chat_log_projects_from_memory_without_raw_log
    Dir.mktmpdir do |dir|
      started_at = Time.parse("2026-04-13 10:00:00")
      finished_at = Time.parse("2026-04-13 10:01:00")
      log_path = File.join(dir, "agent.raw.log")

      assistant_event = {
        "type" => "assistant",
        "message" => {
          "role" => "assistant",
          "content" => [
            {
              "type" => "tool_use",
              "id" => "toolu_repo_search",
              "name" => "Bash",
              "input" => {
                "description" => "Search for login route",
                "command" => "rg -n \"login\" config routes app"
              }
            }
          ]
        }
      }
      message_event = {
        "type" => "item.completed",
        "item" => {
          "type" => "agent_message",
          "text" => "I found the login route in config/routes.rb."
        }
      }
      result_event = {
        "type" => "result",
        "structured_output" => {
          "status" => "success",
          "summary" => "Found the login route."
        }
      }

      File.write(log_path, [
        "=== [#{started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ===",
        "workspace=#{dir}",
        "prompt=SYSTEM:",
        "Inspect the app.",
        "USER:",
        "Where is the login route?",
        "",
        JSON.generate(assistant_event),
        JSON.generate(message_event),
        JSON.generate(result_event)
      ].join("\n"))

      agent = HQ::ManagedAgent.new(
        key: "memory-chat-log-agent",
        name: "memory chat log",
        project_key: "warehouse",
        template_key: "custom",
        workspace: dir,
        prompt: "Inspect the app.",
        agent: "claude",
        log_path: log_path,
        created_at: Time.parse("2026-04-13 09:59:00"),
        started_at: started_at,
        last_exit_code: 0,
        runs: [
          HQ::ManagedAgent::AgentRun.new(
            started_at: started_at,
            status: "running",
            log_path: log_path
          )
        ],
        messages: [
          HQ::ManagedAgent::AgentMessage.new(role: "system", content: "Inspect the app.",
                                             created_at: Time.parse("2026-04-13 09:59:00")),
          HQ::ManagedAgent::AgentMessage.new(role: "user", content: "Where is the login route?", created_at: started_at)
        ]
      )

      agent.instance_variable_set(:@finished_at, finished_at)
      agent.instance_variable_set(:@last_exit_code, 0)
      agent.send(:finalize_latest_run!)
      File.delete(log_path)

      chat_log = HQ::AgentChatLog.new(agent)
      chat_log.ensure_generated

      conversation = File.read(agent.conversation_log_path)
      system = File.read(agent.system_log_path)

      assert(conversation.include?("Where is the login route?"),
             "expected conversation log to be projected from memory")
      assert(conversation.include?("I found the login route in config/routes.rb."),
             "expected assistant reply to survive without raw.log")
      assert(system.include?("Search for login route"),
             "expected system log to project tool summaries from memory")
      assert(system.include?("Found the login route."),
             "expected system log to include run summary entries from memory")

      blocks = chat_log.chat_blocks
      tool_blocks = blocks.select { |b| b.kind == :tool_call }
      assert(tool_blocks.any? { |b| b.tool_name == "Bash" && b.content.include?("Search for login route") },
             "expected chat blocks to expand compact tool summaries from memory")
      messages = blocks.select { |b| b.kind == :message }
      assert(messages.any? { |b| b.role == "user" && b.content.include?("Where is the login route?") },
             "expected chat blocks to include user message from memory")
      assert(messages.any? { |b| b.role == "assistant" && b.content.include?("I found the login route") },
             "expected chat blocks to include assistant message from memory")
    end
  end

  def assert_codex_failed_run_error_appears_in_chat_log
    lines = [
      "workspace=/tmp/blog",
      "prompt=All looks good. Publish this draft",
      "",
      JSON.generate("type" => "thread.started", "thread_id" => "thread-1"),
      JSON.generate("type" => "turn.started"),
      JSON.generate(
        "type" => "error",
        "message" => "You've hit your usage limit. Try again at 2:01 PM."
      ),
      JSON.generate(
        "type" => "turn.failed",
        "error" => {
          "message" => "You've hit your usage limit. Try again at 2:01 PM."
        }
      )
    ]

    conversation, system = HQ::Parser.parse_run(lines, agent_type: "codex")
    blocks = HQ::Parser.compose_chat_blocks(conversation, system)

    user_messages = blocks.select { |b| b.kind == :message && b.role == "user" }
    summaries = blocks.select { |b| b.kind == :summary }.map(&:content)

    assert(user_messages.any? { |b| b.content.include?("All looks good. Publish this draft") },
           "expected one-line codex prompt header to appear as a user chat message")
    assert(summaries.any? { |content| content.include?("usage limit") },
           "expected codex error event to appear in chat summaries")
  end

  def assert_failed_run_summary_from_memory_appears_in_chat_log
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "agent.raw.log")
      File.write(log_path, "")

      agent = HQ::ManagedAgent.new(
        key: "failed-memory-chat-agent",
        name: "failed memory chat",
        project_key: "warehouse",
        template_key: "custom",
        workspace: dir,
        prompt: "SYSTEM:\nManage the blog.",
        agent: "codex",
        log_path: log_path,
        created_at: Time.parse("2026-04-30 13:50:00"),
        messages: [
          HQ::ManagedAgent::AgentMessage.new(
            role: "user",
            content: "All looks good. Publish this draft",
            created_at: Time.parse("2026-04-30 13:51:35")
          )
        ]
      )

      memory = HQ::AgentMemory.new(agent)
      memory.append_user_message!(
        "All looks good. Publish this draft",
        created_at: Time.parse("2026-04-30 13:51:35")
      )
      memory.append_run_summary!(
        summary: "{\"type\":\"error\",\"message\":\"You've hit your usage limit. Try again at 2:01 PM.\"}",
        status: "failed",
        created_at: Time.parse("2026-04-30 13:51:55")
      )

      blocks = HQ::AgentChatLog.new(agent).chat_blocks
      run_summaries = blocks.select { |b| b.kind == :run_summary }.map(&:content)

      assert(blocks.any? { |b| b.kind == :message && b.role == "user" && b.content.include?("Publish this draft") },
             "expected failed run user message to remain visible from memory")
      assert(run_summaries.any? { |content| content.include?("failed: You've hit your usage limit") },
             "expected failed run summary to appear in chat run summaries")
    end
  end

  def assert_chat_q_only_closes_from_content_focus
    app = build_chat_app

    app.send(:handle_sidebar, key_message("q"))
    assert(!app.instance_variable_get(:@agent_chat_form).nil?, "expected q to pass through to chat composer, not close")

    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_ESC))
    assert(app.instance_variable_get(:@agent_chat_form).nil?, "expected esc to close the chat sidebar")
  end

  def assert_chat_content_focus_scrolls_with_arrow_keys
    app = build_running_chat_app(width: 120, height: 30)
    form = app.instance_variable_get(:@agent_chat_form)

    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_TAB))
    assert(form.content_focused?, "expected tab to focus the transcript viewport")
    start_index = form.selected_block_index

    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_UP))
    assert(form.selected_block_index != start_index, "expected up arrow to select a different chat block")

    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_DOWN))
    assert(form.selected_block_index == start_index, "expected down arrow to return to the original chat block")

    form.open_selected_block
    form.block_viewport.content = (1..40).map { |index| "block detail line #{index}" }.join("\n")
    form.block_viewport.goto_bottom
    bottom_offset = form.block_viewport.y_offset

    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_UP))
    assert(form.block_viewport.y_offset < bottom_offset,
           "expected up arrow to scroll opened block detail up from offset #{bottom_offset}, got #{form.block_viewport.y_offset}")

    up_offset = form.block_viewport.y_offset
    app.send(:handle_sidebar, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_DOWN))
    assert(form.block_viewport.y_offset > up_offset,
           "expected down arrow to scroll opened block detail down from offset #{up_offset}, got #{form.block_viewport.y_offset}")
  end

  def assert_chat_block_selection_scrolls_with_large_messages
    Dir.mktmpdir do |dir|
      agent = HQ::ManagedAgent.new(
        key: "large-message-chat-agent",
        name: "large message custom",
        project_key: "warehouse",
        template_key: "custom",
        workspace: dir,
        prompt: "Test",
        agent: "claude",
        log_path: File.join(dir, "large.raw.log"),
        created_at: Time.parse("2026-05-01 10:00:00")
      )

      memory = HQ::AgentMemory.new(agent)
      long_path = "/Users/example/Library/Mobile%20Documents/com~apple~CloudDocs/" \
                  "#{"nested-directory-" * 8}SKILL.md"
      large_message = [
        "Large assistant line with long path #{long_path}",
        *(1..20).map { |index| "Large assistant line #{index}" }
      ].join("\n")
      memory.append_assistant_message!(large_message,
                                       created_at: Time.parse("2026-05-01 10:01:00"))
      memory.append_user_message!("Short follow-up.", created_at: Time.parse("2026-05-01 10:02:00"))
      memory.append_tool_summary!("Tool after large message", tool_name: "exec",
                                  created_at: Time.parse("2026-05-01 10:03:00"))

      app = HQ::App.new
      app.send(:apply_window_size, 100, 20)
      form = HQ::UI::AgentChatForm.new(agent, width: app.send(:sidebar_component_width),
                                              body_height: app.send(:sidebar_component_body_height))
      app.instance_variable_set(:@agent_chat_form, form)
      app.send(:agent_chat_content, agent)

      form.select_next_block
      selected = form.selected_block
      assert(selected[:label] == "large message custom", "expected latest-block wrap to select the large assistant block")
      assert(selected[:line_height] >= form.viewport.height, "expected fixture assistant block to exceed viewport height")
      assert(form.viewport.y_offset == selected[:line_offset],
             "expected oversized selected block to be aligned to the top of the viewport")
      first_visible_line = Bubbles::ANSI.strip(form.viewport.view).lines.first.to_s
      assert(first_visible_line.include?("large message custom"),
             "expected oversized selected block label to remain visible, got #{first_visible_line.inspect}")
      form.viewport.view.lines.each do |line|
        assert(visible_width(line.rstrip) <= form.viewport.width,
               "expected chat viewport line to fit width #{form.viewport.width}, got #{visible_width(line.rstrip)}: #{line.inspect}")
      end

      form.select_next_block
      selected = form.selected_block
      assert(selected[:label] == "You", "expected previous block to select the user message")
      expected_offset = [selected[:line_offset] + selected[:line_height] - form.viewport.height, 0].max
      assert(form.viewport.y_offset == expected_offset,
             "expected selected user block below the viewport to align near the bottom")

      while form.selected_block_index != form.conversation_blocks.length - 1
        form.select_next_block
      end
      app.send(:handle_agent_chat_form, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_TAB))
      form.viewport.goto_bottom
      app.send(:handle_agent_chat_form, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_LEFT))
      app.send(:handle_agent_chat_form, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_LEFT))
      selected = form.selected_block
      assert(selected[:label] == "large message custom", "expected key navigation to select the large assistant block")
      assert(form.viewport.y_offset == selected[:line_offset],
             "expected content-focused refresh to preserve selected block top alignment")
      assert(!form.selected_block_viewport_debug.start_with?("visible 0/0"),
             "expected selected block debug to report visible rows")
    end
  end

  def assert_agent_editor_renders_template_and_harness_choices
    output = render_agent_editor(width: 120, height: 30)
    plain_output = Bubbles::ANSI.strip(output)
    app = HQ::App.new
    projects = app.instance_variable_get(:@projects)
    project = projects.find { |item| item.key == "warehouse" } || projects.first
    raise "expected at least one project for agent editor ordering test" unless project

    app.instance_variable_set(:@screen, :projects)
    app.instance_variable_get(:@selected)[:projects] = projects.index(project) || 0
    app.send(:apply_window_size, 120, 30)
    app.send(:open_agent_editor_for_selected_project)
    editor = app.instance_variable_get(:@agent_editor)
    template_names = editor.template_choices.map(&:name)

    assert(plain_output.include?("Template: Custom"), "expected selected template summary in form")
    assert(plain_output.include?("Custom"), "expected custom template choice")
    assert(plain_output.include?("Implementer"), "expected implementer template choice")
    assert(plain_output.include?("Reviewer"), "expected reviewer template choice")
    assert(plain_output.include?("Harness: codex"), "expected selected harness summary in form")
    assert(plain_output.include?("codex"), "expected codex harness choice")
    assert(plain_output.include?("claude"), "expected claude harness choice")
    assert(plain_output.include?("claude-wrapper"), "expected custom Claude harness choice")
    assert(template_names == template_names.sort,
           "expected template choices to be sorted alphabetically, got #{template_names.inspect}")
  end

  def assert_web_project_icon_renders_for_project_contexts
    projects_output = Bubbles::ANSI.strip(render_main_screen(:projects, width: 120, height: 30))
    editor_output = Bubbles::ANSI.strip(render_agent_editor(width: 120, height: 30))
    chat_output = Bubbles::ANSI.strip(render_chat_screen(width: 120, height: 30))

    assert(projects_output.include?("#{WEB_PROJECT_ICON} warehouse"), "expected app project row to use the web icon")
    assert(editor_output.include?("Create Agent for #{WEB_PROJECT_ICON} warehouse"),
           "expected agent editor project label to use the web icon")
    assert(chat_output.include?("#{WEB_PROJECT_ICON} warehouse #{CURSOR_MARKER}"),
           "expected chat header project label to use the web icon")
  end

  def assert_non_app_project_uses_folder_icon
    projects_output = Bubbles::ANSI.strip(render_main_screen(:projects, width: 120, height: 30))

    assert(projects_output.include?("#{FOLDER_PROJECT_ICON} hq"),
           "expected non-app project row to use the folder icon")
    assert(projects_output.include?("#{FOLDER_PROJECT_ICON} Demo Web"),
           "expected grouped non-app project row to use the folder icon")
  end

  def assert_project_archive_moves_config_logs_and_agents
    Dir.mktmpdir do |dir|
      old_config_path = ENV["TYCHO_CONFIG_PATH"]
      config_path = File.join(dir, "hq.yml")
      archived_config_path = File.join(dir, "hq.archived.yml")
      demo_path = File.join(dir, "demo")
      keep_path = File.join(dir, "keep")
      FileUtils.mkdir_p([demo_path, keep_path])
      File.write(config_path, <<~YAML)
        projects:
          - key: demo
            name: Demo Project
            group: Test
            path: #{demo_path}
            apps: false
          - key: keep
            name: Keep Project
            group: Test
            path: #{keep_path}
            apps: false
      YAML
      ENV["TYCHO_CONFIG_PATH"] = config_path

      app = HQ::App.new
      project = app.instance_variable_get(:@projects).find { |item| item.key == "demo" }
      raise "expected demo project for project archive test" unless project

      agent = HQ::ManagedAgent.new(
        key: "demo-agent-1",
        name: "Demo Agent",
        project_key: "demo",
        template_key: "default",
        workspace: demo_path,
        prompt: "Test"
      )
      File.write(agent.raw_log_path, "raw output")
      app.instance_variable_set(:@agents, [agent])
      app.send(:rebuild_agent_index!)

      app.instance_variable_set(:@screen, :projects)
      app.instance_variable_get(:@selected)[:projects] = app.instance_variable_get(:@projects).index(project) || 0

      FileUtils.mkdir_p(project.log_dir)
      File.write(project.action_log_path, "deploy output")
      File.write(File.join(project.log_dir, "deploy_20260321_084122.log"), "old deploy output")

      app.send(:handle_key, "x")
      archive_confirm = app.instance_variable_get(:@project_archive_confirm)
      assert(!archive_confirm.nil?, "expected x on projects screen to open the archive confirmation modal")
      assert(Bubbles::ANSI.strip(app.view).include?("Archive project?"),
             "expected archive confirmation to render as a modal")

      app.send(:handle_project_archive_confirm, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RIGHT))
      app.send(:handle_project_archive_confirm, Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_ENTER))

      active_config = YAML.safe_load(File.read(config_path))
      archived_config = YAML.safe_load(File.read(archived_config_path))
      assert(active_config["projects"].map { |item| item["key"] } == ["keep"],
             "expected archived project to be removed from active hq.yml")
      assert(archived_config["projects"].map { |item| item["key"] } == ["demo"],
             "expected archived project to move into hq.archived.yml")
      assert(app.instance_variable_get(:@projects).map(&:key) == ["keep"],
             "expected archived project to disappear from the TUI project list")
      assert(app.instance_variable_get(:@agents).empty?,
             "expected agents for the archived project to disappear from the TUI agent list")

      date = Time.now.strftime("%Y-%m-%d")
      archives = Dir.glob(File.join(HQ::PROJECT_ARCHIVE_DIR, "#{date}_demo-project*"))
      assert(archives.length == 1, "expected one archive directory for demo project, got #{archives.inspect}")
      archived = archives.first

      assert(!Dir.exist?(project.log_dir), "expected original project log directory to be moved")
      assert(File.exist?(File.join(archived, "action.log")), "expected action log in archive")
      assert(File.exist?(File.join(archived, "deploy_20260321_084122.log")), "expected historical deploy log in archive")
      assert(Dir.glob(File.join(HQ::AGENT_ARCHIVE_DIR, "*demo-agent-1", "*.raw.log")).any?,
             "expected related agent logs to be archived")
    ensure
      ENV["TYCHO_CONFIG_PATH"] = old_config_path
    end
  end

  def assert_failed_kamal_action_log_marks_action_failed
    started_at = Time.parse("2026-05-02 05:30:23")
    action = HQ::KamalAction.new(
      project_key: "failed-deploy-test",
      project_name: "Failed Deploy",
      project_path: "/tmp",
      action: :deploy,
      pid: 999_999,
      started_at: started_at
    )
    FileUtils.mkdir_p(File.dirname(action.log_path))
    File.write(action.log_path, <<~LOG)

      === [#{started_at.strftime("%Y-%m-%d %H:%M:%S")}] deploy ===

      Build and push app image...
        ERROR (SSHKit::Command::Failed): docker exit status: 32000
      docker stderr: Cannot connect to the Docker daemon
    LOG

    action.poll!

    assert(action.done?, "expected finished action to be marked done")
    assert(action.success? == false, "expected failed deploy log to mark action failed")
  end

  def assert_create_agent_starts_immediately_and_uses_selected_harness
    app = HQ::App.new
    app.define_singleton_method(:save_agents!) { nil }

    projects = app.instance_variable_get(:@projects)
    project = projects.find { |item| item.key == "warehouse" } || projects.first
    raise "expected at least one project for agent form test" unless project

    app.instance_variable_set(:@screen, :projects)
    app.instance_variable_get(:@selected)[:projects] = projects.index(project) || 0
    app.send(:open_agent_editor_for_selected_project)

    form = app.instance_variable_get(:@agent_editor)
    form.cycle_template(1)
    form.cycle_harness(1)
    form.instance_variable_set(:@field_index, form.create_and_run_button_index)

    created_agent = nil
    store = app.instance_variable_get(:@agent_store)
    store.define_singleton_method(:create_from_template) do |selected_project, template_key|
      created_agent = HQ::ManagedAgent.new(
        key: "created-agent-test",
        name: "#{selected_project.name} created",
        project_key: selected_project.key,
        template_key: template_key,
        workspace: selected_project.path,
        prompt: "placeholder"
      )
      created_agent.define_singleton_method(:start!) do
        @started = true
        @started_at = Time.now
        @pid = Process.pid
        @runs << HQ::ManagedAgent::AgentRun.new(started_at: @started_at, status: "running")
      end
      created_agent
    end

    _, command = app.send(:save_agent_editor)

    assert(!created_agent.nil?, "expected create flow to build a new managed agent")
    assert(created_agent.instance_variable_get(:@started),
           "expected 'Create and Run' to start the new agent immediately")
    assert(created_agent.agent == "claude", "expected selected harness to override the template default")
    assert(app.instance_variable_get(:@screen) == :agents, "expected create flow to switch to the agents screen")
    assert(app.instance_variable_get(:@selected)[:agents].zero?, "expected the newly created agent to be selected")
    sidebar = app.instance_variable_get(:@sidebar)
    assert(sidebar && sidebar[:kind] == :agent_chat, "expected create flow to open the agent chat form after saving")
    assert(!app.instance_variable_get(:@agent_chat_form).nil?, "expected an agent chat form instance after create")
    assert(!command.nil?, "expected create flow to schedule polling and focus the chat composer")
  end

  def assert_create_agent_keeps_project_tool_system_prompt
    app = HQ::App.new
    app.define_singleton_method(:save_agents!) { nil }

    projects = app.instance_variable_get(:@projects)
    project = projects.find { |item| item.key == "warehouse" } || projects.find(&:apps_enabled?)
    raise "expected an app project for agent prompt test" unless project

    app.instance_variable_set(:@screen, :projects)
    app.instance_variable_get(:@selected)[:projects] = projects.index(project) || 0
    app.send(:open_agent_editor_for_selected_project)

    form = app.instance_variable_get(:@agent_editor)
    form.prompt_input.value = "Maintenance for #{project.key}."
    form.instance_variable_set(:@field_index, form.create_button_index)

    app.send(:save_agent_editor)

    created_agent = app.instance_variable_get(:@agents).first
    system_messages = created_agent.messages.select { |message| message.role == "system" }
    assert(system_messages.length >= 2,
           "expected created agent to keep project context and template prompts as separate system messages")
    assert(system_messages[0].content.include?("Project:"),
           "expected first created-agent system prompt to include project context")
    assert(system_messages[0].content.include?("bin/tycho app deploy #{project.key}"),
           "expected first created-agent system prompt to include project deploy command")
    assert(system_messages[0].content.include?("Ensure to check the Last Action when performing HQ command."),
           "expected first created-agent system prompt to include last-action instruction")
    assert(system_messages[1].content == "Maintenance for #{project.key}.",
           "expected second created-agent system prompt to be the edited agent prompt")
  end

  def assert_create_and_run_raw_log_includes_project_tool_system_prompt
    app = HQ::App.new
    app.define_singleton_method(:save_agents!) { nil }

    projects = app.instance_variable_get(:@projects)
    project = projects.find { |item| item.key == "warehouse" } || projects.find(&:apps_enabled?)
    raise "expected an app project for raw log prompt test" unless project

    store = app.instance_variable_get(:@agent_store)
    original_create = store.method(:create_from_template)
    created_agent = nil
    store.define_singleton_method(:create_from_template) do |selected_project, template_key|
      created_agent = original_create.call(selected_project, template_key)
      created_agent.define_singleton_method(:build_command) do
        { command: [RbConfig.ruby, "-e", "exit 0"] }
      end
      created_agent
    end

    app.instance_variable_set(:@screen, :projects)
    app.instance_variable_get(:@selected)[:projects] = projects.index(project) || 0
    app.send(:open_agent_editor_for_selected_project)

    form = app.instance_variable_get(:@agent_editor)
    form.prompt_input.value = "Maintenance for #{project.key}."
    form.instance_variable_set(:@field_index, form.create_and_run_button_index)

    begin
      app.send(:save_agent_editor)

      raw_log = File.read(created_agent.raw_log_path)
      assert(raw_log.include?("prompt=SYSTEM:\nProject:"),
             "expected raw log prompt to start with project context system prompt")
      assert(raw_log.include?("bin/tycho app deploy #{project.key}"),
             "expected raw log prompt to include project deploy command")
      assert(raw_log.include?("SYSTEM:\nMaintenance for #{project.key}."),
             "expected raw log prompt to include edited agent system prompt after project context")
    ensure
      if created_agent
        FileUtils.rm_f(created_agent.raw_log_path)
        FileUtils.rm_f(created_agent.memory_path)
      end
    end
  end

  def assert_create_agent_without_run_opens_chat_but_does_not_start
    app = HQ::App.new
    app.define_singleton_method(:save_agents!) { nil }

    projects = app.instance_variable_get(:@projects)
    project = projects.find { |item| item.key == "warehouse" } || projects.first
    raise "expected at least one project for agent form test" unless project

    app.instance_variable_set(:@screen, :projects)
    app.instance_variable_get(:@selected)[:projects] = projects.index(project) || 0
    app.send(:open_agent_editor_for_selected_project)

    form = app.instance_variable_get(:@agent_editor)
    form.cycle_template(1)
    form.instance_variable_set(:@field_index, form.create_button_index)

    created_agent = nil
    store = app.instance_variable_get(:@agent_store)
    store.define_singleton_method(:create_from_template) do |selected_project, template_key|
      created_agent = HQ::ManagedAgent.new(
        key: "created-agent-no-run-test",
        name: "#{selected_project.name} created",
        project_key: selected_project.key,
        template_key: template_key,
        workspace: selected_project.path,
        prompt: "placeholder"
      )
      created_agent.define_singleton_method(:start!) do
        @started = true
      end
      created_agent
    end

    _, command = app.send(:save_agent_editor)

    assert(!created_agent.nil?, "expected create flow to build a new managed agent")
    assert(created_agent.instance_variable_get(:@started).nil?,
           "expected 'Create Agent' button to not start the agent")
    sidebar = app.instance_variable_get(:@sidebar)
    assert(sidebar && sidebar[:kind] == :agent_chat, "expected chat form to open even when not running")
    assert(!app.instance_variable_get(:@agent_chat_form).nil?, "expected chat form instance")
    _ = command
  end

  def assert_clone_agent_uses_fresh_state_and_defaults_to_archive
    app = app_with_default_agent(width: 120, height: 30)
    app.define_singleton_method(:save_agents!) { nil }
    app.instance_variable_set(:@screen, :agents)

    old_agent = app.instance_variable_get(:@agents).first
    old_agent.instance_variable_set(:@session_id, "old-session")
    old_agent.instance_variable_set(:@session_bootstrapped, true)
    old_agent.instance_variable_set(:@started_at, Time.parse("2026-04-05 17:50:00"))
    old_agent.instance_variable_set(:@runs, [
                                      HQ::ManagedAgent::AgentRun.new(
                                        started_at: Time.parse("2026-04-05 17:50:00"),
                                        status: "succeeded"
                                      )
                                    ])
    FileUtils.mkdir_p(File.dirname(old_agent.raw_log_path))
    File.write(old_agent.raw_log_path, "old log\n")

    app.update(key_message("C"))

    confirm = app.instance_variable_get(:@clone_confirm)
    assert(!confirm.nil?, "expected clone flow to ask what to do with the old agent")
    assert(confirm.archive_old?, "expected clone prompt to default to archiving the old agent")

    new_agent = confirm.new_agent
    assert(new_agent.key != old_agent.key, "expected cloned agent to have a fresh key")
    assert(new_agent.name == old_agent.name, "expected cloned agent name to default to the source name")
    assert(new_agent.template_key == old_agent.template_key, "expected clone to copy template")
    assert(new_agent.workspace == old_agent.workspace, "expected clone to copy workspace")
    assert(new_agent.prompt == old_agent.prompt, "expected clone to copy prompt")
    assert(new_agent.sandbox_mode == old_agent.sandbox_mode, "expected clone to copy sandbox mode")
    assert(new_agent.agent == old_agent.agent, "expected clone to copy harness")
    assert(new_agent.runs.empty?, "expected cloned agent to start with no runs")
    assert(new_agent.started_at.nil?, "expected cloned agent to have no started time")
    assert(new_agent.finished_at.nil?, "expected cloned agent to have no finished time")
    assert(new_agent.session_id.to_s.empty?, "expected cloned agent to have no native session id")
    assert(!File.exist?(new_agent.raw_log_path), "expected cloned agent to have empty logs")

    app.send(:handle_clone_confirm, enter_message)

    agents = app.instance_variable_get(:@agents)
    assert(agents.include?(new_agent), "expected cloned agent to remain in the agent list")
    assert(!agents.include?(old_agent), "expected default clone confirmation to archive the old agent")
    assert(app.instance_variable_get(:@selected)[:agents] == agents.index(new_agent),
           "expected cloned agent to stay selected after archive")
    assert(app.instance_variable_get(:@sidebar)&.fetch(:kind, nil) == :agent_chat,
           "expected clone flow to open chat for the cloned agent")
    assert(app.instance_variable_get(:@agent_chat_form)&.agent == new_agent,
           "expected chat form to target the cloned agent")
    assert(Dir.glob(File.join(HQ::AGENT_ARCHIVE_DIR, "*#{old_agent.key}", "*.raw.log")).any?,
           "expected old agent logs to be archived")
  end

  def assert_clone_agent_can_keep_old_agent
    app = app_with_default_agent(width: 120, height: 30)
    app.define_singleton_method(:save_agents!) { nil }
    app.instance_variable_set(:@screen, :agents)

    old_agent = app.instance_variable_get(:@agents).first
    app.update(key_message("C"))
    confirm = app.instance_variable_get(:@clone_confirm)
    new_agent = confirm.new_agent

    app.send(:handle_clone_confirm, key_message("h"))
    assert(!confirm.archive_old?, "expected left/h to select keeping the old agent")
    app.send(:handle_clone_confirm, enter_message)

    agents = app.instance_variable_get(:@agents)
    assert(agents.include?(old_agent), "expected keep choice to leave the old agent in the list")
    assert(agents.include?(new_agent), "expected keep choice to leave the cloned agent in the list")
    assert(app.instance_variable_get(:@agent_chat_form)&.agent == new_agent,
           "expected keep choice to open chat for the cloned agent")
  end

  def assert_custom_claude_harness_builds_configured_command
    previous = HQ.custom_harnesses.values
    HQ.custom_harnesses = [
      HQ::HarnessConfig.new(
        key: "claude-wrapper",
        adapter: "claude",
        execution_command: ["/usr/local/bin/claude-wrapper", "--profile", "demo"]
      )
    ]
    agent = HQ::ManagedAgent.new(
      key: "custom-claude-agent-test",
      name: "custom Claude agent",
      project_key: "warehouse",
      template_key: "custom",
      workspace: "/Users/example/Code/warehouse",
      prompt: "Test custom Claude harness integration.",
      agent: "claude-wrapper"
    )

    command = agent.send(:build_command).fetch(:command)

    assert(command[0..2] == ["/usr/local/bin/claude-wrapper", "--profile", "demo"],
           "expected custom harness execution_command to prefix Claude invocation")
    assert(command.include?("--output-format"), "expected custom Claude harness to use structured Claude output")
    assert(command.include?("--json-schema"), "expected custom Claude harness to use the Claude schema path")
  ensure
    HQ.custom_harnesses = previous if defined?(previous)
  end

  def assert_claude_schema_is_compact_json
    agent = HQ::ManagedAgent.new(
      key: "claude-schema-test",
      name: "claude schema",
      project_key: "warehouse",
      template_key: "custom",
      workspace: "/Users/example/Code/warehouse",
      prompt: "Test schema compaction.",
      agent: "claude"
    )

    command = agent.send(:build_command).fetch(:command)
    schema = command[command.index("--json-schema") + 1]
    assert(!schema.include?("\n"), "expected compact json schema without newlines")
    parsed = JSON.parse(schema)
    attachment_items = parsed.dig("properties", "attachments", "items")
    attachment_type = attachment_items.dig("properties", "type")
    assert(attachment_type["enum"] == %w[file link],
           "expected structured output schema to expose file/link attachment types")
    assert(attachment_items["required"].include?("path"),
           "expected attachment schema to include a nullable path")
    assert(attachment_items["required"].include?("url"),
           "expected attachment schema to include a nullable URL")
    assert(!schema.include?('"oneOf"'), "expected structured output schema to avoid unsupported oneOf")
    assert(parsed["required"].include?("attachments"), "expected structured output schema to require attachments")
  end

  def assert_agent_session_id_persists_and_renders
    session_id = "11111111-1111-4111-8111-111111111111"
    agent = HQ::ManagedAgent.new(
      key: "session-agent-test",
      name: "session agent",
      project_key: "warehouse",
      template_key: "custom",
      workspace: "/Users/example/Code/warehouse",
      prompt: "Test session persistence.",
      agent: "claude",
      session_id:
    )

    restored = HQ::ManagedAgent.from_hash(agent.to_hash)
    assert(restored.session_id == session_id, "expected managed-agent session_id to round-trip through AgentStore data")

    app = app_with_default_agent(width: 120, height: 30)
    app.instance_variable_set(:@agents, [restored])
    app.instance_variable_get(:@selected)[:agents] = 0
    detail = app.send(:agent_detail_text)
    assert(detail.include?(session_id), "expected agent detail to show native session id")
  end

  def assert_claude_resume_uses_incremental_prompt
    Dir.mktmpdir do |dir|
      session_id = "22222222-2222-4222-8222-222222222222"
      finished_at = Time.parse("2026-04-08 17:40:00 +0700")
      run = HQ::ManagedAgent::AgentRun.new(
        started_at: finished_at - 60,
        finished_at:,
        status: "succeeded",
        log_path: File.join(dir, "agent.raw.log")
      )
      agent = HQ::ManagedAgent.new(
        key: "claude-resume-test",
        name: "claude resume",
        project_key: "warehouse",
        template_key: "custom",
        workspace: dir,
        prompt: "Base system prompt.",
        agent: "claude",
        session_id:,
        runs: [run]
      )
      agent.add_user_message!("Use only this follow-up.")

      command = agent.send(:build_command).fetch(:command)
      assert(command.include?("--resume"), "expected Claude to resume known native session")
      assert(command[command.index("--resume") + 1] == session_id, "expected Claude resume to use persisted session id")
      assert(command.last.start_with?("Use only this follow-up."),
             "expected resumed run to start with latest user message")
      assert(command.last.end_with?(HQ::ManagedAgent::FINAL_OUTPUT_CHECKLIST),
             "expected resumed run to append final output checklist")
      assert(!command.last.include?("Base system prompt."),
             "expected resumed run to avoid replaying full memory prompt")
    end
  end

  def assert_codex_session_id_is_captured_from_log
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "agent.raw.log")
      started_at = Time.parse("2026-04-08 17:48:40 +0700")
      File.write(log_path, <<~LOG)
        === [2026-04-08 17:48:40] start ===
        {"type":"thread.started","thread_id":"019db38a-99ca-7109-9f26-be991d1a4708"}
        {"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}
      LOG
      agent = HQ::ManagedAgent.new(
        key: "codex-session-test",
        name: "codex session",
        project_key: "warehouse",
        template_key: "custom",
        workspace: dir,
        prompt: "Test Codex session capture.",
        agent: "codex",
        started_at:,
        log_path:
      )

      agent.send(:capture_session_id!)
      assert(agent.session_id == "019db38a-99ca-7109-9f26-be991d1a4708",
             "expected Codex thread id to persist as session id")
    end
  end

  def assert_failed_claude_run_does_not_reuse_previous_structured_result
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "agent.log")
      started_at = Time.parse("2026-04-08 17:48:40 +0700")
      File.write(log_path, <<~LOG)
        === [2026-04-08 17:40:00] start ===
        {"type":"result","structured_output":{"status":"success","summary":"old summary"}}

        === [2026-04-08 17:48:40] start ===
        error: unknown option '--json-schema'
      LOG

      run = HQ::ManagedAgent::AgentRun.new(started_at:, status: "running", log_path:)
      agent = HQ::ManagedAgent.new(
        key: "claude-log-reuse-test",
        name: "claude log reuse",
        project_key: "warehouse",
        template_key: "custom",
        workspace: dir,
        prompt: "Test stale result handling.",
        agent: "claude",
        started_at:,
        log_path:,
        runs: [run]
      )

      payload = agent.send(:read_structured_result_payload_from_log)
      assert(payload.nil?, "expected current failed run to ignore previous structured result lines")
    end
  end

  def assert_codex_agent_message_unwraps_structured_payload
    structured_text = {
      "status" => "input_required",
      "summary" => "I need the implementation context before writing the markdown plan.",
      "inquiry" => {
        "message" => "Please provide the implementation context.",
        "fields" => [{ "key" => "what", "label" => "What", "input_type" => "multiline", "required" => true }]
      }
    }.to_json

    lines = [
      %({"type":"thread.started","thread_id":"abc"}),
      %({"type":"turn.started"}),
      %({"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":#{structured_text.to_json}}}),
      %({"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}})
    ]

    conversation, = HQ::Parser.parse_stream(lines, agent_type: "codex")
    assistant = conversation.find { |entry| entry.role == "assistant" }

    assert(assistant, "expected assistant conversation entry from structured agent_message")
    assert(assistant.content == "I need the implementation context before writing the markdown plan.",
           "expected assistant message to unwrap to the structured summary, got #{assistant.content.inspect}")
    assert(!assistant.content.include?("\"inquiry\""),
           "expected unwrapped assistant message to omit the raw JSON payload")

    inquiry_only = { "inquiry" => { "message" => "What should we do?" } }.to_json
    inquiry_lines = [
      %({"type":"item.completed","item":{"type":"agent_message","text":#{inquiry_only.to_json}}})
    ]
    inquiry_conversation, = HQ::Parser.parse_stream(inquiry_lines, agent_type: "codex")
    inquiry_assistant = inquiry_conversation.find { |entry| entry.role == "assistant" }
    assert(inquiry_assistant && inquiry_assistant.content == "What should we do?",
           "expected assistant message to fall back to inquiry.message when summary is empty")

    plain_text = "Here is a plain response."
    plain_lines = [
      %({"type":"item.completed","item":{"type":"agent_message","text":#{plain_text.to_json}}})
    ]
    plain_conversation, = HQ::Parser.parse_stream(plain_lines, agent_type: "codex")
    plain_assistant = plain_conversation.find { |entry| entry.role == "assistant" }
    assert(plain_assistant && plain_assistant.content == plain_text,
           "expected non-structured assistant messages to render verbatim")
  end

  # Exercises bin/worker --type glamour end-to-end at a few widths. The worker
  # is the only reliable way to render markdown from inside the Bubbletea
  # process (see docs/research/glamour_bubbletea.md), so any regression in
  # its output — styling dropped, document padding returning, list wrap
  # losing its hanging indent — needs to fail loudly here.
  def assert_glamour_worker_renders_sample_markdown
    require "rbconfig"

    sample = <<~'MD'
      Nothing to continue — the split is complete. Both draft PRs are up:

      - **#47665** (backend pipeline): https://github.com/example/demo-web/pull/47665
      - **#47666** (static admin UI): https://github.com/example/demo-web/pull/47666

      What would you like to do next?
    MD

    worker = File.expand_path("../bin/worker", __dir__)
    ansi = /\e\[[0-9;]*m/

    [72, 100, 120].each do |width|
      rendered = IO.popen([RbConfig.ruby, worker, "--type", "glamour"], "r+") do |io|
        io.write("#{width}\n")
        io.write(sample)
        io.close_write
        io.read
      end

      assert(rendered && !rendered.empty?,
             "expected glamour worker to produce output at width=#{width}")
      assert(rendered.include?("\e["),
             "expected ANSI styling at width=#{width} (style detection must force dark, not auto)")

      lines = rendered.split("\n", -1)
      assert(!lines.first.to_s.strip.empty?,
             "expected leading document padding stripped at width=#{width}, got #{lines.first.inspect}")
      assert(!lines.last.to_s.strip.empty?,
             "expected trailing document padding stripped at width=#{width}, got #{lines.last.inspect}")

      left_indents = lines.reject { |line| line.gsub(ansi, "").strip.empty? }
                          .map { |line| line.gsub(ansi, "")[/\A */].length }
      assert(left_indents.min.to_i.zero?,
             "expected at least one line flush to column 0 at width=#{width}, got min indent=#{left_indents.min}")

      bullet_index = lines.index { |line| line.gsub(ansi, "").match?(/\A[•\-\*]\s/) }
      assert(bullet_index, "expected rendered output to contain a bullet line at width=#{width}")

      continuation = nil
      lines[(bullet_index + 1)..].each do |line|
        stripped = line.gsub(ansi, "")
        break if stripped.strip.empty?
        next if stripped.match?(/\A[•\-\*]\s/)

        continuation = line
        break
      end
      if continuation
        leading = continuation.gsub(ansi, "")[/\A */].length
        assert(leading >= 2,
               "expected hanging indent >= 2 on list continuation at width=#{width}, got #{leading} (#{continuation.inspect})")
      end
    end
  end

  def render_main_screen(screen, width:, height:)
    app = app_with_default_agent(width:, height:)
    app.instance_variable_set(:@screen, screen)
    app.view
  end

  def app_with_default_agent(width:, height:)
    app = HQ::App.new
    app.instance_variable_set(:@latest_kamal, "2.11.0")
    app.instance_variable_set(:@latest_rails, "8.1.3")
    if app.instance_variable_get(:@agents).empty?
      project = app.instance_variable_get(:@projects).find do |item|
        item.key == "warehouse"
      end || app.instance_variable_get(:@projects).first
      if project
        agent = HQ::ManagedAgent.new(
          key: "warehouse-agent-fixture",
          name: "warehouse custom",
          project_key: project.key,
          template_key: "custom",
          workspace: project.path,
          prompt: "Test",
          created_at: Time.parse("2026-04-05 17:49:16"),
          finished_at: Time.parse("2026-04-05 17:56:00"),
          last_exit_code: 0
        )
        app.instance_variable_set(:@agents, [agent])
        app.instance_variable_get(:@selected)[:agents] = 0
      end
    end
    app.send(:apply_window_size, width, height)
    app
  end

  def render_chat_screen(width:, height:, prompt: nil)
    app = build_chat_app(width:, height:, prompt:)
    app.view
  end

  def render_agent_editor(width:, height:)
    app = HQ::App.new
    projects = app.instance_variable_get(:@projects)
    project = projects.find { |item| item.key == "warehouse" } || projects.first
    raise "expected at least one project for agent form rendering test" unless project

    app.instance_variable_set(:@screen, :projects)
    app.instance_variable_get(:@selected)[:projects] = projects.index(project) || 0
    app.send(:apply_window_size, width, height)
    app.send(:open_agent_editor_for_selected_project)
    app.view
  end

  def live_tool_run_lines(project_path = "/tmp/hq-test-project")
    started_at = Time.parse("2026-04-05 17:55:00")
    assistant_event = {
      "type" => "assistant",
      "message" => {
        "role" => "assistant",
        "content" => [
          {
            "type" => "tool_use",
            "id" => "toolu_live_bash",
            "name" => "Bash",
            "input" => {
              "command" => 'curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/login',
              "description" => "Check login page"
            }
          }
        ]
      }
    }
    result_event = {
      "type" => "user",
      "message" => {
        "role" => "user",
        "content" => [
          {
            "tool_use_id" => "toolu_live_bash",
            "type" => "tool_result",
            "content" => "200",
            "is_error" => false
          }
        ]
      }
    }

    [
      "=== [#{started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ===",
      "workspace=#{project_path}",
      "prompt=Test",
      "",
      JSON.generate(assistant_event),
      JSON.generate(result_event)
    ]
  end

  def render_running_chat_screen(width:, height:)
    build_running_chat_app(width:, height:).view
  end

  def build_running_chat_app(width:, height:)
    app = HQ::App.new
    project = app.instance_variable_get(:@projects).find do |item|
      item.key == "warehouse"
    end || app.instance_variable_get(:@projects).first
    raise "expected at least one project for chat rendering test" unless project

    started_at = Time.parse("2026-04-05 17:55:00")
    log_path = File.join(Dir.mktmpdir, "running-agent.log")
    File.write(log_path, live_tool_run_lines(project.path).join("\n"))

    agent = HQ::ManagedAgent.new(
      key: "warehouse-agent-running",
      name: "warehouse custom",
      project_key: project.key,
      template_key: "custom",
      workspace: project.path,
      prompt: "Test",
      agent: "claude",
      created_at: Time.parse("2026-04-05 17:49:16"),
      started_at: started_at,
      pid: Process.pid,
      last_exit_code: nil,
      log_path: log_path,
      runs: [
        HQ::ManagedAgent::AgentRun.new(
          started_at: started_at,
          status: "running"
        )
      ],
      messages: [
        HQ::ManagedAgent::AgentMessage.new(role: "system", content: "Test",
                                           created_at: Time.parse("2026-04-05 17:49:16")),
        HQ::ManagedAgent::AgentMessage.new(role: "assistant", content: "tokens used 2.131 Test received.",
                                           created_at: Time.parse("2026-04-05 17:50:00")),
        HQ::ManagedAgent::AgentMessage.new(role: "user", content: "Please verify this while it runs.",
                                           created_at: started_at + 5)
      ]
    )

    app.instance_variable_set(:@agents, [agent])
    app.instance_variable_set(:@screen, :agents)
    app.instance_variable_get(:@selected)[:agents] = 0
    app.send(:apply_window_size, width, height)
    app.instance_variable_set(:@sidebar, { kind: :agent_chat })
    app.instance_variable_set(:@agent_chat_form,
                              HQ::UI::AgentChatForm.new(agent, width: app.send(:sidebar_component_width),
                                                               body_height: app.send(:sidebar_component_body_height)))
    app.send(:sync_agent_chat_workspace!)
    app
  end

  def render_input_required_chat_screen(width:, height:)
    app = build_input_required_chat_app(width:, height:)
    app.view
  end

  def assert(condition, message)
    raise message unless condition
  end

  def executable_available_for_test?(command)
    command = command.to_s
    if command.include?(File::SEPARATOR)
      return File.file?(command) && File.executable?(command)
    end

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
      path = File.join(dir, command)
      File.file?(path) && File.executable?(path)
    end
  end

  def build_chat_app(width: 120, height: 30, prompt: nil)
    app = HQ::App.new
    project = app.instance_variable_get(:@projects).find do |item|
      item.key == "warehouse"
    end || app.instance_variable_get(:@projects).first
    raise "expected at least one project for chat rendering test" unless project

    started_at = Time.parse("2026-04-05 17:55:00")
    log_path = File.join(Dir.mktmpdir, "chat-agent.raw.log")
    File.write(log_path, <<~LOG)
      === [#{started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ===
      workspace=#{project.path}
      prompt=SYSTEM:
      Test
      USER:
      How about this test?
      A:
      tokens used 12.733 That one came through too.

    LOG

    agent = HQ::ManagedAgent.new(
      key: "warehouse-agent-test",
      name: "warehouse custom",
      project_key: project.key,
      template_key: "custom",
      workspace: project.path,
      prompt: "Test",
      agent: "claude",
      log_path: log_path,
      created_at: Time.parse("2026-04-05 17:49:16"),
      started_at: started_at,
      finished_at: Time.parse("2026-04-05 17:56:00"),
      last_exit_code: 0,
      runs: [
        HQ::ManagedAgent::AgentRun.new(
          started_at: started_at,
          finished_at: Time.parse("2026-04-05 17:56:00"),
          exit_code: 0,
          status: "succeeded"
        )
      ],
      messages: [
        HQ::ManagedAgent::AgentMessage.new(role: "system", content: "Test",
                                           created_at: Time.parse("2026-04-05 17:49:16")),
        HQ::ManagedAgent::AgentMessage.new(role: "user", content: "How about this test?",
                                           created_at: Time.parse("2026-04-05 17:51:00"))
      ]
    )
    agent.summary = "tokens used 12.733 That one came through too."

    app.instance_variable_set(:@agents, [agent])
    app.instance_variable_set(:@screen, :agents)
    app.instance_variable_get(:@selected)[:agents] = 0
    app.send(:apply_window_size, width, height)
    app.instance_variable_set(:@sidebar, { kind: :agent_chat })
    app.instance_variable_set(:@agent_chat_form,
                              HQ::UI::AgentChatForm.new(agent, width: app.send(:sidebar_component_width),
                                                               body_height: app.send(:sidebar_component_body_height)))
    app.instance_variable_get(:@agent_chat_form).composer.value = prompt if prompt
    app.send(:sync_agent_chat_workspace!)
    app
  end

  def build_multi_field_inquiry_chat_app(width: 120, height: 30)
    fixture_path = File.expand_path("fixtures/agents/multi_field_inquiry_result.json", __dir__)
    structured_result = JSON.parse(File.read(fixture_path))

    app = HQ::App.new
    project = app.instance_variable_get(:@projects).find do |item|
      item.key == "warehouse"
    end || app.instance_variable_get(:@projects).first
    raise "expected at least one project for multi-field inquiry test" unless project

    started_at = Time.parse("2026-04-12 16:15:54")
    finished_at = Time.parse("2026-04-12 16:16:20")
    log_path = File.join(Dir.mktmpdir, "multi-field-inquiry.raw.log")

    run = HQ::ManagedAgent::AgentRun.new(
      started_at: started_at,
      finished_at: finished_at,
      exit_code: 0,
      status: "succeeded",
      log_path: log_path
    )

    agent = HQ::ManagedAgent.new(
      key: "warehouse-agent-multi-inquiry",
      name: "warehouse multi inquiry",
      project_key: project.key,
      template_key: "custom",
      workspace: project.path,
      prompt: "Return multiple inquiries with Y/N and multiple-choice questions.",
      agent: "claude",
      log_path: log_path,
      created_at: Time.parse("2026-04-12 16:15:00"),
      started_at: started_at,
      finished_at: finished_at,
      last_exit_code: 0,
      runs: [run],
      messages: [
        HQ::ManagedAgent::AgentMessage.new(role: "system",
                                           content: "Return multiple inquiries with Y/N and multiple-choice questions.", created_at: Time.parse("2026-04-12 16:15:00"))
      ]
    )
    agent.structured_result = structured_result
    agent.summary = structured_result["summary"]

    app.instance_variable_set(:@agents, [agent])
    app.instance_variable_set(:@screen, :agents)
    app.instance_variable_get(:@selected)[:agents] = 0
    app.send(:apply_window_size, width, height)
    app.instance_variable_set(:@sidebar, { kind: :agent_chat })
    app.instance_variable_set(:@agent_chat_form,
                              HQ::UI::AgentChatForm.new(agent, width: app.send(:sidebar_component_width),
                                                               body_height: app.send(:sidebar_component_body_height)))
    app.send(:sync_agent_chat_workspace!)
    app
  end

  def build_multi_select_inquiry_chat_app(width: 120, height: 30)
    fixture_path = File.expand_path("fixtures/agents/multi_select_inquiry_result.json", __dir__)
    structured_result = JSON.parse(File.read(fixture_path))

    app = HQ::App.new
    project = app.instance_variable_get(:@projects).find do |item|
      item.key == "warehouse"
    end || app.instance_variable_get(:@projects).first
    raise "expected at least one project for multi-select inquiry test" unless project

    started_at = Time.parse("2026-04-21 08:47:17")
    finished_at = Time.parse("2026-04-21 08:47:40")
    log_path = File.join(Dir.mktmpdir, "multi-select-inquiry.raw.log")

    run = HQ::ManagedAgent::AgentRun.new(
      started_at: started_at,
      finished_at: finished_at,
      exit_code: 0,
      status: "succeeded",
      log_path: log_path
    )

    agent = HQ::ManagedAgent.new(
      key: "warehouse-agent-banter-inquiry",
      name: "warehouse banter inquiry",
      project_key: project.key,
      template_key: "custom",
      workspace: project.path,
      prompt: "Collect banter picks before editing the beat sheet.",
      agent: "claude",
      log_path: log_path,
      created_at: Time.parse("2026-04-21 08:47:00"),
      started_at: started_at,
      finished_at: finished_at,
      last_exit_code: 0,
      runs: [run],
      messages: [
        HQ::ManagedAgent::AgentMessage.new(role: "system",
                                           content: "Collect banter picks before editing the beat sheet.", created_at: Time.parse("2026-04-21 08:47:00"))
      ]
    )
    agent.structured_result = structured_result
    agent.summary = structured_result["summary"]

    app.instance_variable_set(:@agents, [agent])
    app.instance_variable_set(:@screen, :agents)
    app.instance_variable_get(:@selected)[:agents] = 0
    app.send(:apply_window_size, width, height)
    app.instance_variable_set(:@sidebar, { kind: :agent_chat })
    app.instance_variable_set(:@agent_chat_form,
                              HQ::UI::AgentChatForm.new(agent, width: app.send(:sidebar_component_width),
                                                               body_height: app.send(:sidebar_component_body_height)))
    app.send(:sync_agent_chat_workspace!)
    app
  end

  def build_input_required_chat_app(width: 120, height: 30)
    app = HQ::App.new
    project = app.instance_variable_get(:@projects).find do |item|
      item.key == "warehouse"
    end || app.instance_variable_get(:@projects).first
    raise "expected at least one project for chat rendering test" unless project

    log_path = File.join(Dir.mktmpdir, "input-required.raw.log")

    run = HQ::ManagedAgent::AgentRun.new(
      started_at: Time.parse("2026-04-05 17:55:00"),
      finished_at: Time.parse("2026-04-05 17:56:00"),
      exit_code: 0,
      status: "succeeded",
      log_path: log_path
    )
    structured_result = {
      "status" => "input_required",
      "summary" => "Waiting for your reflection before drafting the journal entry.",
      "inquiry" => {
        "message" => "Please share a short reflection for today's journal.",
        "fields" => [
          {
            "key" => "reflection",
            "label" => "Short Reflection",
            "description" => "A few sentences about what stood out today.",
            "input_type" => "multiline",
            "required" => true,
            "options" => nil
          },
          {
            "key" => "context",
            "label" => "Context",
            "description" => "Any constraints or context to keep in mind.",
            "input_type" => "text",
            "required" => false,
            "options" => nil
          }
        ]
      }
    }

    agent = HQ::ManagedAgent.new(
      key: "journal-helper-agent",
      name: "journal helper",
      project_key: project.key,
      template_key: "custom",
      workspace: project.path,
      prompt: "Help with journaling.",
      log_path: log_path,
      created_at: Time.parse("2026-04-05 17:49:16"),
      finished_at: Time.parse("2026-04-05 17:56:00"),
      last_exit_code: 0,
      runs: [run],
      messages: [
        HQ::ManagedAgent::AgentMessage.new(role: "system", content: "Help with journaling.",
                                           created_at: Time.parse("2026-04-05 17:49:16"))
      ]
    )
    agent.structured_result = structured_result
    agent.summary = structured_result["summary"]

    app.instance_variable_set(:@agents, [agent])
    app.instance_variable_set(:@screen, :agents)
    app.instance_variable_get(:@selected)[:agents] = 0
    app.send(:apply_window_size, width, height)
    app.instance_variable_set(:@sidebar, { kind: :agent_chat })
    app.instance_variable_set(:@agent_chat_form,
                              HQ::UI::AgentChatForm.new(agent, width: app.send(:sidebar_component_width),
                                                               body_height: app.send(:sidebar_component_body_height)))
    app.send(:sync_agent_chat_workspace!)
    app
  end

  def key_message(char)
    Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RUNES, runes: [char.ord])
  end

  def open_omnisearch(app)
    app.update(Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_SPACE))
    app.update(HQ::OmnisearchIndexMessage.new)
  end

  def enter_message
    Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_ENTER)
  end

  def ctrl_g_message
    Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_CTRL_G)
  end

  def ctrl_a_message
    Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_CTRL_A)
  end

  def ctrl_t_message
    Bubbletea::KeyMessage.new(key_type: 20)
  end

  def paste_key_message(text)
    Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RUNES, runes: text.codepoints)
  end

  def visible_width(text)
    Bubbles::ANSI.strip(text.to_s).gsub(/\e\]8;[^\e]*\e\\/, "").length
  end
end

RenderingTest.run! if $PROGRAM_NAME == __FILE__
