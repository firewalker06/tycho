# frozen_string_literal: true

require "bubbletea"
require "bubbles"
require "lipgloss"
require "shellwords"
require "open3"
require "fileutils"

require_relative "bubbletea_input"
require_relative "registry"
require_relative "domain/constants"
require_relative "domain/file_store"
require_relative "domain/log_paths"
require_relative "domain/project"
require_relative "domain/project_archiver"
require_relative "domain/managed_agent"
require_relative "domain/agent_store"
require_relative "domain/visibility"
require_relative "domain/scheduler"
require_relative "domain/skill_discovery"
require_relative "domain/onboarding"
require_relative "ui/components/chat_composer"
require_relative "ui/components/inquiry_form"
require_relative "ui/components/agent_chat_form"
require_relative "ui/components/agent_editor"
require_relative "ui/components/delete_agent_confirm"
require_relative "ui/components/clone_agent_confirm"
require_relative "ui/components/project_archive_confirm"
require_relative "ui/components/project_editor"
require_relative "ui/components/omnisearch"
require_relative "ui/components/log_viewer"
require_relative "ui/components/text_paste"
require_relative "ui/rendering"

module HQ
  class TickMessage < Bubbletea::Message; end
  class ActionPollMessage < Bubbletea::Message; end
  class ProgressTickMessage < Bubbletea::Message; end
  class ChatRenderPollMessage < Bubbletea::Message; end
  class OmnisearchIndexMessage < Bubbletea::Message; end

  class << self
    attr_accessor :restart_requested

    def log_boot_step(label)
      return unless defined?(HQ_BOOT_START)

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - HQ_BOOT_START
      HQ.logger.info("Boot") { format("%7.3fs  %s", elapsed, label) }
    end
  end

  class App
    include Bubbletea::Model
    include UI::Rendering

    SCREENS = %i[agents projects schedules].freeze

    def initialize
      HQ.logger.info("App") { "Starting HQ" }
      HQ.log_boot_step("App#initialize enter")
      @config_error = nil
      @last_refresh = nil
      @loading = false
      @screen = :agents
      @selected = Hash.new(0)
      @spinner = Bubbles::Spinner.new(spinner: Bubbles::Spinners::DOT)
      @progress = Bubbles::Progress.new(width: 30, gradient: %w[#7571F9 #5BC0EB])
      @progress.show_percentage = true
      @progress_mutex = Mutex.new
      @progress_done = 0
      @progress_total = 0
      @progress_activity = []
      @progress_threads = []
      @sidebar_visible = true
      @viewing_detail = false
      @detail_viewport = nil
      @sidebar = nil
      @sidebar_viewport = nil
      @sidebar_content_proc = nil
      @confirming = nil
      @all_projects = []
      @projects = []
      @all_agents = []
      @agents = []
      @schedules = []
      @schedule_daemon = {}
      @schedule_error = nil
      @schedule_action_message = nil
      @schedule_action_error = nil
      @known_agent_keys = []
      @agents_by_project = Hash.new { |hash, key| hash[key] = [] }
      @agent_editor = nil
      @agent_chat_form = nil
      @project_editor = nil
      @onboarding = false
      @onboarding_options = []
      @onboarding_selected = 0
      @onboarding_error = nil
      @omnisearch = nil
      @delete_confirm = nil
      @clone_confirm = nil
      @project_archive_confirm = nil
      @window_width = 120
      @window_height = 40
      HQ.hooks.reload!(projects: [])
      install_hooks_reload_trap!
      HQ.log_boot_step("hooks preloaded")
      load_registry!
      HQ.log_boot_step("registry loaded (#{@projects.length} projects)")
      reload_hooks!
      HQ.log_boot_step("hooks reloaded with projects")
      refresh_boot_metadata!
      HQ.log_boot_step("boot metadata loaded")
      @agent_store = AgentStore.new(@all_projects)
      load_agents!
      HQ.log_boot_step("agents loaded (#{@agents.length} agents)")
      load_schedules!
      HQ.log_boot_step("schedules loaded (#{@schedules.length} schedules)")
      sync_agent_chat_workspace!
      start_empty_config_onboarding!
      HQ.log_boot_step("App#initialize exit")
    end

    def init
      HQ.log_boot_step("App#init enter")
      _, spinner_cmd = @spinner.init
      cmds = [
        Bubbletea.enter_alt_screen,
        Bubbletea.tick(0.1) { TickMessage.new },
        spinner_cmd
      ]
      cmds << begin_refresh!
      cmds << schedule_action_poll
      HQ.log_boot_step("App#init exit")
      [self, Bubbletea.batch(*cmds.compact)]
    end

    def update(message)
      case message
      when Bubbles::Spinner::TickMessage
        @spinner, cmd = @spinner.update(message)
        sync_agent_chat_workspace! if @agent_chat_form&.agent&.running?
        return [self, cmd]
      when Bubbles::Progress::FrameMessage
        @progress, cmd = @progress.update(message)
        return [self, cmd]
      when ProgressTickMessage
        return handle_progress_tick
      when ChatRenderPollMessage
        return handle_chat_render_poll
      when OmnisearchIndexMessage
        return handle_omnisearch_index
      end

      return handle_omnisearch(message) if omnisearch_open? && message.is_a?(Bubbletea::KeyMessage)
      return open_terminal_for_selected if message.is_a?(Bubbletea::KeyMessage) && message.to_s == "ctrl+g"
      return handle_onboarding(message) if @onboarding && message.is_a?(Bubbletea::KeyMessage)

      return handle_delete_confirm(message) if @delete_confirm
      return handle_clone_confirm(message) if @clone_confirm
      return handle_project_archive_confirm(message) if @project_archive_confirm
      if @confirming == :rebuild_memory && message.is_a?(Bubbletea::KeyMessage)
        return handle_confirm(message.to_s)
      end
      return handle_detail_overlay(message) if @viewing_detail
      return handle_sidebar(message) if overlay_open?

      case message
      when Bubbletea::WindowSizeMessage
        apply_window_size(message.width, message.height)
        [self, nil]
      when TickMessage
        cmds = [schedule_refresh, schedule_action_poll]
        cmds << begin_refresh! unless refreshing?
        [self, Bubbletea.batch(*cmds.compact)]
      when ActionPollMessage
        poll_agents!
        refresh_omnisearch_index! if omnisearch_open?
        cmds = [schedule_action_poll]
        cmds << begin_refresh! if @loading && !refreshing?
        [self, Bubbletea.batch(*cmds.compact)]
      when Bubbletea::KeyMessage
        handle_key(message.to_s)
      else
        [self, nil]
      end
    end

    def view
      unless @first_view_logged
        HQ.log_boot_step("App#view first call")
        @first_view_logged = true
      end
      return delete_confirm_view if @delete_confirm
      return clone_confirm_view if @clone_confirm
      return project_archive_confirm_view if @project_archive_confirm
      return config_error_view if @config_error
      return onboarding_view if @onboarding
      return loading_screen_view if @loading && @last_refresh.nil?
      return detail_full_view if @viewing_detail

      main_screen_view
    end

    private

    def handle_key(key)
      return [self, Bubbletea.quit] if key == "ctrl+c"

      return handle_confirm(key) if @confirming

      if key == "q"
        @confirming = :quit
        return [self, nil]
      end

      case key
      when "tab", "right"
        switch_screen(1)
      when "shift+tab", "left", "H"
        switch_screen(-1)
      when "1" then select_screen(:agents)
      when "2" then select_screen(:projects)
      when "3" then select_screen(:schedules)
      when "r"
        @loading = true
        [self, begin_refresh!]
      when "j", "down"
        move_selection(1)
      when "k", "up"
        move_selection(-1)
      when "n"
        open_agent_editor_for_selected_project
      when "N"
        open_project_editor
      when "e"
        open_agent_editor_for_selected_agent
      when "c", "enter"
        open_agent_chat_form
      when "C"
        clone_selected_agent
      when "s"
        @screen == :schedules ? run_selected_schedule : start_selected_agent
      when "p"
        toggle_selected_schedule
      when "R"
        rerun_selected_agent
      when "t"
        stop_selected_agent
      when "x"
        @screen == :projects ? maybe_confirm_project_archive : delete_selected_agent
      when "l"
        open_context_log
      when "L"
        open_raw_log
      when "v"
        open_detail_view
      when "ctrl+g"
        open_terminal_for_selected
      when "ctrl+t"
        open_interactive_terminal_for_selected_agent
      when "ctrl+b"
        toggle_sidebar
      when "ctrl+r"
        @confirming = :restart
        [self, nil]
      when "space"
        open_omnisearch
      else
        [self, nil]
      end
    end

    def toggle_sidebar
      @sidebar_visible = !@sidebar_visible
      [self, nil]
    end

    def handle_onboarding(message)
      case message.to_s
      when "ctrl+c"
        [self, Bubbletea.quit]
      when "q"
        [self, Bubbletea.quit]
      when "j", "down", "tab", "right"
        move_onboarding_selection(1)
      when "k", "up", "shift+tab", "left"
        move_onboarding_selection(-1)
      when "enter", " "
        run_onboarding_option
      when "w"
        run_onboarding_option(:welcome)
      when "c"
        run_onboarding_option(:current_directory)
      when "a", "n"
        run_onboarding_option(:add_project)
      else
        [self, nil]
      end
    end

    def move_onboarding_selection(delta)
      return [self, nil] if @onboarding_options.empty?

      @onboarding_selected = (@onboarding_selected + delta) % @onboarding_options.length
      [self, nil]
    end

    def run_onboarding_option(key = nil)
      option = if key
                 @onboarding_options.find { |item| item[:key] == key }
               else
                 @onboarding_options[@onboarding_selected]
               end
      return [self, nil] unless option

      case option[:key]
      when :welcome
        create_onboarding_welcome_project
      when :current_directory
        create_onboarding_current_directory_project(option[:candidate])
      when :add_project
        @onboarding = false
        @screen = :projects
        open_project_editor(force: true)
      else
        [self, nil]
      end
    end

    def create_onboarding_welcome_project
      attrs = Onboarding.welcome_project_attrs(agent: HQ.harness_keys.first)
      create_onboarding_project(attrs, success_message: "Created welcome sandbox")
    end

    def create_onboarding_current_directory_project(candidate)
      return [self, nil] unless candidate

      attrs = {
        key: candidate[:key],
        name: candidate[:name],
        path: candidate[:path],
        agent: HQ.harness_keys.first
      }
      create_onboarding_project(attrs, success_message: "Created project from current directory")
    end

    def create_onboarding_project(attrs, success_message:)
      @registry.add_project!(attrs)
      load_registry!
      reload_hooks!
      @agent_store = AgentStore.new(@all_projects)
      load_agents!
      @selected[:projects] = @projects.index { |project| project.key == attrs[:key] } || 0
      @screen = :projects
      @onboarding = false
      @onboarding_error = nil
      close_sidebar!
      HQ.logger.info("Project") { "#{success_message}: #{attrs[:key]}" }
      refresh_project_async!(attrs[:key])
      [self, nil]
    rescue ConfigError => e
      @onboarding_error = e.message
      [self, nil]
    rescue StandardError => e
      @onboarding_error = "Could not create project: #{e.message}"
      [self, nil]
    end

    def load_registry!
      retried_missing_config = false
      begin
        @registry = Registry.new
        @all_projects = @registry.projects.map { |config| Project.new(config) }
        apply_project_visibility!
        @registry_mtime = File.mtime(@registry.path) if File.exist?(@registry.path)
        @config_error = nil
      rescue ConfigError => e
        missing_config_path = missing_config_path_from_error(e)
        if missing_config_path && !retried_missing_config && create_onboarding_config_file!(missing_config_path)
          retried_missing_config = true
          retry
        end

        HQ.logger.error("Config") { e.message }
        @config_error = e.message
        @all_projects = []
        @projects = []
        @all_agents = []
        @agents = []
      end
    end

    def missing_config_path_from_error(error)
      prefix = "Config file not found: "
      message = error.message.to_s
      return nil unless message.start_with?(prefix)

      message.delete_prefix(prefix).strip
    end

    def create_onboarding_config_file!(path)
      return false if path.to_s.empty?
      return true if File.exist?(path)

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "---\nprojects: []\n")
      HQ.logger.info("Config") { "Created empty project config at #{path}" }
      true
    rescue StandardError => e
      HQ.logger.warn("Config") do
        "Could not create empty project config at #{path}: #{e.class}: #{e.message}"
      end
      false
    end

    def start_empty_config_onboarding!
      return if @config_error
      return unless @all_projects.empty?

      close_sidebar!
      @onboarding = true
      @onboarding_error = nil
      @onboarding_selected = 0
      refresh_onboarding_options!
      @screen = :projects
    end

    def refresh_onboarding_options!
      options = [
        {
          key: :welcome,
          title: "Create Welcome Sandbox",
          detail: "Safe local workspace at #{Onboarding.welcome_workspace_path}"
        }
      ]

      if (candidate = Onboarding.current_directory_candidate)
        options << {
          key: :current_directory,
          title: "Use Current Directory",
          detail: "#{candidate[:kind]} at #{candidate[:path]}",
          candidate: candidate
        }
      end

      options << {
        key: :add_project,
        title: "Add Local Project",
        detail: "Choose a project folder for managed agents"
      }
      @onboarding_options = options
      @onboarding_selected = clamp_selection(@onboarding_selected, @onboarding_options.length)
    end

    def reload_registry_if_changed!
      return unless @registry
      return unless File.exist?(@registry.path)

      current = File.mtime(@registry.path)
      return if @registry_mtime && current <= @registry_mtime

      HQ.logger.info("Config") { "Detected change in #{@registry.path}, reloading" }
      previous = @all_projects.each_with_object({}) { |p, h| h[p.key] = p }
      @registry = Registry.new
      @registry_mtime = current
      @all_projects = @registry.projects.map do |config|
        prior = previous[config.key]
        project = Project.new(config)
        if prior
          project.instance_variable_set(:@commit_hash, prior.commit_hash)
          project.instance_variable_set(:@branch, prior.branch)
          project.instance_variable_set(:@dirty_files, prior.dirty_files)
        end
        project
      end
      apply_project_visibility!
      @agent_store = AgentStore.new(@all_projects) if @agent_store
      apply_agent_visibility!
      rebuild_agent_index!
      load_schedules!
      reload_hooks!
      HQ.hooks.publish("config.reloaded",
                       path: @registry.path,
                       project_count: @projects.length)
    rescue ConfigError => e
      HQ.logger.warn("Config") { "Reload skipped: #{e.message}" }
    end

    def reload_hooks!
      HQ.hooks.reload!(projects: @registry&.projects || [])
    rescue StandardError => e
      HQ.logger.error("Hooks") { "Reload failed: #{e.class}: #{e.message}" }
    end

    def install_hooks_reload_trap!
      Signal.trap("HUP") { reload_hooks! }
    rescue ArgumentError
      nil
    end

    def refresh_boot_metadata!
      @projects.each do |project|
        project.refresh_metadata!
      rescue StandardError => e
        HQ.logger.warn("Project") { "Boot metadata refresh failed for #{project.key}: #{e.class}: #{e.message}" }
      end
    end

    def begin_refresh!
      return nil if @config_error
      return nil if refreshing?

      reload_registry_if_changed!
      HQ.logger.debug("App") { "Full refresh" }
      @loading = true
      HQ.log_boot_step("loading screen started") if @last_refresh.nil?

      projects = @projects
      agents = @agents
      @progress_mutex.synchronize do
        @progress_activity = []
        @progress_done = 0
        @progress_total = projects.length + agents.length
      end

      if @progress_total.zero?
        finish_refresh!
        return nil
      end

      @progress.instance_variable_set(:@percent_shown, 0.0)
      @progress.instance_variable_set(:@velocity, 0.0)
      progress_cmd = @progress.set_percent(0.0)

      worker = Thread.new do
        metadata_threads = projects.map do |project|
          Thread.new do
            timed_step("metadata:#{project.key}") do
              log_activity("Loading metadata: #{project.name}")
              project.refresh_metadata!
            end
          end
        end

        agent_threads = agents.map do |agent|
          Thread.new do
            timed_step("agent_poll:#{agent.name}") do
              log_activity("Polling agent: #{agent.name}")
              agent.poll!
            end
          end
        end

        (metadata_threads + agent_threads).each(&:join)
      end

      @progress_threads = [worker]
      Bubbletea.batch(progress_cmd, schedule_progress_poll)
    end

    def refresh_project_async!(project_key)
      project = @projects.find { |p| p.key == project_key }
      return unless project

      Thread.new do
        project.refresh_metadata!
      rescue StandardError => e
        HQ.logger.warn("Project") { "Async refresh failed for #{project_key}: #{e.class}: #{e.message}" }
      end
    end

    def timed_step(label)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
    rescue StandardError => e
      HQ.logger.error("Step") { "#{label} failed: #{e.class}: #{e.message}" }
    ensure
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round
      HQ.logger.debug("Step") { format("%5dms  %s", elapsed_ms, label) }
      @progress_mutex.synchronize { @progress_done += 1 }
    end

    def log_activity(line)
      @progress_mutex.synchronize do
        @progress_activity << line
        @progress_activity.shift while @progress_activity.length > 12
      end
    end

    def progress_activity_snapshot
      @progress_mutex.synchronize { @progress_activity.dup }
    end

    def progress_counts
      @progress_mutex.synchronize { [@progress_done, @progress_total] }
    end

    def refreshing?
      !@progress_threads.empty?
    end

    def handle_progress_tick
      done, total = progress_counts
      return [self, nil] unless refreshing?

      fraction = total.zero? ? 1.0 : done.to_f / total
      progress_cmd = fraction != @progress.percent ? @progress.set_percent(fraction) : nil

      if done >= total && !@progress.animating?
        @progress_threads.each(&:join)
        @progress_threads = []
        @agents = sort_agents(@agents)
        save_agents!
        rebuild_agent_index!
        refresh_omnisearch_index! if omnisearch_open?
        finish_refresh!
        [self, progress_cmd]
      else
        [self, Bubbletea.batch(*[progress_cmd, schedule_progress_poll].compact)]
      end
    end

    def finish_refresh!
      first_load = @last_refresh.nil?
      @last_refresh = Time.now
      @loading = false
      load_schedules!
      sync_agent_chat_workspace!
      HQ.log_boot_step("loading screen ended") if first_load
    end

    def schedule_progress_poll
      Bubbletea.tick(0.1) { ProgressTickMessage.new }
    end

    def rebuild_agent_index!
      @agents_by_project = Hash.new { |hash, key| hash[key] = [] }
      @agents.each do |agent|
        @agents_by_project[agent.project_key] << agent
      end
    end

    def load_agents!
      @all_agents = sort_agents(@agent_store.load)
      apply_agent_visibility!
      remember_known_agent_keys!
      rebuild_agent_index!
      sync_agent_chat_workspace!
    end

    def load_schedules!
      current_scheduler = build_scheduler
      @schedules = current_scheduler.list
      @schedule_daemon = current_scheduler.daemon_state.to_hash
      @schedule_error = nil
    rescue ScheduleRegistry::Error => e
      @schedules = []
      @schedule_daemon = ScheduleStore.new.daemon_state.to_hash
      @schedule_error = e.message
    rescue StandardError => e
      @schedules = []
      @schedule_daemon = {}
      @schedule_error = e.message
    end

    def run_selected_schedule
      schedule = selected_schedule
      return [self, nil] unless @screen == :schedules && schedule
      if schedule_blocked?(schedule)
        @schedule_action_message = nil
        @schedule_action_error = "Resume #{schedule_label(schedule)} before running it."
        return [self, nil]
      end

      result = build_scheduler.run_now(schedule.fetch(:key))
      load_agents!
      load_schedules!
      if result.fetch(:status) == :failed
        @schedule_action_message = nil
        @schedule_action_error = "Run failed: #{result.fetch(:error, "Unknown error")}"
      else
        @schedule_action_error = nil
        @schedule_action_message = schedule_run_message(schedule, result)
      end
      [self, schedule_action_poll]
    rescue StandardError => e
      record_schedule_action_error("Run failed", e)
    end

    def toggle_selected_schedule
      schedule = selected_schedule
      return [self, nil] unless @screen == :schedules && schedule

      scheduler = build_scheduler
      if schedule_blocked?(schedule)
        scheduler.resume(schedule.fetch(:key))
        action = "Resumed"
      else
        scheduler.pause(schedule.fetch(:key))
        action = "Paused"
      end
      @schedule_action_error = nil
      @schedule_action_message = "#{action} #{schedule_label(schedule)}."
      load_schedules!
      [self, nil]
    rescue StandardError => e
      record_schedule_action_error("Update failed", e)
    end

    def schedule_run_message(schedule, result)
      label = schedule_label(schedule)
      case result.fetch(:status)
      when :started then "Started #{label}."
      when :queued then "Queued #{label}."
      when :skipped then "Skipped #{label}."
      else "#{label}: #{result.fetch(:status)}."
      end
    end

    def build_scheduler
      Scheduler.new(registry: @registry)
    end

    def schedule_label(schedule)
      schedule[:name].to_s.empty? ? schedule.fetch(:key).to_s : schedule[:name].to_s
    end

    def schedule_blocked?(schedule)
      schedule[:paused] || %w[paused stopped].include?(schedule[:status].to_s)
    end

    def record_schedule_action_error(prefix, error)
      @schedule_action_message = nil
      @schedule_action_error = "#{prefix}: #{error.message}"
      HQ.logger.warn("Schedule") { @schedule_action_error }
      [self, nil]
    end

    def save_agents!
      agents = agents_with_external_additions(agents_with_hidden_projects(@agents))
      @agent_store.save(agents)
      @all_agents = sort_agents(agents)
      apply_agent_visibility!
      remember_known_agent_keys!
    rescue StandardError => e
      HQ.logger.error("AgentStore") { "Failed to save agents: #{e.message}" }
    end

    def apply_project_visibility!
      @projects = HQ::Visibility.visible_projects(@all_projects)
      clamp_selections!
    end

    def apply_agent_visibility!
      @agents = HQ::Visibility.visible_agents(@all_agents, @all_projects)
      clamp_selections!
    end

    def agents_with_hidden_projects(visible_agents)
      hidden_agents = @all_agents.reject { |agent| HQ::Visibility.agent_visible?(agent, @all_projects) }
      visible_agents + hidden_agents
    end

    def agents_with_external_additions(agents)
      return agents unless File.exist?(AGENTS_FILE)

      current_keys = agents.map(&:key)
      known_keys = @known_agent_keys || current_keys
      persisted_agents = @agent_store.load
      return agents if persisted_agents.empty? && !empty_persisted_agent_store?

      persisted_keys = persisted_agents.map(&:key)
      externally_removed_keys = known_keys - persisted_keys
      reconciled_agents = agents.reject { |agent| externally_removed_keys.include?(agent.key) }
      reconciled_keys = reconciled_agents.map(&:key)
      external_agents = persisted_agents.reject do |agent|
        reconciled_keys.include?(agent.key) || known_keys.include?(agent.key)
      end
      external_agents.empty? ? reconciled_agents : reconciled_agents + external_agents
    rescue StandardError
      agents
    end

    def empty_persisted_agent_store?
      parsed = JSON.parse(File.read(AGENTS_FILE))
      parsed.is_a?(Array) && parsed.empty?
    rescue StandardError
      false
    end

    def remember_known_agent_keys!
      @known_agent_keys = @all_agents.map(&:key)
    end

    def clamp_selections!
      @selected[:agents] = clamp_selection(@selected[:agents], @agents.length)
      @selected[:projects] = clamp_selection(@selected[:projects], @projects.length)
      @selected[:schedules] = clamp_selection(@selected[:schedules], @schedules.length)
    end

    def clamp_selection(value, length)
      return 0 if length.to_i <= 0

      [[value.to_i, 0].max, length - 1].min
    end

    def poll_agents!
      @agents.each do |agent|
        was_running = agent_running_for_unread?(agent)
        agent.poll!
        mark_agent_unread_if_needed(agent) if was_running && agent.status != "running"
      end
      @agents = sort_agents(@agents)
      save_agents!
      rebuild_agent_index!
      sync_agent_chat_workspace!
    end

def selected_screen_items
      case @screen
      when :agents then @agents
      when :projects then @projects
      when :schedules then @schedules
      else []
      end
    end

    def move_selection(delta)
      items = selected_screen_items
      return [self, nil] if items.empty?

      @selected[@screen] = (@selected[@screen] + delta) % items.length
      clear_stale_results
      sync_agent_chat_workspace! if @screen == :agents
      [self, nil]
    end

    def switch_screen(delta)
      index = SCREENS.index(@screen)
      @screen = SCREENS[(index + delta) % SCREENS.length]
      [self, nil]
    end

    def select_screen(screen)
      @screen = screen
      [self, nil]
    end

    def selected_agent
      @agents[@selected[:agents]]
    end

    def selected_project
      @projects[@selected[:projects]]
    end

    def selected_schedule
      @schedules[@selected[:schedules]]
    end

    def overlay_open?
      !@sidebar.nil?
    end

    def sidebar_visible?
      @sidebar_visible
    end

    def omnisearch_open?
      !@omnisearch.nil?
    end

    def open_omnisearch
      return [self, nil] unless sidebar_navigation_focus?

      @omnisearch = UI::Omnisearch.new
      [self, schedule_omnisearch_index]
    end

    def schedule_omnisearch_index
      Bubbletea.tick(0) { OmnisearchIndexMessage.new }
    end

    def handle_omnisearch_index
      return [self, nil] unless @omnisearch

      refresh_omnisearch_index!
      [self, nil]
    end

    def refresh_omnisearch_index!
      @omnisearch&.build_index!(agents: @agents, projects: @projects, reset_selection: @omnisearch.empty_query?)
    end

    def sidebar_navigation_focus?
      SCREENS.include?(@screen) &&
        sidebar_visible? &&
        !overlay_open? &&
        !@viewing_detail &&
        !@confirming &&
        !@delete_confirm &&
        !@clone_confirm &&
        !@project_archive_confirm
    end

    def handle_omnisearch(message)
      return [self, nil] unless message.is_a?(Bubbletea::KeyMessage)

      case message.to_s
      when "esc", "escape"
        close_omnisearch!
        [self, nil]
      when "enter"
        navigate_to_omnisearch_result
      else
        @omnisearch.update_key(message.to_s)
        [self, nil]
      end
    end

    def navigate_to_omnisearch_result
      item = @omnisearch&.selected_item
      close_omnisearch!
      return [self, nil] unless item

      case item.type
      when :agent
        select_omnisearch_agent(item.target_key)
      when :project
        select_omnisearch_project(item.target_key)
      else
        [self, nil]
      end
    end

    def close_omnisearch!
      @omnisearch = nil
    end

    def select_omnisearch_agent(agent_key)
      index = @agents.index { |agent| agent.key == agent_key }
      return [self, nil] unless index

      @screen = :agents
      @selected[:agents] = index
      sync_agent_chat_workspace!
      [self, nil]
    end

    def select_omnisearch_project(project_key)
      index = @projects.index { |project| project.key == project_key }
      return [self, nil] unless index

      @screen = :projects
      @selected[:projects] = index
      [self, nil]
    end

    def maybe_confirm_project_archive
      return [self, nil] unless @screen == :projects

      project = selected_project
      return [self, nil] unless project
      return [self, nil] if @agents_by_project[project.key].any?(&:running?)

      @project_archive_confirm = UI::ProjectArchiveConfirm.new(project, agents: @agents_by_project[project.key])
      [self, nil]
    end

    def open_agent_editor_for_selected_project
      return [self, nil] unless @screen == :projects

      open_agent_editor(selected_project, mode: :create)
    end

    def open_agent_editor_for_selected_agent
      return [self, nil] unless @screen == :agents

      agent = selected_agent
      return [self, nil] unless agent
      return [self, nil] if agent.running?

      project = @projects.find { |candidate| candidate.key == agent.project_key }
      open_agent_editor(project, mode: :edit, agent: agent)
    end

    def open_agent_chat_form
      return [self, nil] unless @screen == :agents

      agent = selected_agent
      return [self, nil] unless agent

      close_sidebar!
      body_height = sidebar_component_body_height
      width = sidebar_component_width
      @agent_chat_form = UI::AgentChatForm.new(agent, width: width, body_height: body_height)
      @sidebar = { kind: :agent_chat }
      agent.mark_read!
      refresh_skills_for_workspace!(agent)
      save_agents!
      @agent_chat_form.composer.skill_picker.skills = agent.skills
      sync_agent_chat_workspace!
      maybe_prompt_rebuild_memory!(agent)
      [self, @agent_chat_form.composer.focus_input]
    end

    def maybe_prompt_rebuild_memory!(agent)
      chat_log = HQ::AgentChatLog.new(agent)
      @confirming = :rebuild_memory if chat_log.memory_missing_with_raw_log?
    end

    def request_rebuild_memory_for_chat!
      return [self, nil] unless @agent_chat_form

      @confirming = :rebuild_memory
      [self, nil]
    end

    def rebuild_memory_for_chat_agent
      agent = @agent_chat_form&.agent
      return [self, nil] unless agent

      written = HQ::AgentChatLog.new(agent).rebuild_memory_from_raw_log!
      agent.build_summary!
      save_agents!
      HQ.logger.info("Agent") { "Rebuilt memory for #{agent.key} (events=#{written})" } if written
      sync_agent_chat_workspace!
      [self, nil]
    end

    def start_selected_agent
      return [self, nil] unless @screen == :agents

      start_agent(selected_agent)
    end

    def stop_selected_agent
      return [self, nil] unless @screen == :agents

      agent = selected_agent
      return [self, nil] unless agent

      replacement = @agent_store.stop_agent!(agent.key)
      @agents[@agents.index(agent)] = replacement
      rebuild_agent_index!
      [self, schedule_action_poll]
    end

    def rerun_selected_agent
      return [self, nil] unless @screen == :agents

      start_agent(selected_agent)
    end

    def delete_selected_agent
      return [self, nil] unless @screen == :agents

      agent = selected_agent
      return [self, nil] unless agent
      return [self, nil] if agent.running?

      @delete_confirm = UI::DeleteAgentConfirm.new(agent)
      [self, nil]
    end

    def clone_selected_agent
      return [self, nil] unless @screen == :agents

      old_agent = selected_agent
      return [self, nil] unless old_agent

      close_sidebar!
      new_agent = @agent_store.clone_agent(old_agent, existing_agents: @all_agents)
      @agents.unshift(new_agent)
      @agents = sort_agents(@agents)
      @selected[:agents] = @agents.index(new_agent) || 0
      save_agents!
      rebuild_agent_index!
      @clone_confirm = UI::CloneAgentConfirm.new(old_agent: old_agent, new_agent: new_agent)
      HQ.hooks.publish("agent.cloned",
                       agent_key: new_agent.key,
                       source_agent_key: old_agent.key,
                       project_key: new_agent.project_key,
                       name: new_agent.name,
                       agent: new_agent.agent,
                       model: new_agent.model,
                       reasoning_effort: new_agent.reasoning_effort)
      [self, nil]
    end

    def handle_delete_confirm(message)
      return [self, nil] unless message.is_a?(Bubbletea::KeyMessage)

      case message.to_s
      when "esc", "escape", "q"
        @delete_confirm = nil
        [self, nil]
      when "tab", "right", "l"
        @delete_confirm.picker.value = UI::DeleteAgentConfirm::CONFIRM
        [self, nil]
      when "shift+tab", "left", "h"
        @delete_confirm.picker.value = UI::DeleteAgentConfirm::ABORT
        [self, nil]
      when "enter"
        confirm = @delete_confirm.confirm?
        agent = @delete_confirm.agent
        @delete_confirm = nil
        confirm ? perform_delete_agent(agent) : [self, nil]
      else
        @delete_confirm.update(message)
        [self, nil]
      end
    end

    def handle_clone_confirm(message)
      return [self, nil] unless message.is_a?(Bubbletea::KeyMessage)

      case message.to_s
      when "esc", "escape", "q"
        confirm = @clone_confirm
        @clone_confirm = nil
        open_cloned_agent_chat(confirm.new_agent)
      when "tab", "right", "l"
        @clone_confirm.picker.value = UI::CloneAgentConfirm::ARCHIVE
        [self, nil]
      when "shift+tab", "left", "h"
        @clone_confirm.picker.value = UI::CloneAgentConfirm::KEEP
        [self, nil]
      when "enter"
        confirm = @clone_confirm
        @clone_confirm = nil
        if confirm.archive_old?
          _, command = perform_delete_agent(confirm.old_agent)
          _, chat_command = open_cloned_agent_chat(confirm.new_agent)
          [self, Bubbletea.batch(*[command, chat_command].compact)]
        else
          open_cloned_agent_chat(confirm.new_agent)
        end
      else
        @clone_confirm.update(message)
        [self, nil]
      end
    end

    def handle_project_archive_confirm(message)
      return [self, nil] unless message.is_a?(Bubbletea::KeyMessage)

      case message.to_s
      when "esc", "escape", "q"
        @project_archive_confirm = nil
        [self, nil]
      when "tab", "right", "l"
        @project_archive_confirm.picker.value = UI::ProjectArchiveConfirm::CONFIRM
        [self, nil]
      when "shift+tab", "left", "h"
        @project_archive_confirm.picker.value = UI::ProjectArchiveConfirm::ABORT
        [self, nil]
      when "enter"
        confirm = @project_archive_confirm.confirm?
        project = @project_archive_confirm.project
        @project_archive_confirm = nil
        confirm ? archive_project(project) : [self, nil]
      else
        @project_archive_confirm.update(message)
        [self, nil]
      end
    end

    def perform_delete_agent(agent)
      return [self, nil] unless agent
      return [self, nil] if agent.running?

      @agent_store.archive_agent!(agent.key)
      reconcile_archived_schedule_agent(agent)
      @agents.delete(agent)
      rebuild_agent_index!
      @selected[:agents] = [@selected[:agents], @agents.length - 1].min
      @selected[:agents] = 0 if @selected[:agents].negative?
      HQ.hooks.publish("agent.deleted",
                       agent_key: agent.key,
                       project_key: agent.project_key,
                       name: agent.name)
      [self, nil]
    end

    def reconcile_archived_schedule_agent(agent)
      Scheduler.new(registry: @registry).reconcile_archived_agent!(agent.key, archived_agent: agent)
    rescue StandardError
      false
    end

    def open_cloned_agent_chat(agent)
      @selected[:agents] = @agents.index(agent) || 0
      @screen = :agents
      open_agent_chat_form
    end

    def open_project_editor(force: false)
      return [self, nil] unless force || @screen == :projects

      close_sidebar!
      groups = @projects.map { |p| p.config.group }.reject(&:empty?)
      @project_editor = UI::ProjectEditor.new(existing_groups: groups)
      @project_editor.resize(width: sidebar_component_width)
      @sidebar = {
        kind: :project_editor,
        title: "New Project"
      }
      @sidebar_viewport = nil
      @sidebar_content_proc = nil
      [self, @project_editor.current_input&.focus]
    end

    def open_agent_editor(project, mode:, agent: nil)
      return [self, nil] unless project

      close_sidebar!
      @agent_editor = UI::AgentEditor.new(mode: mode, project: project, agent: agent)
      @agent_editor.resize(width: sidebar_component_width)
      @sidebar = {
        kind: :agent_editor,
        title: "#{@agent_editor.title}  #{Styles::MARKERS[:bullet_sep]}  #{icon_label(:project, project)}"
      }
      @sidebar_viewport = nil
      @sidebar_content_proc = nil
      [self, @agent_editor.current_input&.focus]
    end

    def start_agent(agent)
      return [self, nil] unless agent
      return [self, nil] if agent.running?

      replacement = @agent_store.start_agent!(agent.key)
      @agents[@agents.index(agent)] = replacement
      agent = replacement
      @agents.sort_by!(&:last_activity_at).reverse!
      @selected[:agents] = @agents.index(agent) || 0
      rebuild_agent_index!
      [self, schedule_action_poll]
    end

    def handle_confirm(key)
      key = "y" if key == "q" && @confirming == :quit
      case key
      when "y"
        action = @confirming
        @confirming = nil
        if action == :restart
          HQ.restart_requested = true
          return [self, Bubbletea.quit]
        end
        return [self, Bubbletea.quit] if action == :quit
        return rebuild_memory_for_chat_agent if action == :rebuild_memory

        [self, nil]
      when "n", "escape"
        @confirming = nil
        [self, nil]
      else
        [self, nil]
      end
    end

    def archive_project(project)
      return [self, nil] unless project
      return [self, nil] if @agents_by_project[project.key].any?(&:running?)

      merged = agents_with_hidden_projects(@agents)
      result = ProjectArchiver.new(registry: @registry, agent_store: @agent_store)
        .archive(project.key, agents: merged)
      destination = result.project_log_archive
      load_registry!
      @agent_store = AgentStore.new(@all_projects)
      @agents = @agent_store.load
      rebuild_agent_index!
      @selected[:projects] = [@selected[:projects], @projects.length - 1].min
      @selected[:projects] = 0 if @selected[:projects].negative?
      @selected[:agents] = [@selected[:agents], @agents.length - 1].min
      @selected[:agents] = 0 if @selected[:agents].negative?
      @project_archive_confirm = nil
      close_sidebar!
      if destination
        HQ.logger.info("Project") { "Archived #{project.key} to #{destination}" }
      else
        HQ.logger.info("Project") { "Archived #{project.key}" }
      end
      [self, nil]
    end

    def handle_agent_editor(message)
      case message
      when Bubbletea::KeyMessage
        case message.to_s
        when "esc", "escape"
          close_sidebar!
          return [self, nil]
        when "tab", "down"
          @agent_editor.next_field
          return [self, @agent_editor.current_input&.focus]
        when "shift+tab", "up"
          @agent_editor.previous_field
          return [self, @agent_editor.current_input&.focus]
        when "left"
          if @agent_editor.template_focused?
            @agent_editor.cycle_template(-1)
            return [self, nil]
          end
          if @agent_editor.harness_focused?
            @agent_editor.cycle_harness(-1)
            return [self, nil]
          end
          if @agent_editor.submit_focused?
            @agent_editor.cycle_submit_button(-1)
            return [self, nil]
          end
        when "right"
          if @agent_editor.template_focused?
            @agent_editor.cycle_template(1)
            return [self, nil]
          end
          if @agent_editor.harness_focused?
            @agent_editor.cycle_harness(1)
            return [self, nil]
          end
          if @agent_editor.submit_focused?
            @agent_editor.cycle_submit_button(1)
            return [self, nil]
          end
        when "enter"
          return save_agent_editor if @agent_editor.submit_focused?
          return [self, nil] if @agent_editor.field_index != @agent_editor.prompt_field_index

          # Allow multiline editing in the prompt field.
        when "ctrl+s"
          return save_agent_editor
        end
      end

      input = @agent_editor.current_input
      return [self, nil] unless input

      updated_input, command = input.update(UI::TextPaste.normalize_message(input, message))
      case @agent_editor.field_index
      when @agent_editor.name_field_index then @agent_editor.instance_variable_set(:@name_input, updated_input)
      when @agent_editor.workspace_field_index
        @agent_editor.instance_variable_set(:@workspace_input, updated_input)
      when @agent_editor.model_field_index
        @agent_editor.mark_model_dirty!
        @agent_editor.instance_variable_set(:@model_input, updated_input)
      when @agent_editor.reasoning_effort_field_index
        @agent_editor.mark_reasoning_effort_dirty!
        @agent_editor.instance_variable_set(:@reasoning_effort_input, updated_input)
      else
        @agent_editor.instance_variable_set(:@prompt_input, updated_input)
      end
      [self, command]
    end

    def save_agent_editor
      attrs = @agent_editor.attributes
      if (error = @agent_editor.validate)
        @agent_editor.error_message = error
        return [self, nil]
      end

      target_agent = nil
      command = nil
      name_only = false

      if @agent_editor.mode == :create
        agent = @agent_store.create_from_template(@agent_editor.project, attrs[:template_key])
        agent.update!(**attrs)
        @agent_store.ensure_project_context_prompt!(agent, @agent_editor.project)
        refresh_skills_for_workspace!(agent)
        HQ.hooks.publish("agent.created",
                         agent_key: agent.key,
                         project_key: agent.project_key,
                         template_key: agent.template_key.to_s,
                         name: agent.name,
                         workspace: agent.workspace,
                         agent: agent.agent,
                         model: agent.model,
                         reasoning_effort: agent.reasoning_effort)
        @agents.unshift(agent)
        target_agent = agent
      else
        agent = @agent_editor.agent
        other_keys = %i[template_key workspace prompt sandbox_mode agent model reasoning_effort]
        if other_keys.all? { |k| attrs[k].to_s == agent.public_send(k).to_s }
          agent.rename!(attrs[:name])
          target_agent = agent
          name_only = true
        else
          agent.update!(**attrs)
          target_agent = agent
        end
      end

      @agents = sort_agents(@agents) unless name_only
      @selected[:agents] = @agents.index(target_agent) || 0
      save_agents!
      if @agent_editor.mode == :create && @agent_editor.run_on_submit?
        begin
          target_agent = @agent_store.start_agent!(target_agent.key)
          @agents[@agents.index { |item| item.key == target_agent.key }] = target_agent
        rescue StandardError => e
          @agent_editor.error_message = "Failed to start agent: #{e.message}"
          return [self, nil]
        end
        command = schedule_action_poll
      end
      rebuild_agent_index! unless name_only

      if @agent_editor.mode == :create
        @screen = :agents
        _, chat_command = open_agent_chat_form
        [self, Bubbletea.batch(*[command, chat_command].compact)]
      else
        close_sidebar!
        sync_agent_chat_workspace!
        [self, command]
      end
    end

    def handle_project_editor(message)
      return [self, nil] unless message.is_a?(Bubbletea::KeyMessage)

      key = message.to_s

      if @project_editor.suggestions_visible?
        case key
        when "down"
          @project_editor.move_suggestion(1)
          return [self, nil]
        when "up"
          @project_editor.move_suggestion(-1)
          return [self, nil]
        when "enter"
          if @project_editor.accept_suggestion!
            return [self, nil]
          end
        when "esc", "escape"
          @project_editor.clear_suggestions!
          return [self, nil]
        end
      end

      case key
      when "esc", "escape"
        close_sidebar!
        return [self, nil]
      when "tab"
        @project_editor.prefill_from_path! if @project_editor.path_focused?
        @project_editor.next_field
        @project_editor.refresh_suggestions!
        return [self, @project_editor.current_input&.focus]
      when "shift+tab"
        @project_editor.prefill_from_path! if @project_editor.path_focused?
        @project_editor.previous_field
        @project_editor.refresh_suggestions!
        return [self, @project_editor.current_input&.focus]
      when "left"
        if @project_editor.agent_focused?
          @project_editor.cycle_agent(-1)
          return [self, nil]
        end
      when "right"
        if @project_editor.agent_focused?
          @project_editor.cycle_agent(1)
          return [self, nil]
        end
      when "enter"
        return save_project_editor if @project_editor.submit_focused?
      end

      input = @project_editor.current_input
      return [self, nil] unless input

      input, = input.update(UI::TextPaste.normalize_message(input, message))
      case @project_editor.field_index
      when @project_editor.key_field_index then @project_editor.instance_variable_set(:@key_input, input)
      when @project_editor.name_field_index then @project_editor.instance_variable_set(:@name_input, input)
      when @project_editor.group_field_index
        @project_editor.instance_variable_set(:@group_input, input)
        @project_editor.refresh_suggestions!
      when @project_editor.path_field_index
        @project_editor.instance_variable_set(:@path_input, input)
        @project_editor.refresh_suggestions!
      end
      [self, nil]
    end

    def save_project_editor
      attrs = @project_editor.attributes
      if (error = @project_editor.validate)
        @project_editor.error_message = error
        return [self, nil]
      end

      @registry.add_project!(attrs)
      load_registry!
      @agent_store = AgentStore.new(@all_projects)
      load_agents!
      @selected[:projects] = @projects.index { |p| p.key == attrs[:key] } || (@projects.length - 1)
      close_sidebar!
      HQ.logger.info("Project") { "Created project #{attrs[:key]}" }
      refresh_project_async!(attrs[:key])
      [self, nil]
    rescue ConfigError => e
      @project_editor.error_message = e.message
      [self, nil]
    end

    def refresh_skills_for_workspace!(new_agent)
      skills = SkillDiscovery.discover(workspace: new_agent.workspace, agent_kind: new_agent.agent)
      new_agent.skills = skills
      @agents.each do |existing|
        next unless existing.workspace == new_agent.workspace

        existing.skills = skills
      end
    end

    def mark_agent_unread_if_needed(agent)
      return if agent.respond_to?(:no_action_needed?) && agent.no_action_needed?

      if agent_chat_visible_for?(agent)
        agent.mark_read!
      else
        agent.mark_unread!
      end
    end

    def agent_running_for_unread?(agent)
      agent.status == "running" || (!!agent.pid && agent.last_run&.status == "running")
    end

    def agent_chat_visible_for?(agent)
      @sidebar&.fetch(:kind, nil) == :agent_chat && @agent_chat_form&.agent == agent
    end

    def schedule_refresh
      Bubbletea.tick(30) { TickMessage.new }
    end

    def schedule_chat_render_poll
      Bubbletea.tick(0.2) { ChatRenderPollMessage.new }
    end

    def handle_chat_render_poll
      return [self, nil] unless @agent_chat_form&.block_detail_open?

      @agent_chat_form.sync_block_detail!
      cmd = UI::Rendering::ChatRendering.glamour_render_pending? ? schedule_chat_render_poll : nil
      [self, cmd]
    end

    def schedule_action_poll
      return nil if @agents.none? { |agent| agent.pid || agent.running? }

      Bubbletea.tick(10) { ActionPollMessage.new }
    end

    def clear_stale_results
    end

    def open_context_log
      case @screen
      when :agents
        agent = selected_agent
        return [self, nil] unless agent

        return open_sidebar_text(
          kind: :chat_log,
          title: "Agent Chat Log  #{Styles::MARKERS[:bullet_sep]}  #{agent.name}"
        ) { read_agent_chat_log(agent) }
      end

      [self, nil]
    end

    def open_raw_log
      return [self, nil] unless @screen == :agents

      agent = selected_agent
      return [self, nil] unless agent

      path = agent.raw_log_path
      open_sidebar_text(
        kind: :raw_log,
        title: "Agent Raw Log  #{Styles::MARKERS[:bullet_sep]}  #{agent.name}",
        path: path
      ) { read_log_file(path) }
    end

    def agent_chat_text(agent)
      AgentChatLog.new(agent).chat_text
    rescue StandardError
      "(chat log unavailable)"
    end

    def open_sidebar_text(kind:, title:, path: nil, &content_proc)
      close_sidebar!
      @sidebar = {
        kind: kind,
        title: title,
        path: path,
        stat_key: nil
      }
      @sidebar_content_proc = content_proc
      @sidebar_viewport = if log_sidebar_kind?(kind)
                            UI::LogViewer.new(width: sidebar_content_width, height: sidebar_text_height)
                          else
                            Bubbles::Viewport.new(width: sidebar_content_width, height: sidebar_text_height)
                          end
      sync_sidebar_text!(force: true)
      [self, nil]
    end

    def log_sidebar_kind?(kind)
      %i[chat_log raw_log project_log].include?(kind)
    end

    def read_agent_chat_log(agent)
      agent_chat_text(agent)
    end

    def read_log_file(path, tail_bytes: nil, max_lines: nil, max_line_width: nil)
      return "(log unavailable)" unless path && File.exist?(path)

      data = if tail_bytes && File.size(path) > tail_bytes
               File.open(path, "rb") do |f|
                 f.seek(-tail_bytes, IO::SEEK_END)
                 chunk = f.read.to_s
                 newline = chunk.index("\n".b)
                 chunk = chunk[(newline + 1)..] if newline
                 chunk
               end
             else
               File.read(path)
             end
      data = data.to_s.dup.force_encoding(Encoding::UTF_8)
      data = data.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?") unless data.valid_encoding?

      truncated_bytes = tail_bytes && File.size(path) > tail_bytes
      truncated_lines = false

      if max_lines || max_line_width
        lines = data.split("\n", -1)
        if max_lines && lines.length > max_lines
          lines = lines.last(max_lines)
          truncated_lines = true
        end
        if max_line_width
          ellipsis = "… (#{max_line_width}+ chars)"
          lines.map! do |line|
            line.length > max_line_width ? "#{line[0, max_line_width]}#{ellipsis}" : line
          end
        end
        data = lines.join("\n")
      end

      banner = []
      banner << "… (truncated to last #{tail_bytes / 1024} KB)" if truncated_bytes
      banner << "… (showing last #{max_lines} lines)" if truncated_lines
      banner.empty? ? data : "#{banner.join("\n")}\n#{data}"
    rescue StandardError => e
      "Failed to read log: #{e.message}"
    end

    def open_terminal_for_selected
      dir = case @screen
            when :projects
              selected_project&.path
            when :agents
              selected_agent&.workspace
            end
      return [self, nil] unless dir && Dir.exist?(dir)

      spawn_terminal_window(dir)
      [self, nil]
    end

    def open_interactive_terminal_for_selected_agent
      agent = case @screen
              when :agents
                selected_agent
              when :projects
                project = selected_project
                project ? @agents_by_project[project.key].first : nil
              end
      return [self, nil] unless agent
      return [self, nil] unless agent.workspace && Dir.exist?(agent.workspace)

      execution = agent.interactive_command
      spawn_terminal_window(
        agent.workspace,
        command: shell_command_for_terminal(execution.fetch(:command), execution.fetch(:env, {}))
      )
      [self, nil]
    rescue StandardError => e
      HQ.logger.error("App") { "Failed to open interactive agent terminal: #{e.message}" }
      [self, nil]
    end

    def shell_command_for_terminal(command, env = {})
      return Shellwords.shelljoin(command) if env.empty?

      Shellwords.shelljoin(["env"] + env.map { |key, value| "#{key}=#{value}" } + command)
    end

    def spawn_terminal_window(dir, command: nil)
      term = ENV["TERM_PROGRAM"].to_s.downcase

      if term == "ghostty"
        escaped_dir = applescript_escape(dir)
        escaped_command = applescript_escape(command.to_s)
        script = <<~APPLESCRIPT
          tell application "Ghostty"
            set cfg to new surface configuration
            set initial working directory of cfg to "#{escaped_dir}"
            #{command.to_s.empty? ? "" : "set command of cfg to \"#{escaped_command}\""}
            set t to focused terminal of selected tab of front window
            split t direction right with configuration cfg
          end tell
        APPLESCRIPT
        run_osascript(script)
        return
      end

      if command && !command.empty? && term == "wezterm"
        spawn_detached("wezterm", "cli", "split-pane", "--right", "--cwd", dir, "--", "sh", "-lc", "exec #{command}")
        return
      end

      if command && !command.empty? && (term.empty? || %w[iterm.app apple_terminal].include?(term))
        spawn_shell_terminal(app_for_term(term), dir, command)
        return
      end

      app = app_for_term(term)
      spawn_detached("open", "-a", app, dir)
    rescue StandardError => e
      HQ.logger.error("App") { "Failed to open terminal: #{e.message}" }
    end

    def app_for_term(term)
      case term
      when "iterm.app" then "iTerm"
      when "apple_terminal" then "Terminal"
      when "wezterm" then "WezTerm"
      when "vscode" then "Visual Studio Code"
      when "" then "Terminal"
      else ENV["TERM_PROGRAM"]
      end
    end

    def spawn_shell_terminal(app, dir, command)
      shell_command = "cd #{Shellwords.escape(dir)} && exec #{command}"
      escaped = applescript_escape(shell_command)
      script = if app == "iTerm"
                 <<~APPLESCRIPT
                   tell application "iTerm"
                     create window with default profile command "#{escaped}"
                     activate
                   end tell
                 APPLESCRIPT
               else
                 <<~APPLESCRIPT
                   tell application "Terminal"
                     do script "#{escaped}"
                     activate
                   end tell
                 APPLESCRIPT
               end
      run_osascript(script)
    end

    def applescript_escape(text)
      text.to_s.gsub("\\") { "\\\\" }.gsub('"') { '\\"' }
    end

    def spawn_detached(*command)
      pid = Process.spawn(*command, %i[out err] => "/dev/null", in: "/dev/null")
      Process.detach(pid)
    rescue StandardError => e
      HQ.logger.error("App") { "Failed to spawn process: #{e.message}" }
    end

    def run_osascript(script)
      Thread.new do
        out, err, status = Open3.capture3("osascript", "-e", script)
        if status.exitstatus != 0 || !err.to_s.strip.empty?
          HQ.logger.error("App") do
            "osascript exit=#{status.exitstatus} stderr=#{err.strip.inspect} stdout=#{out.strip.inspect}"
          end
        end
      rescue StandardError => e
        HQ.logger.error("App") { "Failed to run osascript: #{e.message}" }
      end
    end

    def handle_sidebar(message)
      case message
      when Bubbletea::WindowSizeMessage
        apply_window_size(message.width, message.height)
        return [self, nil]
      when ActionPollMessage
        poll_agents!
        sync_sidebar_text!
        return [self, schedule_action_poll]
      when Bubbletea::KeyMessage
        case message.to_s
        when "q"
          unless %i[agent_chat agent_editor project_editor].include?(@sidebar[:kind])
            close_sidebar!
            return [self, nil]
          end
        end
      end

      case @sidebar[:kind]
      when :agent_chat
        handle_agent_chat_form(message)
      when :agent_editor
        handle_agent_editor(message)
      when :project_editor
        handle_project_editor(message)
      else
        handle_sidebar_text(message)
      end
    end

    def open_detail_view
      close_sidebar!
      @viewing_detail = true
      @detail_viewport = Bubbles::Viewport.new(width: detail_overlay_width, height: detail_overlay_height)
      sync_detail_overlay!
      [self, nil]
    end

    def sync_detail_overlay!
      return unless @detail_viewport

      @detail_viewport.width = detail_overlay_width
      @detail_viewport.height = detail_overlay_height
      @detail_viewport.content = current_detail_text.to_s
    rescue StandardError
      nil
    end

    def handle_detail_overlay(message)
      case message
      when Bubbletea::WindowSizeMessage
        apply_window_size(message.width, message.height)
        return [self, nil]
      when ActionPollMessage
        poll_agents!
        sync_detail_overlay!
        return [self, schedule_action_poll]
      when Bubbletea::KeyMessage
        case message.to_s
        when "esc", "escape", "q", "v"
          @viewing_detail = false
          @detail_viewport = nil
          return [self, nil]
        when "r"
          sync_detail_overlay!
          return [self, nil]
        end
      end

      @detail_viewport&.update(message)
      [self, nil]
    end

    def handle_sidebar_text(message)
      return [self, nil] unless @sidebar_viewport

      if message.is_a?(Bubbletea::KeyMessage)
        case message.to_s
        when "esc", "escape"
          close_sidebar!
          return [self, nil]
        when "r"
          sync_sidebar_text!(force: true)
          return [self, nil]
        end
      end

      @sidebar_viewport.update(message)
      [self, nil]
    end

    def close_sidebar!
      @sidebar = nil
      @sidebar_viewport = nil
      @sidebar_content_proc = nil
      @agent_editor = nil
      @agent_chat_form = nil
      @project_editor = nil
    end

    def sync_sidebar_text!(force_bottom: false, force: false)
      return unless @sidebar_viewport && @sidebar_content_proc

      @sidebar_viewport.width = sidebar_content_width
      @sidebar_viewport.height = sidebar_text_height

      stat_key = sidebar_stat_key
      if !force && stat_key && @sidebar && @sidebar[:stat_key] == stat_key
        @sidebar_viewport.goto_bottom if force_bottom
        return
      end

      pin_to_bottom = force_bottom || @sidebar_viewport.at_bottom?
      @sidebar_viewport.content = @sidebar_content_proc.call.to_s
      @sidebar[:stat_key] = stat_key if @sidebar
      @sidebar_viewport.goto_bottom if pin_to_bottom
    rescue StandardError
      nil
    end

    def sidebar_stat_key
      path = @sidebar && @sidebar[:path]
      return nil unless path && File.exist?(path)

      stat = File.stat(path)
      [stat.size, stat.mtime.to_f]
    rescue StandardError
      nil
    end

    def sync_agent_chat_workspace!(force_bottom: false)
      return unless @agent_chat_form

      viewport = @agent_chat_form.viewport
      pin_to_bottom = force_bottom
      @agent_chat_form.sync_inquiry!(@agent_chat_form.agent.latest_inquiry)
      @agent_chat_form.composer.placeholder = chat_placeholder_for(@agent_chat_form.agent) unless @agent_chat_form.inquiry_active?
      @agent_chat_form.sync!(agent_chat_content(@agent_chat_form.agent))
      viewport.goto_bottom if pin_to_bottom
    rescue StandardError
      nil
    end

    def apply_window_size(width, height)
      @window_width = width
      @window_height = height
      content_width = sidebar_component_width
      body_height = sidebar_component_body_height
      @agent_chat_form&.resize(width: content_width, body_height: body_height)
      @agent_editor&.resize(width: content_width)
      @project_editor&.resize(width: content_width)
      sync_sidebar_text!
      sync_agent_chat_workspace!
      sync_detail_overlay!
    end

    def handle_agent_chat_form(message)
      case message
      when Bubbletea::KeyMessage
        key = message.to_s
        if key == "ctrl+a"
          @agent_chat_form.toggle_attachments_detail
          sync_agent_chat_workspace!
          return [self, nil]
        end

        if @agent_chat_form.attachments_detail_open?
          return handle_agent_attachments_detail_key(message)
        end

        if @agent_chat_form.skill_picker_open? && @agent_chat_form.prompt_focused?
          handled = handle_skill_picker_key(key)
          return handled if handled
        end

        case key
        when "esc", "escape"
          if @agent_chat_form.content_focused? && @agent_chat_form.block_detail_open?
            @agent_chat_form.close_block_detail
            sync_agent_chat_workspace!
            return [self, nil]
          end
          if @agent_chat_form.summary_focused? && @agent_chat_form.summary_detail_open?
            @agent_chat_form.close_summary_detail
            sync_agent_chat_workspace!
            return [self, nil]
          end
          close_sidebar!
          return [self, nil]
        when "tab"
          @agent_chat_form.next_focus
          return [self, nil]
        when "shift+tab"
          @agent_chat_form.previous_focus
          return [self, nil]
        when "enter"
          if @agent_chat_form.prompt_focused?
            return handle_inquiry_enter if @agent_chat_form.inquiry_active?

            return save_agent_chat_form
          end
          if @agent_chat_form.content_focused?
            if @agent_chat_form.block_detail_open?
              @agent_chat_form.close_block_detail
              sync_agent_chat_workspace!
              return [self, nil]
            else
              @agent_chat_form.open_selected_block
              sync_agent_chat_workspace!
              cmd = UI::Rendering::ChatRendering.glamour_render_pending? ? schedule_chat_render_poll : nil
              return [self, cmd]
            end
          end
          if @agent_chat_form.summary_focused?
            if @agent_chat_form.summary_detail_open?
              @agent_chat_form.close_summary_detail
            else
              @agent_chat_form.open_summary_detail
            end
            sync_agent_chat_workspace!
            return [self, nil]
          end
        when "shift+enter", "alt+enter", "ctrl+j"
          if @agent_chat_form.prompt_focused?
            @agent_chat_form.input_component.insert_newline
            sync_agent_chat_workspace!
          end
          return [self, nil]
        when "ctrl+p"
          if @agent_chat_form.prompt_focused? && @agent_chat_form.inquiry_active?
            @agent_chat_form.inquiry_form.previous_field
            sync_agent_chat_workspace!
            return [self, nil]
          end
        when "left"
          if @agent_chat_form.content_focused?
            was_detail_open = @agent_chat_form.block_detail_open?
            if was_detail_open
              @agent_chat_form.select_previous_detail_block
            else
              @agent_chat_form.select_previous_block
            end
            sync_agent_chat_workspace!
            cmd = was_detail_open && UI::Rendering::ChatRendering.glamour_render_pending? ? schedule_chat_render_poll : nil
            return [self, cmd]
          end
          if @agent_chat_form.prompt_focused? && @agent_chat_form.inquiry_active? &&
             @agent_chat_form.inquiry_form.picker?
            @agent_chat_form.inquiry_form.previous_field
            sync_agent_chat_workspace!
            return [self, nil]
          end
        when "right"
          if @agent_chat_form.content_focused?
            was_detail_open = @agent_chat_form.block_detail_open?
            if was_detail_open
              @agent_chat_form.select_next_detail_block
            else
              @agent_chat_form.select_next_block
            end
            sync_agent_chat_workspace!
            cmd = was_detail_open && UI::Rendering::ChatRendering.glamour_render_pending? ? schedule_chat_render_poll : nil
            return [self, cmd]
          end
          if @agent_chat_form.prompt_focused? && @agent_chat_form.inquiry_active? &&
             @agent_chat_form.inquiry_form.picker?
            @agent_chat_form.inquiry_form.next_field
            sync_agent_chat_workspace!
            return [self, nil]
          end
        when "ctrl+s"
          return handle_inquiry_enter if @agent_chat_form&.inquiry_active?

          return save_agent_chat_form
        when "R"
          return request_rebuild_memory_for_chat! if @agent_chat_form.content_focused?
        when ","
          if @agent_chat_form.content_focused? && !@agent_chat_form.block_detail_open?
            @agent_chat_form.select_previous_block
            sync_agent_chat_workspace!
            return [self, nil]
          end
        when "."
          if @agent_chat_form.content_focused? && !@agent_chat_form.block_detail_open?
            @agent_chat_form.select_next_block
            sync_agent_chat_workspace!
            return [self, nil]
          end
        when "j", "down"
          if @agent_chat_form.content_focused? && !@agent_chat_form.block_detail_open?
            @agent_chat_form.select_next_block
            sync_agent_chat_workspace!
            return [self, nil]
          end
          if @agent_chat_form.content_focused? && @agent_chat_form.block_detail_open?
            @agent_chat_form.block_viewport.update(message)
            return [self, nil]
          end
          if @agent_chat_form.summary_focused?
            viewport = @agent_chat_form.summary_detail_open? ? @agent_chat_form.summary_detail_viewport : @agent_chat_form.summary_viewport
            viewport.update(message)
            return [self, nil]
          end
        when "k", "up"
          if @agent_chat_form.content_focused? && !@agent_chat_form.block_detail_open?
            @agent_chat_form.select_previous_block
            sync_agent_chat_workspace!
            return [self, nil]
          end
          if @agent_chat_form.content_focused? && @agent_chat_form.block_detail_open?
            @agent_chat_form.block_viewport.update(message)
            return [self, nil]
          end
          if @agent_chat_form.summary_focused?
            viewport = @agent_chat_form.summary_detail_open? ? @agent_chat_form.summary_detail_viewport : @agent_chat_form.summary_viewport
            viewport.update(message)
            return [self, nil]
          end
        when "j", "k", "up", "down", "g", "G", "pgdown", "pgup", "ctrl+f", "ctrl+b", "ctrl+d", "ctrl+u", "home", "end"
          if @agent_chat_form.content_focused?
            if @agent_chat_form.block_detail_open?
              @agent_chat_form.block_viewport.update(message)
            else
              @agent_chat_form.viewport.update(message)
            end
            return [self, nil]
          end
          if @agent_chat_form.summary_focused?
            viewport = @agent_chat_form.summary_detail_open? ? @agent_chat_form.summary_detail_viewport : @agent_chat_form.summary_viewport
            viewport.update(message)
            return [self, nil]
          end
        end
      end

      return [self, nil] unless @agent_chat_form.prompt_focused?

      composer = @agent_chat_form.composer
      picker = composer.skill_picker
      was_composer = @agent_chat_form.input_component == composer
      previous_value = was_composer ? composer.value : nil

      updated_input, command = @agent_chat_form.input_component.update_input(message)
      @agent_chat_form.input_component.instance_variable_set(:@input, updated_input) if was_composer

      sync_skill_picker_state!(picker, previous_value, composer) if was_composer && !@agent_chat_form.inquiry_active?

      sync_agent_chat_workspace!
      [self, command]
    end

    def handle_agent_attachments_detail_key(message)
      case message.to_s
      when "esc", "escape", "q"
        @agent_chat_form.close_attachments_detail
        sync_agent_chat_workspace!
        [self, nil]
      when "enter"
        open_selected_attachment
      when "j", "down"
        @agent_chat_form.select_next_attachment
        sync_agent_chat_workspace!
        [self, nil]
      when "k", "up"
        @agent_chat_form.select_previous_attachment
        sync_agent_chat_workspace!
        [self, nil]
      else
        [self, nil]
      end
    end

    def open_selected_attachment
      attachment = @agent_chat_form&.selected_attachment
      return [self, nil] unless attachment.is_a?(Hash)

      target = AttachmentNormalizer.attachment_target(attachment)
      return [self, nil] if target.empty?

      spawn_detached("open", resolved_attachment_target(target, @agent_chat_form.agent&.workspace))
      [self, nil]
    end

    def resolved_attachment_target(target, workspace)
      value = target.to_s.strip
      return value if value.match?(/\A[a-z][a-z0-9+.-]*:/i)

      base = workspace.to_s.empty? ? Dir.pwd : workspace.to_s
      value.start_with?("~") ? File.expand_path(value) : File.expand_path(value, base)
    end

    def handle_skill_picker_key(key)
      picker = @agent_chat_form.composer.skill_picker
      case key
      when "up", "ctrl+p"
        picker.move(-1)
        sync_agent_chat_workspace!
        [self, nil]
      when "down", "ctrl+n"
        picker.move(1)
        sync_agent_chat_workspace!
        [self, nil]
      when "tab", "enter"
        completion = picker.autocomplete_text
        if completion
          @agent_chat_form.composer.value = completion
          picker.close
        end
        sync_agent_chat_workspace!
        [self, nil]
      when "esc", "escape"
        picker.close
        sync_agent_chat_workspace!
        [self, nil]
      end
    end

    def sync_skill_picker_state!(picker, previous_value, composer)
      value = composer.value
      if picker.open?
        trigger = picker.trigger
        if value.start_with?(trigger)
          new_query = value[trigger.length..] || ""
          picker.update_query(new_query) if new_query != picker.query
        else
          picker.close
        end
        return
      end

      return unless previous_value.to_s.empty?

      trigger = HQ::SkillDiscovery.trigger_for(@agent_chat_form.agent.agent)
      return unless value == trigger

      picker.skills = @agent_chat_form.agent.skills
      picker.open(trigger: trigger)
    end

    def handle_inquiry_enter
      form = @agent_chat_form.inquiry_form

      unless form.review?
        form.next_field
        sync_agent_chat_workspace!
        return [self, nil]
      end

      if form.current_field.input.value == HQ::UI::InquiryForm::REVIEW_EDIT
        form.previous_field
        sync_agent_chat_workspace!
        return [self, nil]
      end

      unless form.submit_ready?
        form.error_message = if (error = form.validate)
                               error
                             else
                               "Pick Submit on the review step to send your answers"
                             end
        sync_agent_chat_workspace!
        return [self, nil]
      end

      save_agent_chat_form
    end

    def save_agent_chat_form
      if @agent_chat_form.inquiry_active?
        form = @agent_chat_form.inquiry_form
        if (error = form.validate)
          form.error_message = error
          sync_agent_chat_workspace!
          return [self, nil]
        end
        unless form.submit_ready?
          form.error_message = "Pick Submit on the review step to send your answers"
          sync_agent_chat_workspace!
          return [self, nil]
        end
      end

      content = @agent_chat_form.content
      return [self, nil] if content.empty?

      agent = @agent_chat_form.agent
      @agent_store.accept_delegation_prompt!(agent, owner: "user")
      agent.add_user_message!(content)
      @agent_chat_form.composer.clear unless @agent_chat_form.inquiry_active?
      save_agents!
      unless agent.running?
        replacement = @agent_store.start_agent!(agent.key)
        @agents[@agents.index { |item| item.key == agent.key }] = replacement
        @agent_chat_form.agent = replacement if @agent_chat_form.respond_to?(:agent=)
      end
      sync_agent_chat_workspace!(force_bottom: true)
      [self, schedule_action_poll]
    end

    def chat_placeholder_for(agent)
      inquiry = agent&.latest_inquiry
      return "Send a message..." unless inquiry

      properties = inquiry.dig("requested_schema", "properties")
      first_key, definition = properties.to_a.first
      return "Respond to the agent..." unless definition.is_a?(Hash)

      label = definition["title"].to_s.strip
      label = first_key.to_s.tr("_", " ").split.map(&:capitalize).join(" ") if label.empty?
      label.empty? ? "Respond to the agent..." : "#{label}..."
    end

    def project_name(key)
      project_for_key(key)&.name
    end

    def project_for_key(key)
      @projects.find { |project| project.key == key }
    end

    def sort_agents(agents)
      agents.sort_by.with_index do |agent, index|
        project_label = (project_name(agent.project_key) || "~Unlinked").to_s.downcase
        agent_label = agent.name.to_s.downcase
        [project_label, agent_label, index]
      end
    end
  end
end
