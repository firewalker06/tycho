# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "thread"
require "socket"
require "uri"

require_relative "harness_registry"
require_relative "log_file_reader"
require_relative "registry"
require_relative "remote_ui"
require_relative "terminal_qr"
require_relative "version"
require_relative "domain/tycho_updater"
require_relative "domain/project"
require_relative "domain/project_workspace"
require_relative "domain/attachment_normalizer"
require_relative "domain/constants"
require_relative "domain/agent_attachment_store"
require_relative "domain/agent_activity_snapshot"
require_relative "domain/agent_chat_log"
require_relative "domain/agent_store"
require_relative "domain/delegation_actor"
require_relative "domain/agent_archive_store"
require_relative "domain/executable_resolver"
require_relative "domain/file_store"
require_relative "domain/file_transaction"
require_relative "domain/git_diff"
require_relative "domain/harness_catalog"
require_relative "domain/push_notification_store"
require_relative "domain/push_subscription_store"
require_relative "domain/pull_request_diff"
require_relative "domain/pull_request_selection"
require_relative "domain/response_style_policy"
require_relative "domain/remote_credential_store"
require_relative "domain/schedule_daemon_supervisor"
require_relative "domain/scheduler"
require_relative "domain/server_identity"
require_relative "domain/skill_discovery"
require_relative "domain/skill_installer"
require_relative "domain/onboarding"
require_relative "domain/personal_assistant"
require_relative "domain/personal_assistant_actions"
require_relative "domain/visibility"
require_relative "domain/web_push_notifier"
require_relative "domain/usage_metrics"
require_relative "domain/remote_server_control"

module HQ
  class RemoteServer
    DEFAULT_HOST = "127.0.0.1"
    DEFAULT_PORT = 7373
    AGENT_PUSH_POLL_INTERVAL = 5
    ACTIVITY_AGENT_FIELDS = %i[
      key name project_key template_key scheduled schedule_key agent model reasoning_effort status running unread
      awaiting_input blocked run_count created_at started_at finished_at updated_at last_exit_code last_result summary
      archived archived_at delegation
    ].freeze
    REMOTE_DAEMON_LOG_FILE = File.join(LOGS_DIR, "remote_server_daemon.log")
    RESTART_CACHE_RESET_HEADERS = {
      "Cache-Control" => "no-store, max-age=0, must-revalidate",
      "Clear-Site-Data" => "\"cache\"",
      "Pragma" => "no-cache",
      "Expires" => "0"
    }.freeze

    class Error < StandardError
      attr_reader :status, :details

      def initialize(message, status: 400, details: nil)
        super(message)
        @status = status
        @details = details
      end
    end

    def initialize(host: DEFAULT_HOST, port: DEFAULT_PORT, public_url: nil, startup_messages: nil,
                   restart_command: nil, token: HQ.env("REMOTE_TOKEN"), logger: HQ.logger, output: $stdout,
                   daemonize_after_startup: false, daemon_log_path: REMOTE_DAEMON_LOG_FILE, daemonizer: nil,
                   resource_catalog: nil, resource_snapshot_path: nil, agent_activity_snapshot: nil)
      @host = host.to_s.empty? ? DEFAULT_HOST : host.to_s
      @port = port.to_i.positive? ? port.to_i : DEFAULT_PORT
      @public_url = public_url.to_s
      @startup_messages = Array(startup_messages).map(&:to_s).reject(&:empty?)
      @restart_command = Array(restart_command).map(&:to_s).reject(&:empty?)
      @token = token.to_s
      @logger = logger
      @output = output
      @daemonize_after_startup = daemonize_after_startup ? true : false
      @daemon_log_path = daemon_log_path.to_s.empty? ? REMOTE_DAEMON_LOG_FILE : daemon_log_path.to_s
      @daemonizer = daemonizer
      @resource_catalog = resource_catalog || RemoteResourceCatalog.new(snapshot_path: resource_snapshot_path)
      @agent_activity_snapshot = agent_activity_snapshot || AgentActivitySnapshot.new
    end

    def start
      server = TCPServer.new(@host, @port)
      @server = server
      RemoteServerControl.publish(host: @host, port: @port)
      @shutdown = false
      @restart_requested = false
      shutdown = proc do
        @shutdown = true
        begin
          server.close
        rescue IOError, SystemCallError
          nil
        end
      end
      trap("INT", &shutdown)
      trap("TERM", &shutdown)
      @startup_messages.each { |message| log_server(message) }
      if unauthenticated_non_loopback?
        log_server("Warning: TYCHO_REMOTE_TOKEN is unset while binding to #{@host}; set TYCHO_REMOTE_TOKEN before using Tycho Remote from another device")
      end
      log_server("Remote server listening on http://#{@host}:#{@port}")
      unless @public_url.empty?
        log_server("Remote UI available at #{@public_url}")
        log_server("Scan this QR code to open HQ Remote")
        @output.puts
        @output.puts(TerminalQR.render(@public_url))
        @output.flush if @output.respond_to?(:flush)
      end
      daemonize_after_startup! if @daemonize_after_startup
      warm_resource_catalog!

      until @shutdown
        begin
          if IO.select([server], nil, nil, 0.25)
            client = server.accept_nonblock
            handle_client(client)
          end
        rescue IO::WaitReadable
          nil
        rescue IOError, Errno::EBADF
          break if @shutdown
        end
        poll_agent_push_notifications! unless @shutdown
      end
    ensure
      RemoteServerControl.clear(host: @host, port: @port)
      server&.close unless server&.closed?
      @daemon_log_io&.close
      @server = nil
      perform_restart! if @restart_requested
    end

    private

    Request = Struct.new(:method, :path, :query, :headers, :body, keyword_init: true) do
      def [](key)
        headers[key.to_s.downcase]
      end

      def query_params
        @query_params ||= URI.decode_www_form(query.to_s).to_h
      end
    end

    def handle_client(client)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status = nil
      request = read_request(client)
      unless request
        status = 400
        write_http(client, status, error: "Bad request")
        return
      end

      if ui_request?(request)
        result = route_ui(request.path)
        status = result.fetch(:status, 200)
        write_http(client, status, result.fetch(:body, ""), content_type: result.fetch(:content_type),
                   headers: result.fetch(:headers, {}))
        return
      end

      unless authorized?(request)
        status = 401
        write_http(client, status, error: "Unauthorized")
        return
      end

      cached_read = if request.method == "GET" && request.path == "/servers/resources"
                      @resource_catalog.snapshot
                    elsif request.method == "GET" && request.path == "/servers/activity"
                      activity_catalog
                    elsif request.method == "GET" && request.path == "/activity"
                      @agent_activity_snapshot.snapshot
                    end
      if cached_read
        result = ok(cached_read)
        status = result.fetch(:status)
        write_http(client, status, result.fetch(:body))
        return
      end

      service = RemoteService.new(
        server_url: "http://#{@host}:#{@port}",
        public_url: @public_url,
        auth_required: !@token.empty?,
        restartable: restartable?,
        agent_activity_snapshot: @agent_activity_snapshot
      )
      result = route(service, request.method, request.path, json_body(request), request)
      status = result.fetch(:status, 200)
      write_http(client, status, result.fetch(:body, {}),
                 content_type: result.fetch(:content_type, "application/json"),
                 headers: result.fetch(:headers, {}))
    rescue Error => e
      status = e.status
      payload = { error: e.message }
      payload[:details] = e.details if e.details
      write_http(client, status, payload)
    rescue JSON::ParserError
      status = 400
      write_http(client, status, error: "Invalid JSON body")
    rescue StandardError => e
      status = 500
      label = request ? "#{request.method} #{request.path}" : "request"
      @logger.error("Remote") { "#{label}: #{e.class} - #{e.message}" }
      write_http(client, status, error: "Internal server error")
    ensure
      log_request(request, status || 500, started_at) if started_at
      client&.close
    end

    def daemonize_after_startup!
      FileUtils.mkdir_p(File.dirname(@daemon_log_path))
      log_server("Remote server daemonizing; logs at #{@daemon_log_path}")
      @output.flush if @output.respond_to?(:flush)
      daemonizer = @daemonizer || Process.method(:daemon)
      daemonizer.call(true, false)
      @daemon_log_io = File.open(@daemon_log_path, "ab")
      @daemon_log_io.sync = true
      @output = @daemon_log_io
      log_server("Remote server daemon started with PID #{Process.pid}")
    end

    def poll_agent_push_notifications!
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @last_agent_push_poll ||= now - AGENT_PUSH_POLL_INTERVAL
      return if now - @last_agent_push_poll < AGENT_PUSH_POLL_INTERVAL

      @last_agent_push_poll = now
      service = RemoteService.new(server_url: "http://#{@host}:#{@port}",
                                  public_url: @public_url,
                                  auth_required: !@token.empty?,
                                  agent_activity_snapshot: @agent_activity_snapshot)
      service.dispatch_agent_push_notifications!
    rescue StandardError => e
      HQ.logger.warn("Push") { "Agent push notification poll failed: #{e.class} - #{e.message}" }
    end

    def route(service, method, path, body, request = nil)
      parts = path.split("/").reject(&:empty?)
      actor = request_actor(body)

      if parts.first == "servers"
        broker = RemoteBroker.new(registry: service.registry, server_url: service.server_url)
        @resource_catalog.reconcile(registry: service.registry, server_url: service.server_url)
        return ok(servers: broker_servers(broker)) if method == "GET" && parts == ["servers"]
        return ok(activity_catalog) if method == "GET" && parts == ["servers", "activity"]
        return ok(@resource_catalog.snapshot) if method == "GET" && parts == ["servers", "resources"]
        if method == "POST" && parts == ["servers", "resources", "refresh"]
          tokens = body["tokens"].is_a?(Hash) ? body["tokens"] : {}
          refreshes = broker.servers.map do |server|
            @resource_catalog.refresh(
              server[:key],
              registry: service.registry,
              server_url: service.server_url,
              local_service: service,
              token_override: tokens[server[:key]].to_s,
              force: body["force"] == true
            )
          end
          return accepted({
            accepted: refreshes.any? { |refresh| refresh[:accepted] },
            refreshes: refreshes
          })
        end
        if method == "POST" && parts.length == 4 && parts[2, 2] == ["resources", "refresh"]
          return accepted(@resource_catalog.refresh(
                            parts[1],
                            registry: service.registry,
                            server_url: service.server_url,
                            local_service: service,
                            token_override: remote_server_token(request),
                            force: body["force"] == true
                          ))
        end
        if method == "DELETE" && parts.length == 3 && parts[2] == "resources"
          unless @resource_catalog.forget(parts[1])
            raise Error.new("Unknown peer server: #{parts[1]}", status: 404)
          end

          return ok(@resource_catalog.snapshot)
        end
        if method == "POST" && parts.length == 3 && parts[2] == "credentials"
          result = service.save_remote_server_credential(parts[1], body)
          @resource_catalog.reconcile(registry: service.registry, server_url: service.server_url)
          return ok(enrich_server_response(result))
        end
        if method == "POST" && parts == ["servers"]
          result = service.add_remote_server(body)
          @resource_catalog.reconcile(registry: service.registry, server_url: service.server_url)
          return created(enrich_server_response(result))
        end
        if method == "PATCH" && parts.length == 2
          result = service.update_remote_server(parts[1], body)
          @resource_catalog.reconcile(registry: service.registry, server_url: service.server_url)
          return ok(enrich_server_response(result))
        end
        if method == "DELETE" && parts.length == 2
          result = service.remove_remote_server(parts[1])
          @resource_catalog.reconcile(registry: service.registry, server_url: service.server_url)
          return ok(result)
        end
        if parts.length >= 3 && RemoteBroker::RESOURCE_ROOTS.include?(parts[2])
          resource_path = "/#{parts.drop(2).join("/")}"
          return broker.proxy(parts[1], method, resource_path, body, request)
        end
        if parts.length >= 3 && parts[2] == "proxy"
          proxy_path = "/#{parts.drop(3).join("/")}"
          proxy_path = "/" if proxy_path == "/"
          return broker.proxy(parts[1], method, proxy_path, body, request)
        end
      end
      return ok(service.agent_activity) if method == "GET" && parts == ["activity"]
      return ok(personal_assistant: service.personal_assistant) if method == "GET" && parts == ["personal-assistant"]
      return ok(personal_assistant: service.setup_personal_assistant(body)) if method == "POST" && parts == ["personal-assistant", "setup"]
      return ok(personal_assistant: service.open_personal_assistant) if method == "POST" && parts == ["personal-assistant", "open"]
      return ok(personal_assistant: service.reset_personal_assistant(body)) if method == "POST" && parts == ["personal-assistant", "reset"]
      return ok(service.submit_personal_assistant_prompt(body, actor:)) if method == "POST" && parts == ["personal-assistant", "messages"]
      return ok(proposals: service.personal_assistant_actions) if method == "GET" && parts == ["personal-assistant", "actions"]
      if method == "POST" && parts.length == 4 && parts[0, 2] == ["personal-assistant", "actions"] && parts[3] == "confirm"
        return ok(proposal: service.confirm_personal_assistant_action(parts[2], body))
      end
      if method == "POST" && parts.length == 4 && parts[0, 2] == ["personal-assistant", "actions"] && parts[3] == "reject"
        return ok(proposal: service.reject_personal_assistant_action(parts[2]))
      end
      return ok(service.resource_snapshot) if method == "GET" && parts == ["resources"]
      return ok(service.metrics_query(request&.query_params || {})) if method == "GET" && parts == ["metrics"]
      return ok(service.metrics_backfill(body)) if method == "POST" && parts == ["metrics", "backfill"]
      if method == "GET" && parts == ["agents", "archived"]
        return ok(service.archived_agents(request&.query_params || {}))
      end
      return ok(agents: service.agents) if method == "GET" && parts == ["agents"]
      return created(agent: service.create_agent(body, actor:)) if method == "POST" && parts == ["agents"]
      return ok(schedules: service.schedules, daemon: service.schedule_daemon) if method == "GET" && parts == ["schedules"]
      return created(schedule: service.create_schedule(body)) if method == "POST" && parts == ["schedules"]
      return ok(service.reload_schedules) if method == "POST" && parts == ["schedules", "reload"]
      return accepted(service.start_schedule_daemon(body)) if method == "POST" && parts == ["schedules", "daemon", "start"]
      return accepted(service.stop_schedule_daemon) if method == "POST" && parts == ["schedules", "daemon", "stop"]
      return accepted(service.restart_schedule_daemon(body)) if method == "POST" && parts == ["schedules", "daemon", "restart"]
      return ok(service.archive_agents(body)) if method == "POST" && parts == ["agents", "archive"]
      return ok(projects: service.projects) if method == "GET" && parts == ["projects"]
      return ok(skill_installation: service.skill_installation) if method == "GET" && parts == ["skills"]
      if method == "POST" && parts.length == 3 && parts.first == "skills" && %w[install update].include?(parts[2])
        return ok(service.change_skills(parts[1], parts[2], body))
      end
      return created(project: service.create_welcome_project) if method == "POST" && parts == ["setup", "welcome"]
      return ok(setup: service.refresh_harnesses) if method == "POST" && parts == ["setup", "harnesses", "refresh"]
      if %w[PATCH PUT].include?(method) && parts.length == 4 && parts[0, 2] == ["setup", "harnesses"] && parts[3] == "catalog"
        return ok(setup: service.update_harness_catalog(parts[2], body))
      end
      return ok(hidden: service.hidden_settings) if method == "GET" && parts == ["settings", "hidden"]
      return ok(hidden: service.update_hidden_setting(body)) if %w[PATCH PUT].include?(method) && parts == ["settings", "hidden"]
      return ok(session_loops: service.session_loop_settings) if method == "GET" && parts == ["settings", "session-loops"]
      if %w[PATCH PUT].include?(method) && parts == ["settings", "session-loops"]
        return ok(session_loops: service.update_session_loop_settings(body))
      end
      if %w[PATCH PUT].include?(method) && parts == ["settings", "session-loops", "defaults"]
        return ok(session_loops: service.update_session_loop_defaults(body))
      end
      if %w[PATCH PUT].include?(method) && parts == ["settings", "session-loops", "prompt-templates"]
        return ok(session_loops: service.update_session_loop_prompt_templates(body))
      end
      return ok(response_style: service.response_style) if method == "GET" && parts == ["settings", "response-style"]
      if %w[PATCH PUT].include?(method) && parts == ["settings", "response-style"]
        return ok(response_style: service.update_response_style(body))
      end
      if method == "DELETE" && parts == ["settings", "response-style"]
        return ok(response_style: service.delete_response_style)
      end
      return ok(setup: service.setup) if method == "GET" && parts == ["setup"]
      return ok(service.search_index) if method == "GET" && parts == ["search"]
      return ok(service.memory_handoffs) if method == "GET" && parts == ["memory-handoffs"]
      return accepted(update_and_restart!(service), headers: RESTART_CACHE_RESET_HEADERS) if method == "POST" && parts == ["update"]
      return accepted(schedule_restart!, headers: RESTART_CACHE_RESET_HEADERS) if method == "POST" && parts == ["server", "restart"]
      return ok(service.push_config) if method == "GET" && parts == ["push", "config"]
      return ok(service.push_status(body)) if method == "POST" && parts == ["push", "status"]
      return service.attachment_blob(parts[1]) if method == "GET" && parts.length == 3 && parts.first == "attachments" && parts[2] == "blob"
      return ok(service.delete_attachment(parts[1])) if method == "DELETE" && parts.length == 2 && parts.first == "attachments"
      return ok(attachment: service.attachment(parts[1])) if method == "GET" && parts.length == 2 && parts.first == "attachments"
      if parts == ["push", "subscriptions"]
        return created(service.save_push_subscription(body, user_agent: request&.[]("User-Agent"))) if method == "POST"
        return ok(service.disable_push_subscription(body)) if method == "DELETE"
      end
      return ok(service.send_test_push(body)) if method == "POST" && parts == ["push", "test"]

      if parts.length >= 2 && parts.first == "agents"
        key = parts[1]
        tail = parts.drop(2)
        return ok(agent: service.agent(key)) if method == "GET" && tail.empty?
        return ok(agent: service.update_agent(key, body)) if %w[PATCH PUT].include?(method) && tail.empty?
        return ok(service.update_agent_delegation(key, body)) if %w[PATCH PUT].include?(method) && tail == ["delegation"]
        return ok(service.archive_agent(key)) if method == "DELETE" && tail.empty?
        return created(service.create_agent_loop(key, body)) if method == "POST" && tail == ["loop-schedule"]
        return ok(conversation: service.conversation(key)) if method == "GET" && tail == ["conversation"]
        return ok(debug: service.agent_debug(key)) if method == "GET" && tail == ["debug"]
        return ok(log: service.agent_log(key, request&.query_params || {})) if method == "GET" && tail == ["logs"]
        if method == "POST" && tail == ["memory", "capture", "dry-run"]
          return ok(memory_capture: service.agent_memory_capture_dry_run(key))
        end
        if method == "POST" && tail == ["memory", "rebuild"]
          return ok(memory_rebuild: service.rebuild_agent_memory(key))
        end
        return ok(pull_requests: service.agent_pull_requests(key)) if method == "GET" && tail == ["pull-requests"]
        if method == "POST" && tail == ["pull-requests", "metadata", "refresh"]
          return ok(service.refresh_agent_pull_request_metadata(key))
        end
        return ok(service.refresh_agent_pull_requests(key)) if method == "POST" && tail == ["pull-requests", "refresh"]
        if tail.length == 3 && tail.first == "pull-requests" && tail[2] == "diff"
          return ok(diff: service.agent_pull_request_diff(key, tail[1])) if method == "GET"
        end
        if tail.length == 3 && tail.first == "pull-requests" && tail[2] == "refresh"
          return ok(diff: service.refresh_agent_pull_request_diff(key, tail[1])) if method == "POST"
        end
        return ok(agent: service.mark_agent_read(key)) if method == "PUT" && tail == ["reading"]
        if method == "POST" && tail.length == 3 && tail.first == "inquiries" && tail[2] == "answer"
          return ok(service.answer_inquiry(key, tail[1], body, actor:))
        end
        if method == "POST" && tail.length == 3 && tail.first == "inquiries" && tail[2] == "dismiss"
          return ok(service.dismiss_inquiry(key, tail[1], actor:))
        end
        if method == "POST" && tail.length == 3 && tail.first == "inquiries" && tail[2] == "restore"
          return ok(service.restore_inquiry(key, tail[1], actor:))
        end
        if tail.length == 2 && tail.first == "prompt-queue"
          return ok(service.edit_queued_prompt(key, tail[1], body)) if %w[PATCH PUT].include?(method)
          return ok(service.delete_queued_prompt(key, tail[1])) if method == "DELETE"
        end
        return ok(service.retry_prompt_queue(key)) if method == "POST" && tail == ["prompt-queue", "retry"]
        return ok(service.submit_prompt(key, body, actor:)) if method == "POST" && [%w[messages], %w[prompt]].include?(tail)
        return ok(service.start_agent(key, body, actor:)) if method == "POST" && tail == ["start"]
        return ok(service.stop_agent(key)) if method == "POST" && tail == ["stop"]
        return created(service.clone_agent(key, body)) if method == "POST" && tail == ["clone"]
        return ok(service.archive_agent(key)) if method == "POST" && tail == ["archive"]
      end

      if parts.length >= 2 && parts.first == "schedules"
        key = parts[1]
        tail = parts.drop(2)
        return ok(message: service.schedule_message(key)) if method == "GET" && tail == ["message"]
        return ok(message: service.update_schedule_message(key, body)) if %w[PATCH PUT].include?(method) && tail == ["message"]
        return ok(schedule: service.schedule(key)) if method == "GET" && tail.empty?
        return ok(service.schedule_message_file(key, request: request)) if method == "GET" && tail == ["message_file"]
        return ok(schedule: service.update_schedule(key, body)) if %w[PATCH PUT].include?(method) && tail.empty?
        return ok(service.update_schedule_message_file(key, body)) if method == "PUT" && tail == ["message_file"]
        return ok(service.delete_schedule(key)) if method == "DELETE" && tail.empty?
        return ok(service.run_schedule(key)) if method == "POST" && tail == ["run"]
        return ok(service.refresh_schedule_session(key)) if method == "POST" && tail == ["refresh-session"]
        return ok(schedule: service.pause_schedule(key)) if method == "POST" && tail == ["pause"]
        return ok(service.resume_schedule(key)) if method == "POST" && tail == ["resume"]
        return ok(service.resume_and_run_schedule(key)) if method == "POST" && tail == ["resume-and-run"]
      end

      if parts.length >= 2 && parts.first == "projects"
        key = parts[1]
        tail = parts.drop(2)
        return ok(project: service.project(key)) if method == "GET" && tail.empty?
        return ok(project: service.update_project(key, body)) if %w[PATCH PUT].include?(method) && tail.empty?
        if method == "GET" && tail == ["workspace"]
          return ok(workspace: service.project_workspace(key, request&.query_params || {}))
        end
        if method == "GET" && tail == ["workspace", "preview"]
          return ok(preview: service.project_workspace_preview(key, request&.query_params || {}))
        end
        if method == "GET" && tail == ["workspace", "image"]
          return service.project_workspace_image(key, request&.query_params || {})
        end
        if method == "PUT" && tail == ["workspace", "file"]
          return ok(preview: service.update_project_workspace_file(key, body))
        end
        return ok(git: service.project_git_status(key)) if method == "GET" && tail == ["git", "status"]
        if method == "GET" && tail[0, 2] == ["git", "diff"] && tail.length <= 3
          return ok(diff: service.project_git_diff(key, scope: tail[2] || request&.query_params&.fetch("scope", nil)))
        end
        return ok(service.skills(key, tail[1])) if method == "GET" && tail.length == 2 && tail.first == "skills"
      end

      raise Error.new("Not found", status: 404)
    end

    def activity_catalog
      local = @agent_activity_snapshot.snapshot
      catalog = @resource_catalog.snapshot
      servers = Array(catalog[:servers]).map do |server|
        source_agents = if server[:local] && local[:ready]
                          local[:agents]
                        else
                          Array(server[:agents])
                        end
        agents = source_agents.map { |agent| agent.slice(*ACTIVITY_AGENT_FIELDS) }
        {
          key: server[:key],
          name: server[:name],
          icon: server[:icon],
          local: server[:local],
          status: server[:status],
          stale: server[:stale],
          ready: server[:local] ? local[:ready] : !server[:last_success_at].nil?,
          agents: agents
        }
      end
      activity = {
        schema_version: AgentActivitySnapshot::SCHEMA_VERSION,
        generated_at: Time.now.utc.iso8601,
        unread_count: servers.sum { |server| server[:agents].count { |agent| agent[:unread] } },
        servers: servers
      }
      activity[:revision] = Digest::SHA256.hexdigest(JSON.generate(activity.except(:generated_at)))
      activity
    end

    def broker_servers(broker)
      enrich_servers(broker.servers)
    end

    def enrich_server_response(result)
      servers = enrich_servers(result.fetch(:servers, []))
      server = result[:server]
      enriched_server = servers.find { |entry| entry[:key] == server[:key] } if server
      result.merge(servers: servers, server: enriched_server || server)
    end

    def enrich_servers(servers)
      catalog_versions = @resource_catalog.snapshot.fetch(:servers, []).to_h do |server|
        [server[:key], server[:version]]
      end
      servers.map do |server|
        version = catalog_versions[server[:key]]
        version.to_s.empty? ? server : server.merge(version: version)
      end
    end

    def update_and_restart!(service)
      update = service.update_tycho
      scheduler = service.restart_running_schedule_daemon(command: [update.fetch(:executable), "schedule", "daemon"])
      schedule_restart!.merge(update: update, scheduler: scheduler)
    end

    def route_ui(path)
      case path
      when "/", "/ui", "/ui/"
        ui_asset("text/html; charset=utf-8", RemoteUI.index)
      when "/design-system", "/design-system/"
        ui_asset("text/html; charset=utf-8", RemoteUI.design_system_index)
      when "/ui.css"
        ui_asset("text/css; charset=utf-8", RemoteUI.css)
      when "/ui-helpers.js"
        ui_asset("application/javascript; charset=utf-8", RemoteUI.helpers_js)
      when "/ui.js"
        ui_asset("application/javascript; charset=utf-8", RemoteUI.js)
      when "/service-worker.js"
        ui_asset(
          "application/javascript; charset=utf-8",
          RemoteUI.service_worker_js,
          headers: {
            "Cache-Control" => "no-cache, max-age=0, must-revalidate",
            "Service-Worker-Allowed" => "/"
          }
        )
      when "/manifest.webmanifest"
        ui_asset("application/manifest+json; charset=utf-8", RemoteUI.manifest_json)
      when "/remote-logo.png", "/favicon.png", "/favicon.ico"
        ui_asset("image/png", RemoteUI.png_asset("remote-logo"))
      when "/remote-logo-horizontal.png"
        ui_asset("image/png", RemoteUI.png_asset("remote-logo-horizontal"))
      when "/apple-touch-icon.png"
        ui_asset("image/png", RemoteUI.png_asset("apple-touch-icon"))
      when "/pwa-icon-192.png"
        ui_asset("image/png", RemoteUI.png_asset("pwa-icon-192"))
      when "/pwa-icon-512.png"
        ui_asset("image/png", RemoteUI.png_asset("pwa-icon-512"))
      when "/pwa-icon-maskable-512.png"
        ui_asset("image/png", RemoteUI.png_asset("pwa-icon-maskable-512"))
      when "/fred-avatar.png"
        ui_asset("image/png", RemoteUI.png_asset("fred-avatar"))
      when "/favicon.svg"
        ui_asset("image/svg+xml; charset=utf-8", RemoteUI.favicon_svg)
      else
        raise Error.new("Not found", status: 404)
      end
    end

    def ui_asset(content_type, body, headers: {})
      {
        status: 200,
        content_type: content_type,
        body: body,
        headers: { "X-Tycho-Asset-Version" => RemoteUI.asset_version }.merge(headers)
      }
    end

    def ui_request?(request)
      request.method == "GET" && [
        "/",
        "/ui",
        "/ui/",
        "/design-system",
        "/design-system/",
        "/ui.css",
        "/ui-helpers.js",
        "/ui.js",
        "/service-worker.js",
        "/manifest.webmanifest",
        "/remote-logo.png",
        "/remote-logo-horizontal.png",
        "/apple-touch-icon.png",
        "/pwa-icon-192.png",
        "/pwa-icon-512.png",
        "/pwa-icon-maskable-512.png",
        "/fred-avatar.png",
        "/favicon.png",
        "/favicon.svg",
        "/favicon.ico"
      ].include?(request.path)
    end

    def authorized?(request)
      return true if @token.empty?

      auth = request["Authorization"].to_s
      token = auth.sub(/\ABearer\s+/i, "")
      token == @token
    end

    def unauthenticated_non_loopback?
      @token.empty? && !loopback_host?(@host)
    end

    def loopback_host?(host)
      value = host.to_s.downcase
      value == "localhost" || value == "::1" || value.start_with?("127.")
    end

    def json_body(request)
      raw = request.body.to_s
      return {} if raw.strip.empty?

      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed : {}
    end

    def ok(body)
      { status: 200, body: body }
    end

    def accepted(body, headers: {})
      { status: 202, body: body, headers: headers }
    end

    def created(body)
      { status: 201, body: body }
    end

    def restartable?
      !@restart_command.empty?
    end

    def schedule_restart!
      raise Error.new("Remote restart is unavailable for this host", status: 409) unless restartable?

      @restart_command = TychoUpdater.stable_command(@restart_command)
      @restart_requested = true
      @shutdown = true
      close_listener!
      {
        restarting: true,
        command: @restart_command.first
      }
    end

    def close_listener!
      listener = @server
      return unless listener
      return if listener.closed?

      listener.close
    rescue IOError, SystemCallError
      nil
    end

    def perform_restart!
      command = @restart_command
      return if command.empty?

      log_server("Restarting Remote server via #{command.join(" ")}")
      exec(*command)
    end

    def read_request(client)
      request_line = client.gets&.strip
      return nil if request_line.to_s.empty?

      method, raw_path, _version = request_line.split(/\s+/, 3)
      headers = {}
      while (line = client.gets)
        line = line.chomp
        break if line.empty?

        name, value = line.split(":", 2)
        headers[name.to_s.downcase] = value.to_s.strip unless name.to_s.empty?
      end
      body = client.read(headers["content-length"].to_i).to_s
      path, query = raw_path.to_s.split("?", 2)
      Request.new(method: method.to_s.upcase, path: path, query: query.to_s, headers: headers, body: body)
    end

    def write_http(client, status, body = nil, content_type: "application/json", headers: {}, **payload)
      body = payload if body.nil? && !payload.empty?
      content = content_type.start_with?("application/json") ? JSON.pretty_generate(body) : body.to_s
      reason = reason_phrase(status)
      response_headers = headers
      client.write "HTTP/1.1 #{status} #{reason}\r\n"
      client.write "Content-Type: #{content_type}\r\n"
      client.write "Content-Length: #{content.bytesize}\r\n"
      response_headers.each { |name, value| client.write "#{name}: #{value}\r\n" }
      client.write "Connection: close\r\n"
      client.write "\r\n"
      client.write content
    rescue IOError, SystemCallError
      nil
    end

    def log_request(request, status, started_at)
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)
      line = if request
               "#{request.method} #{request.path} #{status} #{elapsed_ms}ms"
             else
               "bad_request #{status} #{elapsed_ms}ms"
             end
      log_server(line)
    rescue StandardError
      nil
    end

    def warm_resource_catalog!
      service = RemoteService.new(
        server_url: "http://#{@host}:#{@port}",
        public_url: @public_url,
        auth_required: !@token.empty?,
        restartable: restartable?,
        agent_activity_snapshot: @agent_activity_snapshot
      )
      @resource_catalog.reconcile(registry: service.registry, server_url: service.server_url)
      @resource_catalog.refresh(
        "local",
        registry: service.registry,
        server_url: service.server_url,
        local_service: service
      )
    rescue StandardError => e
      HQ.logger.warn("RemoteResources") { "Initial local resource refresh failed: #{e.class} - #{e.message}" }
    end

    def remote_server_token(request)
      request&.[]("X-Tycho-Remote-Server-Token").to_s
    end

    def request_actor(body)
      parent_key = body.is_a?(Hash) ? body["parent_agent_key"].to_s.strip : ""
      return DelegationActor.user_actor if parent_key.empty?

      DelegationActor.parent_actor(parent_key)
    end

    def log_server(line)
      @logger.info("Remote") { line }
      @output.puts("[Remote] #{Time.now.strftime("%H:%M:%S")} #{line}")
      @output.flush if @output.respond_to?(:flush)
    rescue StandardError
      nil
    end

    def reason_phrase(status)
      {
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        413 => "Content Too Large",
        415 => "Unsupported Media Type",
        502 => "Bad Gateway",
        504 => "Gateway Timeout",
        500 => "Internal Server Error"
      }.fetch(status, "OK")
    end
  end

  class RemoteResourceCatalog
    SCHEMA_VERSION = 1
    SNAPSHOT_SCHEMA_VERSION = 1
    MAX_WORKERS = 4
    OPEN_TIMEOUT = 0.5
    READ_TIMEOUT = 1.0
    REFRESH_INTERVAL_SECONDS = 2
    FAILURE_BACKOFF_SECONDS = [2, 5, 15, 30, 60].freeze

    LocalConfig = Struct.new(:key, :name, :url, keyword_init: true) do
      def resolved_token
        ""
      end
    end

    def initialize(max_workers: MAX_WORKERS, logger: HQ.logger, snapshot_path: nil)
      @logger = logger
      @max_workers = [max_workers.to_i, 1].max
      @snapshot_path = snapshot_path.to_s.strip
      @snapshot_path = nil if @snapshot_path.empty?
      @mutex = Mutex.new
      @worker_mutex = Mutex.new
      @persistence_mutex = Mutex.new
      @entries = {}
      @inflight = {}
      @revision = 0
      @queue = Queue.new
      @workers = nil
      @persisted_entries = load_persisted_entries
    end

    def reconcile(registry:, server_url:)
      credential_resolver = RemoteCredentialResolver.new(store: RemoteCredentialStore.new(registry: registry))
      configs = [
        LocalConfig.new(key: "local", name: "Local", url: server_url.to_s)
      ] + Array(registry.remote_servers)
      next_keys = configs.map(&:key)

      persistence_changed = false
      @mutex.synchronize do
        removed_keys = @entries.keys - next_keys
        removed_persisted_keys = @persisted_entries.keys - next_keys
        @entries.delete_if { |key, _entry| removed_keys.include?(key) }
        @inflight.delete_if { |key, _value| !next_keys.include?(key) }
        removed_persisted_keys.each { |key| @persisted_entries.delete(key) }
        persistence_changed = removed_persisted_keys.any?
        configs.each_with_index do |config, index|
          existing = @entries[config.key]
          existing = nil if existing && existing[:url].to_s != config.url.to_s
          metadata = {
            key: config.key,
            name: config.name,
            icon: index.zero? ? "home" : config.icon,
            url: config.url,
            local: index.zero?,
            auth_configured: index.zero? ? false : credential_resolver.configured?(config),
            version: index.zero? ? HQ::VERSION : existing&.fetch(:version, nil)
          }
          persisted = @persisted_entries[config.key]
          if persisted && !valid_persisted_entry?(persisted, metadata)
            @persisted_entries.delete(config.key)
            persisted = nil
            persistence_changed = true
          end
          @entries[config.key] = if existing
                                   existing.merge(metadata)
                                 else
                                   restored_entry(metadata, persisted)
                                 end
        end
      end
      persist_peer_snapshots! if persistence_changed
    end

    def snapshot
      @mutex.synchronize do
        servers = @entries.values
                          .sort_by { |entry| [entry[:local] ? 0 : 1, entry[:name].to_s.downcase, entry[:key]] }
                          .map { |entry| entry.merge(retry_after_ms: retry_after_ms(entry)) }
        deep_copy(
          schema_version: SCHEMA_VERSION,
          revision: @revision,
          generated_at: Time.now.iso8601,
          servers: servers
        )
      end
    end

    def forget(key)
      forgotten = false
      @mutex.synchronize do
        entry = @entries[key.to_s]
        return false unless entry && !entry[:local]

        @entries[key.to_s] = entry.merge(
          last_success_at: nil,
          stale: false,
          resource_mode: nil,
          agents: [],
          projects: []
        )
        @persisted_entries.delete(key.to_s)
        @revision += 1
        forgotten = true
      end
      persist_peer_snapshots! if forgotten
      forgotten
    end

    def refresh(key, registry:, server_url:, local_service:, token_override: nil, force: false)
      ensure_workers!
      reconcile(registry:, server_url:)
      server_key = key.to_s
      config = config_for(server_key, registry:, server_url:)

      @mutex.synchronize do
        raise RemoteServer::Error.new("Unknown remote server: #{server_key}", status: 404) unless @entries.key?(server_key)

        if @inflight[server_key]
          return {
            accepted: false,
            server_key: server_key,
            revision: @revision,
            retry_after_ms: 0
          }
        end

        entry = @entries.fetch(server_key)
        retry_after = retry_after_ms(entry)
        if !force && retry_after.positive?
          return {
            accepted: false,
            server_key: server_key,
            revision: @revision,
            retry_after_ms: retry_after
          }
        end

        @inflight[server_key] = true
        @entries[server_key] = entry.merge(refreshing: true)
        @revision += 1
      end
      @queue << {
        key: server_key,
        config: config,
        local_service: server_key == "local" ? local_service : nil,
        token_override: token_override.to_s,
        credential_resolver: RemoteCredentialResolver.new(store: RemoteCredentialStore.new(registry: registry))
      }
      refresh_payload(server_key, accepted: true)
    end

    private

    def ensure_workers!
      @worker_mutex.synchronize do
        return if @workers

        @workers = Array.new(@max_workers) do
          Thread.new do
            loop { perform_refresh(@queue.pop) }
          rescue StandardError => e
            @logger.error("RemoteResources") { "Refresh worker stopped: #{e.class} - #{e.message}" }
          end
        end
      end
    end

    def perform_refresh(job)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = fetch_snapshot(job)
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      if result[:success]
        record_success(job[:key], result, elapsed_ms)
      else
        record_failure(job[:key], result, elapsed_ms)
      end
    rescue StandardError => e
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      record_failure(job[:key], { category: "offline", error: e.class.name }, elapsed_ms)
    ensure
      job[:token_override] = nil if job
    end

    def fetch_snapshot(job)
      if job[:local_service]
        return successful_snapshot(job[:local_service].resource_snapshot, mode: "native")
      end

      client = RemoteClient.new(
        job.fetch(:config),
        open_timeout: OPEN_TIMEOUT,
        read_timeout: READ_TIMEOUT,
        token_override: job[:token_override],
        credential_resolver: job[:credential_resolver]
      )
      response = client.request("GET", "/resources")
      return legacy_snapshot(client) if response[:status].to_i == 404
      return failed_response(response) unless response[:status].to_i.between?(200, 299)

      successful_snapshot(response[:body], mode: "native")
    end

    def legacy_snapshot(client)
      agents = client.request("GET", "/agents")
      return failed_response(agents) unless agents[:status].to_i.between?(200, 299)

      projects = client.request("GET", "/projects")
      return failed_response(projects) unless projects[:status].to_i.between?(200, 299)

      successful_snapshot(
        {
          "schema_version" => SCHEMA_VERSION,
          "agents" => value_for(agents[:body], "agents"),
          "projects" => value_for(projects[:body], "projects")
        },
        mode: "legacy"
      )
    end

    def successful_snapshot(payload, mode:)
      version = value_for(payload, "schema_version").to_i
      unless version == SCHEMA_VERSION
        return {
          success: false,
          category: "incompatible",
          error: "unsupported resource schema #{version}"
        }
      end

      agents = value_for(payload, "agents")
      projects = value_for(payload, "projects")
      unless agents.is_a?(Array) && projects.is_a?(Array) &&
             agents.all?(Hash) && projects.all?(Hash)
        return {
          success: false,
          category: "incompatible",
          error: "resource snapshot must contain complete agent and project arrays"
        }
      end
      {
        success: true,
        version: resource_version(payload),
        agents: agents,
        projects: projects,
        resource_mode: mode
      }
    end

    def failed_response(response)
      error = value_for(response[:body], "error").to_s
      category = if error.include?("rejected broker credentials")
                   "unauthorized"
                 elsif response[:status].to_i == 504
                   "timeout"
                 else
                   "offline"
                 end
      { success: false, category: category, error: error }
    end

    def record_success(key, result, elapsed_ms)
      now = Time.now.iso8601
      persist = false
      @mutex.synchronize do
        entry = @entries[key]
        return unless entry

        persist = !entry[:local]
        @entries[key] = entry.merge(
          status: "online",
          latency_ms: elapsed_ms,
          last_checked_at: now,
          last_success_at: now,
          stale: false,
          refreshing: false,
          error: nil,
          failure_count: 0,
          next_refresh_at: (Time.now + REFRESH_INTERVAL_SECONDS).iso8601,
          retry_after_ms: REFRESH_INTERVAL_SECONDS * 1000,
          resource_mode: result[:resource_mode],
          version: result[:version],
          agents: decorate_resources(result[:agents], entry, kind: "agent"),
          projects: decorate_resources(result[:projects], entry, kind: "project")
        )
        @inflight.delete(key)
        @revision += 1
      end
      persist_peer_snapshots! if persist
      @logger.info("RemoteResources") { "#{key} refreshed in #{elapsed_ms}ms" }
    end

    def record_failure(key, result, elapsed_ms)
      now = Time.now.iso8601
      @mutex.synchronize do
        entry = @entries[key]
        return unless entry

        status = result[:category] == "unauthorized" ? "unauthorized" : "offline"
        failure_count = entry[:failure_count].to_i + 1
        backoff = FAILURE_BACKOFF_SECONDS.fetch(
          [failure_count - 1, FAILURE_BACKOFF_SECONDS.length - 1].min
        )
        @entries[key] = entry.merge(
          status: status,
          latency_ms: elapsed_ms,
          last_checked_at: now,
          stale: !entry[:last_success_at].nil?,
          refreshing: false,
          error: result[:category].to_s,
          failure_count: failure_count,
          next_refresh_at: (Time.now + backoff).iso8601,
          retry_after_ms: backoff * 1000
        )
        @inflight.delete(key)
        @revision += 1
      end
      @logger.warn("RemoteResources") { "#{key} refresh #{result[:category]} after #{elapsed_ms}ms" }
    end

    def decorate_resources(resources, entry, kind:)
      Array(resources).filter_map do |resource|
        next unless resource.is_a?(Hash)

        normalized = resource.each_with_object({}) { |(key, value), result| result[key.to_sym] = value }
        normalized.merge(
          server_key: entry[:key],
          server_name: entry[:name],
          server_local: entry[:local],
          resource_kind: kind
        )
      end
    end

    def empty_entry(metadata)
      metadata.merge(
        status: "loading",
        latency_ms: nil,
        last_checked_at: nil,
        last_success_at: nil,
        stale: false,
        refreshing: false,
        error: nil,
        failure_count: 0,
        next_refresh_at: nil,
        retry_after_ms: 0,
        resource_mode: nil,
        agents: [],
        projects: []
      )
    end

    def restored_entry(metadata, persisted)
      entry = empty_entry(metadata)
      return entry unless valid_persisted_entry?(persisted, metadata)

      entry.merge(
        last_success_at: value_for(persisted, "last_success_at"),
        stale: true,
        version: value_for(persisted, "version"),
        resource_mode: value_for(persisted, "resource_mode"),
        agents: decorate_resources(value_for(persisted, "agents"), metadata, kind: "agent"),
        projects: decorate_resources(value_for(persisted, "projects"), metadata, kind: "project")
      )
    end

    def load_persisted_entries
      return {} unless @snapshot_path

      payload = FileStore.read_json(@snapshot_path, fallback: {})
      return {} unless value_for(payload, "schema_version").to_i == SNAPSHOT_SCHEMA_VERSION

      Array(value_for(payload, "servers")).each_with_object({}) do |entry, result|
        next unless entry.is_a?(Hash)

        key = value_for(entry, "key").to_s
        next if key.empty? || key == "local"

        result[key] = entry
      end
    rescue StandardError => e
      @logger.warn("RemoteResources") do
        "Failed to load persisted resource snapshots: #{e.class} - #{e.message}"
      end
      {}
    end

    def valid_persisted_entry?(persisted, metadata)
      return false unless persisted.is_a?(Hash)
      return false unless value_for(persisted, "key").to_s == metadata[:key].to_s
      return false unless value_for(persisted, "url").to_s == metadata[:url].to_s
      return false if value_for(persisted, "last_success_at").to_s.empty?

      agents = value_for(persisted, "agents")
      projects = value_for(persisted, "projects")
      agents.is_a?(Array) && projects.is_a?(Array) &&
        agents.all?(Hash) && projects.all?(Hash)
    end

    def persist_peer_snapshots!
      return unless @snapshot_path

      @persistence_mutex.synchronize do
        payload = @mutex.synchronize do
          {
            schema_version: SNAPSHOT_SCHEMA_VERSION,
            saved_at: Time.now.iso8601,
            servers: @entries.values.filter_map do |entry|
              next if entry[:local] || entry[:last_success_at].to_s.empty?

              {
                key: entry[:key],
                url: entry[:url],
                version: entry[:version],
                last_success_at: entry[:last_success_at],
                resource_mode: entry[:resource_mode],
                agents: persisted_resources(entry[:agents]),
                projects: persisted_resources(entry[:projects])
              }
            end
          }
        end
        FileStore.write_json(@snapshot_path, payload)
        persisted = Array(payload[:servers]).to_h { |entry| [entry[:key].to_s, entry] }
        @mutex.synchronize { @persisted_entries = persisted }
      end
    rescue StandardError => e
      @logger.warn("RemoteResources") do
        "Failed to persist resource snapshots: #{e.class} - #{e.message}"
      end
    end

    def persisted_resources(resources)
      Array(resources).map do |resource|
        resource.each_with_object({}) do |(key, value), result|
          name = key.to_s
          next if %w[server_key server_name server_local server_stale resource_kind].include?(name)

          result[name] = value
        end
      end
    end

    def resource_version(payload)
      build = value_for(payload, "build")
      version = build.is_a?(Hash) ? value_for(build, "version").to_s : ""
      version = value_for(payload, "version").to_s if version.empty?
      server = value_for(payload, "server")
      version = value_for(server, "version").to_s if version.empty? && server.is_a?(Hash)
      version.empty? ? nil : version
    end

    def config_for(key, registry:, server_url:)
      return LocalConfig.new(key: "local", name: "Local", url: server_url.to_s) if key == "local"

      Array(registry.remote_servers).find { |config| config.key == key }
    end

    def refresh_payload(key, accepted:)
      {
        accepted: accepted,
        server_key: key,
        revision: @mutex.synchronize { @revision },
        retry_after_ms: 0
      }
    end

    def retry_after_ms(entry)
      value = entry[:next_refresh_at].to_s
      return 0 if value.empty?

      [((Time.iso8601(value) - Time.now) * 1000).ceil, 0].max
    rescue ArgumentError
      0
    end

    def value_for(hash, key)
      return nil unless hash.is_a?(Hash)

      hash[key] || hash[key.to_sym]
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end
  end

  class RemoteClient
    DEFAULT_TIMEOUT = 5

    def initialize(config, timeout: DEFAULT_TIMEOUT, open_timeout: nil, read_timeout: nil, token_override: nil,
                   credential_resolver: nil)
      @config = config
      @base_uri = URI.parse(config.url)
      @open_timeout = open_timeout || timeout
      @read_timeout = read_timeout || timeout
      @token_override = token_override.to_s
      @credential_resolver = credential_resolver
      @credential = resolve_credential
    end

    def request(method, path, body: nil, query: nil)
      uri = target_uri(path, query)
      response = perform_request(method, uri, body)
      response_payload(response)
    rescue Net::OpenTimeout, Net::ReadTimeout
      {
        status: 504,
        body: { error: "Remote server #{@config.key} timed out" }
      }
    rescue SystemCallError, IOError, SocketError, OpenSSL::SSL::SSLError => e
      {
        status: 502,
        body: { error: "Remote server #{@config.key} is unreachable: #{e.message}" }
      }
    end

    private

    def target_uri(path, query)
      target_path = path.to_s
      target_path = "/#{target_path}" unless target_path.start_with?("/")
      base_path = @base_uri.path.to_s.sub(%r{/+\z}, "")
      uri = @base_uri.dup
      uri.path = "#{base_path}#{target_path}"
      uri.query = query.to_s.empty? ? nil : query.to_s
      uri
    end

    def perform_request(method, uri, body)
      request = request_for(method, uri)
      request["Accept"] = "application/json"
      token = @credential.token.to_s
      request["Authorization"] = "Bearer #{token}" unless token.to_s.empty?
      if request.request_body_permitted?
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body || {})
      end

      Net::HTTP.start(
        uri.hostname,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: @open_timeout,
        read_timeout: @read_timeout
      ) do |http|
        http.request(request)
      end
    end

    def request_for(method, uri)
      klass = {
        "GET" => Net::HTTP::Get,
        "POST" => Net::HTTP::Post,
        "PUT" => Net::HTTP::Put,
        "PATCH" => Net::HTTP::Patch,
        "DELETE" => Net::HTTP::Delete
      }.fetch(method.to_s.upcase) do
        raise RemoteServer::Error.new("Unsupported broker method: #{method}", status: 400)
      end
      klass.new(uri)
    end

    def response_payload(response)
      content_type = response["content-type"].to_s
      if [401, 403].include?(response.code.to_i)
        @credential_resolver&.rejected!(@credential, @config)
        return {
          status: 502,
          body: { error: "Remote server #{@config.key} rejected broker credentials" }
        }
      end

      if content_type.start_with?("application/json")
        parsed = JSON.parse(response.body.to_s)
        @credential_resolver&.verified!(@credential, @config) if response.code.to_i.between?(200, 299)
        parsed = redact_value(parsed) if response.code.to_i >= 400
        return {
          status: response.code.to_i,
          body: parsed.is_a?(Hash) ? parsed : { data: parsed },
          content_type: content_type.empty? ? "application/json" : content_type
        }
      end

      if response.code.to_i >= 400
        return {
          status: response.code.to_i,
          body: { error: redact_value(response.body.to_s.empty? ? response.message : response.body.to_s) }
        }
      end

      {
        status: response.code.to_i,
        body: response.body.to_s,
        content_type: content_type.empty? ? "application/octet-stream" : content_type,
        headers: proxy_response_headers(response)
      }
    rescue JSON::ParserError
      {
        status: response.code.to_i >= 400 ? response.code.to_i : 502,
        body: { error: "Remote server #{@config.key} returned invalid JSON" }
      }
    end

    def redact_value(value)
      token = @credential.token.to_s
      return value if token.empty?

      case value
      when Hash
        value.transform_values { |item| redact_value(item) }
      when Array
        value.map { |item| redact_value(item) }
      when String
        value.gsub(token, "[REDACTED]")
      else
        value
      end
    end

    def resolve_credential
      if !@token_override.empty? && @credential_resolver
        return @credential_resolver.transient(@config, @token_override)
      end
      return @credential_resolver.resolve(@config) if @credential_resolver

      RemoteCredentialResolver::Credential.new(
        server_key: @config.key,
        token: @token_override.empty? ? @config.resolved_token : @token_override,
        source: "legacy",
        state: "legacy"
      )
    rescue RemoteCredentialResolver::Error => e
      raise RemoteServer::Error.new(e.message, status: 502)
    end

    def proxy_response_headers(response)
      headers = {}
      %w[cache-control x-content-type-options content-disposition].each do |name|
        value = response[name]
        headers[name.split("-").map(&:capitalize).join("-")] = value if value
      end
      headers
    end
  end

  class RemoteBroker
    LOOPBACK_PEER_KEY = /\Aloopback-(\d{1,5})\z/
    RESOURCE_ROOTS = %w[activity agents projects attachments].freeze

    LocalServerConfig = Struct.new(:key, :name, :url, keyword_init: true) do
      def resolved_token
        ""
      end
    end

    def initialize(registry:, server_url: nil, timeout: RemoteClient::DEFAULT_TIMEOUT, logger: HQ.logger)
      @registry = registry
      @server_url = server_url.to_s
      @timeout = timeout
      @logger = logger
      @credential_resolver = RemoteCredentialResolver.new(store: RemoteCredentialStore.new(registry: registry))
    end

    def servers
      [server_payload(local_config, local: true)] +
        remote_configs.map { |config| server_payload(config, local: false) }
    end

    def proxy(key, method, path, body, request)
      config = find_config!(key)
      raise RemoteServer::Error.new("Cannot proxy to local server", status: 400) if local_key?(config.key)
      unless resource_path?(path)
        raise RemoteServer::Error.new("Peer access is limited to agents, projects, and attachments", status: 404)
      end

      response = RemoteClient.new(
        config,
        timeout: @timeout,
        token_override: remote_server_token(request),
        credential_resolver: @credential_resolver
      ).request(method, path, body:, query: request&.query)
      log_recoverable_activity_failure(config.key, method, path, response) if response[:status].to_i >= 500
      response
    end

    private

    def log_recoverable_activity_failure(peer_key, method, path, response)
      return unless path.to_s.split("/").reject(&:empty?).first == "activity"
      response_body = response[:body]
      error = if response_body.is_a?(Hash)
                response_body[:error] || response_body["error"]
              end
      return if error.to_s.include?("rejected broker credentials")

      @logger.warn("RemoteBroker") do
        "Peer activity fetch failed peer=#{peer_key.inspect} method=#{method.to_s.upcase} " \
          "path=#{path.to_s.inspect} status=#{response[:status].to_i}; treating as recoverable"
      end
    end

    def remote_configs
      Array(@registry.remote_servers)
    end

    def local_config
      LocalServerConfig.new(
        key: "local",
        name: "Local",
        url: @server_url.empty? ? nil : @server_url
      )
    end

    def find_config!(key)
      value = key.to_s
      return local_config if local_key?(value)

      configured = remote_configs.find { |config| config.key == value }
      return configured if configured
      return loopback_config(value) if loopback_key?(value)

      raise RemoteServer::Error.new("Unknown remote server: #{key}", status: 404)
    end

    def local_key?(key)
      key.to_s == "local"
    end

    def loopback_key?(key)
      match = key.to_s.match(LOOPBACK_PEER_KEY)
      return false unless match

      port = match[1].to_i
      port.positive? && port <= 65_535
    end

    def loopback_config(key)
      port = key.to_s.match(LOOPBACK_PEER_KEY)[1].to_i
      LocalServerConfig.new(
        key: key,
        name: "Loopback #{port}",
        url: "http://127.0.0.1:#{port}"
      )
    end

    def remote_server_token(request)
      value = request&.[]("X-Tycho-Remote-Server-Token").to_s
      value.empty? ? request&.[]("x-tycho-remote-server-token").to_s : value
    end

    def server_payload(config, local:)
      {
        key: config.key,
        name: config.name,
        icon: local ? "home" : (config.respond_to?(:icon) ? config.icon : "server"),
        url: config.url,
        local: local,
        auth_configured: local ? false : @credential_resolver.configured?(config),
        version: local ? HQ::VERSION : nil
      }
    end

    def resource_path?(path)
      root = path.to_s.split("/").reject(&:empty?).first
      RESOURCE_ROOTS.include?(root)
    end
  end

  class RemoteService
    ATTACHMENT_CONTENT_LIMIT = 512 * 1024
    ATTACHMENT_TEXT_SNIFF_LIMIT = 64 * 1024
    HTML_PREVIEW_ASSET_LIMIT = 2 * 1024 * 1024
    HTML_PREVIEW_ASSET_TYPES = {
      ".css" => "text/css",
      ".gif" => "image/gif",
      ".jpeg" => "image/jpeg",
      ".jpg" => "image/jpeg",
      ".js" => "application/javascript",
      ".mjs" => "application/javascript",
      ".png" => "image/png",
      ".svg" => "image/svg+xml",
      ".webp" => "image/webp",
      ".woff" => "font/woff",
      ".woff2" => "font/woff2"
    }.freeze
    MAX_PULL_REQUEST_INBOX_ITEMS = 100
    MAX_PROMPT_PULL_REQUEST_CONTEXTS = 5
    MAX_PROMPT_PULL_REQUEST_COMMENT_BYTES = 8 * 1024
    IMAGE_CONTENT_TYPES = {
      ".gif" => "image/gif",
      ".heic" => "image/heic",
      ".jpeg" => "image/jpeg",
      ".jpg" => "image/jpeg",
      ".png" => "image/png",
      ".svg" => "image/svg+xml; charset=utf-8",
      ".webp" => "image/webp"
    }.freeze

    Error = RemoteServer::Error
    attr_reader :registry, :server_url

    def initialize(registry: Registry.new, server_url: nil, public_url: nil, auth_required: false,
                   push_subscription_store: PushSubscriptionStore.new,
                   push_notification_store: PushNotificationStore.new,
                   web_push_notifier: nil,
                   schedule_daemon_supervisor: nil,
                   restartable: false,
                   tycho_updater: nil,
                   skill_installer: nil,
                   github_client: GitHubAPIClient.new,
                   pull_request_diff_store: PullRequestDiff::Store.new,
                   agent_activity_snapshot: AgentActivitySnapshot.new)
      @registry = registry
      @projects = registry.projects.map { |config| Project.new(config) }
      @agent_store = AgentStore.new(@projects)
      @personal_assistant = PersonalAssistantLifecycle.new(
        registry:, agent_store: @agent_store, state_path: File.join(HQ::PERSONAL_ASSISTANT_DIR, "state.json")
      )
      @personal_assistant_actions = PersonalAssistantActions.new(
        path: File.join(HQ::PERSONAL_ASSISTANT_DIR, "proposals.json"), executor: method(:execute_personal_assistant_action)
      )
      @agent_archive_store = AgentArchiveStore.new
      @push_subscription_store = push_subscription_store
      @push_notification_store = push_notification_store
      @web_push_notifier = web_push_notifier || WebPushNotifier.new(subscription_store: @push_subscription_store)
      @schedule_daemon_supervisor = schedule_daemon_supervisor
      @server_url = server_url.to_s
      @public_url = public_url.to_s
      @auth_required = auth_required ? true : false
      @restartable = restartable ? true : false
      @tycho_updater = tycho_updater || TychoUpdater.new
      skills_home = HQ.env_present("TYCHO_SKILLS_HOME", Dir.home)
      @skill_installer = skill_installer || SkillInstaller.new(home: skills_home)
      @github_client = github_client
      @pull_request_diff_store = pull_request_diff_store
      @agent_activity_snapshot = agent_activity_snapshot
      @pull_request_fetch_lock = Mutex.new
      @pull_request_fetches = {}
      @archived_query_lock = Mutex.new
      @archived_query_cache = {}
    end

    def add_remote_server(body)
      name = body["name"].to_s.strip
      url = body["url"].to_s.strip
      token = body["token"].to_s
      raise Error.new("Server name is required", status: 400) if name.empty?
      validate_ad_hoc_remote_url!(url)

      config = RemoteServerConfig.new(key: "candidate", name: name, url: url.sub(%r{/+\z}, ""), token:, token_env: "")
      response = RemoteClient.new(config).request("GET", "/agents")
      unless response[:status].to_i.between?(200, 299)
        detail = response.dig(:body, "error") || response.dig(:body, :error) || response[:status]
        raise Error.new("#{name} rejected the agent request: #{detail}", status: 502)
      end

      stored = @registry.add_remote_server!(name:, url:)
      broker = RemoteBroker.new(registry: @registry, server_url: @server_url)
      {
        server: broker.servers.find { |server| server[:key] == stored.key },
        servers: broker.servers
      }
    rescue ConfigError => e
      raise Error.new(e.message, status: 400)
    end

    def update_remote_server(key, body)
      updated = @registry.update_remote_server!(
        key,
        name: body["name"],
        icon: body["icon"]
      )
      broker = RemoteBroker.new(registry: @registry, server_url: @server_url)
      {
        server: broker.servers.find { |server| server[:key] == updated.key },
        servers: broker.servers
      }
    rescue ConfigError => e
      raise Error.new(e.message, status: e.message.start_with?("Unknown") ? 404 : 400)
    end

    def save_remote_server_credential(key, body)
      config = Array(@registry.remote_servers).find { |server| server.key == key.to_s }
      raise Error.new("Unknown remote server: #{key}", status: 404) unless config
      unless config.token_env.to_s.empty?
        raise Error.new(
          "Remote server #{key} uses external credential #{config.token_env}; update that source on this Tycho host",
          status: 409
        )
      end

      token = body["token"].to_s
      raise Error.new("Remote token is required", status: 400) if token.empty?

      store = RemoteCredentialStore.new(registry: @registry)
      resolver = RemoteCredentialResolver.new(store: store)
      response = RemoteClient.new(config, credential_resolver: resolver, token_override: token).request("GET", "/agents")
      unless response[:status].to_i.between?(200, 299)
        detail = response.dig(:body, "error") || response.dig(:body, :error) || response[:status]
        raise Error.new("Remote server #{key} rejected the credential: #{detail}", status: 502)
      end

      resolver.save(config, token: token, verified: true)
      {
        credential: remote_credential_metadata(config, resolver),
        servers: RemoteBroker.new(registry: @registry, server_url: @server_url).servers
      }
    end

    def remove_remote_server(key)
      removed = @registry.remove_remote_server!(key)
      RemoteCredentialStore.new(registry: @registry).remove_server(key)
      broker = RemoteBroker.new(registry: @registry, server_url: @server_url)
      {
        removed: removed,
        servers: broker.servers
      }
    rescue ConfigError => e
      raise Error.new(e.message, status: e.message.start_with?("Unknown") ? 404 : 400)
    end

    def remote_credential_metadata(config, resolver)
      credential = resolver.resolve(config)
      metadata = resolver.store.metadata(config.key).fetch(credential.source, {})
      {
        server_key: config.key,
        source: credential.source,
        state: credential.state,
        origin: metadata["origin"],
        verified_at: metadata["verified_at"],
        rejected_at: metadata["rejected_at"]
      }
    end

    def agents
      all_agents = load_all_agents
      context = delegation_reference_context(all_agents)
      relationships = delegation_relationship_context
      visible_agents(all_agents).map do |agent|
        agent_payload(agent, reference_context: context, relationship_context: relationships)
      end
    end

    def agent_activity
      @agent_activity_snapshot.snapshot
    end

    def archived_agents(params = {})
      page = positive_integer(params["page"], default: 1, name: "page")
      raise Error.new("page must be at most 1000000", status: 400) if page > 1_000_000
      per_page = positive_integer(params["per_page"], default: 50, name: "per_page")
      raise Error.new("per_page must be at most 100", status: 400) if per_page > 100

      project_key = params["project_key"].to_s.strip
      query = params["q"].to_s.strip.downcase
      archive_snapshot = @agent_archive_store.all
      active_keys = load_all_agents.map(&:key).sort
      projects_by_key = @projects.to_h { |project| [project.key, project] }
      project_search_revision = @projects.map do |project|
        [project.key, project.name, project.group, project.branch]
      end
      cache_key = [archive_snapshot.object_id, active_keys, project_search_revision, project_key, query]
      records = @archived_query_lock.synchronize do
        @archived_query_cache[cache_key] ||= begin
          active_index = active_keys.to_h { |key| [key, true] }
          matches = archive_snapshot.select do |record|
            !active_index[record.agent.key] && archived_agent_visible?(record.agent)
          end
          matches.select! { |record| record.agent.project_key == project_key } unless project_key.empty?
          unless query.empty?
            matches.select! do |record|
              agent = record.agent
              project = projects_by_key[agent.project_key]
              [
                agent.key,
                agent.display_name,
                agent.project_key,
                agent.status,
                agent.last_summary,
                project&.name,
                project&.group,
                project&.branch
              ]
                .compact.any? { |value| value.to_s.downcase.include?(query) }
            end
          end
          matches.sort_by { |record| record.agent.archived_at || Time.at(0) }.reverse.freeze
        end
        @archived_query_cache.shift while @archived_query_cache.length > 8
        @archived_query_cache.fetch(cache_key)
      end
      total = records.length
      page_records = if total.zero? || page > (total.to_f / per_page).ceil
                       []
                     else
                       records.slice((page - 1) * per_page, per_page) || []
                     end
      reference_context = delegation_reference_context
      relationship_context = delegation_relationship_context
      total_pages = (total.to_f / per_page).ceil
      {
        agents: page_records.map do |record|
          agent_list_payload(
            record.agent,
            reference_context: reference_context,
            relationship_context: relationship_context
          )
        end,
        pagination: {
          page: page,
          per_page: per_page,
          total: total,
          total_pages: total_pages,
          next_page: page < total_pages ? page + 1 : nil
        }
      }
    end

    def resource_snapshot
      all_agents = load_all_agents
      agents = visible_agents(all_agents)
      reference_context = delegation_reference_context(all_agents)
      relationship_context = delegation_relationship_context
      agents_by_project = agents.group_by(&:project_key)
      {
        schema_version: RemoteResourceCatalog::SCHEMA_VERSION,
        generated_at: Time.now.iso8601,
        build: {
          version: HQ::VERSION
        },
        agents: agents.map { |agent| agent_list_payload(agent, reference_context:, relationship_context:) },
        projects: visible_projects.map do |project|
          project_list_payload(project, agents: agents_by_project.fetch(project.key, []))
        end
      }
    end

    def personal_assistant
      status = @personal_assistant.status
      ingest_personal_assistant_actions!(status)
      status = @personal_assistant.reconcile
      agent = load_all_agents.find { |candidate| candidate.key == status[:active_key] && candidate.personal_assistant? }
      agent ? status.merge(agent: agent_payload(agent)) : status
    rescue ArgumentError => e
      raise Error.new(e.message, status: 409)
    end

    def setup_personal_assistant(attrs)
      @personal_assistant.setup!(attrs)
    rescue ArgumentError => e
      raise Error.new(e.message, status: 400)
    end

    def open_personal_assistant
      @personal_assistant.open!
    rescue ArgumentError => e
      raise Error.new(e.message, status: 409)
    end

    def reset_personal_assistant(attrs)
      raise Error.new("Reset FRED requires exact confirmation", status: 400) unless attrs["confirmed"] == true

      @personal_assistant_actions.reset! { @personal_assistant.reset! }
      @personal_assistant.status
    rescue ArgumentError => e
      raise Error.new(e.message, status: 409)
    end

    def submit_personal_assistant_prompt(attrs, actor: DelegationActor.user_actor)
      key = @personal_assistant.status[:active_key]
      raise Error.new("Open FRED before sending a message", status: 409) if key.to_s.empty?

      submit_prompt(key, attrs, actor:, personal_assistant_lifecycle: true)
    end

    def personal_assistant_actions
      status = @personal_assistant.status
      ingest_personal_assistant_actions!(status)
      status = @personal_assistant.reconcile
      @personal_assistant_actions.proposals.select { |proposal| proposal["active_key"] == status[:active_key] }
    end

    def confirm_personal_assistant_action(id, attrs)
      @personal_assistant_actions.execute!(id, confirmed: attrs["confirmed"] == true)
    rescue ArgumentError => e
      raise Error.new(e.message, status: 409)
    end

    def reject_personal_assistant_action(id)
      @personal_assistant_actions.reject!(id)
    rescue ArgumentError => e
      raise Error.new(e.message, status: 409)
    end

    def execute_personal_assistant_action(type, arguments)
      case type
      when "read_docs"
        path = arguments.fetch("path", "").to_s
        root = File.join(HQ::ROOT_DIR, "docs")
        expanded = File.realpath(File.expand_path(path, root)) rescue nil
        docs_root = File.realpath(root)
        raise ArgumentError, "Documentation path is outside Tycho docs" unless expanded && expanded.start_with?("#{docs_root}/") && File.file?(expanded)
        { "path" => path, "content" => File.read(expanded, 100_000) }
      when "search_docs"
        query = arguments.fetch("query", "").to_s.strip
        raise ArgumentError, "Documentation search query is required" if query.empty?
        root = File.realpath(File.join(HQ::ROOT_DIR, "docs"))
        results = Dir.glob(File.join(root, "**", "*.md")).filter_map do |path|
          path = File.realpath(path) rescue nil
          next unless path&.start_with?("#{root}/")

          text = File.read(path); next unless text.downcase.include?(query.downcase)
          { "path" => path.delete_prefix("#{HQ::ROOT_DIR}/"), "match" => text.lines.find { |line| line.downcase.include?(query.downcase) }.to_s.strip }
        end.first(20)
        { "results" => results }
      when "inspect_agents" then { "agents" => agents }
      when "inspect_projects" then { "projects" => projects }
      when "install_or_update_tycho_skill"
        change_skills(arguments.fetch("harness"), arguments.fetch("action"), "confirmed" => true)
      when "create_agent"
        create_agent(arguments.merge("start" => false), actor: DelegationActor.user_actor)
      when "message_agent"
        submit_prompt(arguments.fetch("agent_key"), "prompt" => arguments.fetch("prompt"), actor: DelegationActor.user_actor)
      when "start_agent" then start_agent(arguments.fetch("agent_key"), {}, actor: DelegationActor.user_actor)
      when "stop_agent" then stop_agent(arguments.fetch("agent_key"))
      else raise ArgumentError, "Unsupported assistant action"
      end
    end

    def ingest_personal_assistant_actions!(status)
      @personal_assistant.finalized_proposals.each do |snapshot|
        next if snapshot["run_id"].to_s == status[:summary_run_id].to_s && !status[:summary_run_id].to_s.empty?

        @personal_assistant_actions.register_finalized!(snapshot["proposals"], active_key: snapshot["active_key"], source_run_id: snapshot["run_id"])
        @personal_assistant.mark_finalized_proposals_registered!(snapshot["run_id"])
      end
    rescue ArgumentError => e
      HQ.logger.warn("PersonalAssistant") { "Rejected finalized action proposals: #{e.message}" }
    end

    def agent(key)
      agent_payload(find_agent_reference!(key))
    end

    # A compact, source-shaped feed for Second Brain reconciliation. The group
    # map is deliberately live configuration, while run provenance stays in
    # the persisted run record.
    def memory_handoffs
      projects = @projects.each_with_object({}) do |project, result|
        group = project.group.to_s
        result[project.key] = group if %w[Personal Cookpad].include?(group)
      end
      runs = load_all_agents.flat_map do |agent|
        next [] unless projects.key?(agent.project_key)

        agent.runs.filter_map do |run|
          handoff = MemoryHandoff.normalize(run.metadata.is_a?(Hash) ? run.metadata["memory_handoff"] : nil)
          next unless run.run_id.to_s.strip != "" && run.finished_at && run.status == "success" && handoff

          {
            run_id: run.run_id,
            finished_at: run.finished_at.iso8601,
            status: run.status,
            project: agent.project_key,
            metadata: { memory_handoff: handoff }
          }
        end
      end
      {
        server: ServerIdentity.load.fetch("id"),
        projects: projects,
        runs: runs.sort_by { |run| [run[:finished_at], run[:run_id]] }
      }
    end

    def agent_debug(key)
      agent = find_agent!(key)
      memory_events = AgentMemory.new(agent).events
      {
        agent: agent_payload(agent),
        run: agent_run_debug_payload(agent),
        files: agent_debug_files(agent),
        memory: {
          exists: File.exist?(agent.memory_path),
          event_count: memory_events.length,
          event_types: count_values(memory_events.map { |event| event["type"].to_s.empty? ? "unknown" : event["type"].to_s }),
          conversation_event_count: memory_events.count { |event| %w[system_prompt user_message assistant_message].include?(event["type"]) },
          assistant_message_count: memory_events.count { |event| event["type"] == "assistant_message" },
          run_summary_count: memory_events.count { |event| event["type"] == "run_summary" },
          last_event: memory_events.last
        },
        recent_app_log: filtered_log_tail(LOG_FILE, agent.key, 50)
      }
    end

    def agent_log(key, params)
      agent = find_agent!(key)
      type = params.fetch("type", "raw").to_s
      tail = bounded_tail(params["tail"], default: 200, max: 1_000)
      path = agent_log_path(agent, type)
      {
        agent_key: agent.key,
        type: type,
        path: path,
        exists: File.file?(path),
        tail: type == "app" ? filtered_log_tail(path, agent.key, tail) : file_tail(path, tail)
      }
    end

    def agent_memory_capture_dry_run(key)
      agent = find_agent!(key)
      lines = current_agent_run_lines(agent)
      conversation, system = Parser.parse_stream(lines, agent_type: agent.agent)
      assistant_messages = conversation.select { |entry| entry.role == "assistant" }
      tool_entries = system.reject { |entry| entry.type == :usage }
      usage_entries = system.select { |entry| entry.type == :usage }
      {
        agent_key: agent.key,
        raw_log_path: agent.raw_log_path,
        raw_log_exists: File.exist?(agent.raw_log_path),
        current_run_line_count: lines.length,
        conversation_entry_count: conversation.length,
        assistant_message_count: assistant_messages.length,
        system_entry_count: system.length,
        tool_entry_count: tool_entries.length,
        usage_entry_count: usage_entries.length,
        would_append_run_summary: !agent.last_summary.to_s.strip.empty?,
        summary: agent.last_summary,
        status: agent.effective_status
      }
    rescue StandardError => e
      {
        agent_key: key.to_s,
        error: e.message,
        error_class: e.class.name
      }
    end

    def rebuild_agent_memory(key)
      agent = reject_personal_assistant_control!(find_agent!(key))
      written = AgentChatLog.new(agent).rebuild_memory_from_raw_log!
      raise Error.new("Unable to rebuild memory from raw log", status: 422) unless written
      save_agent(agent)

      {
        agent_key: agent.key,
        memory_path: agent.memory_path,
        event_count: written
      }
    end

    def agent_pull_requests(key)
      ensure_github_enabled!
      agent = find_agent!(key)
      references = PullRequestDiff.references_for_agent(agent)
      snapshots = @pull_request_diff_store.all
      catalog = pull_request_catalog(agent).discover(references, metadata_by_id: snapshots)
      references.map do |reference|
        pull_request_reference_payload(reference, catalog[reference.id], snapshots[reference.id])
      end
    end

    def refresh_agent_pull_request_metadata(key)
      agent = reject_personal_assistant_control!(find_agent!(key))
      ensure_github_enabled!
      references = PullRequestDiff.references_for_agent(agent)
      catalog_store = pull_request_catalog(agent)
      catalog_store.discover(references)
      refreshed = []
      failed = []
      references.each do |reference|
        refreshed << [reference, github_provider.metadata(reference)]
      rescue PullRequestDiff::Error => e
        failed << {
          id: reference.id,
          repository: reference.repository,
          number: reference.number,
          error: e.message
        }
      end
      catalog = catalog_store.save_all_metadata(refreshed)
      snapshots = @pull_request_diff_store.all
      {
        pull_requests: references.map do |reference|
          pull_request_reference_payload(reference, catalog[reference.id], snapshots[reference.id])
        end,
        refreshed: refreshed.map { |reference, _metadata| reference.id },
        failed:
      }
    end

    def agent_pull_request_diff(key, id)
      ensure_github_enabled!
      agent = find_agent!(key)
      reference = pull_request_reference!(agent, id)
      snapshot = @pull_request_diff_store.fetch(reference.id)
      raise Error.new("Pull request diff has not been fetched yet", status: 404) unless snapshot
      return snapshot if PullRequestDiff.current_snapshot?(snapshot)

      refresh_pull_request_snapshot(reference)
    rescue PullRequestDiff::Error => e
      raise Error.new(e.message, status: e.status)
    end

    def refresh_agent_pull_request_diff(key, id)
      agent = reject_personal_assistant_control!(find_agent!(key))
      ensure_github_enabled!
      reference = pull_request_reference!(agent, id)
      refresh_pull_request_snapshot(reference)
    rescue PullRequestDiff::Error => e
      raise Error.new(e.message, status: e.status)
    end

    def refresh_agent_pull_requests(key)
      agent = reject_personal_assistant_control!(find_agent!(key))
      ensure_github_enabled!
      refreshed = []
      failed = []
      PullRequestDiff.references_for_agent(agent).each do |reference|
        refreshed << refresh_pull_request_snapshot(reference)
      rescue PullRequestDiff::Error => e
        failed << {
          id: reference.id,
          repository: reference.repository,
          number: reference.number,
          error: e.message
        }
      end
      { refreshed: refreshed, failed: failed }
    end

    def schedules
      scheduler.list
    rescue ScheduleRegistry::Error => e
      raise Error.new(e.message, status: 400)
    end

    def schedule_daemon
      scheduler.daemon_state.to_hash
    end

    def schedule(key)
      found = schedules.find { |item| item[:key] == key.to_s }
      raise Error.new("Unknown schedule: #{key}", status: 404) unless found

      found
    end

    def schedule_message_file(key, request: nil)
      schedule = find_schedule_definition!(key)
      raise Error.new("Schedule #{key.inspect} is not using file-based message mode") unless schedule.message_source == "file"

      requested_path = request&.query_params&.fetch("path", nil)
      message_file = requested_path.to_s.strip
      message_file = schedule.message_file.to_s if message_file.empty?
      raise Error.new("Schedule #{key.inspect} has no message file", status: 400) if message_file.empty?

      path = resolve_schedule_message_path!(key, message_file)
      {
        message_file: message_file,
        content: File.read(path)
      }
    rescue Errno::ENOENT => e
      raise Error.new(e.message, status: 404)
    end

    def update_schedule_message_file(key, attrs)
      schedule = find_schedule_definition!(key)
      raise Error.new("Schedule #{key.inspect} is not using file-based message mode") unless schedule.message_source == "file"

      message_file = required_text(attrs, "message_file", fallback: "message_file").to_s.strip
      path = resolve_schedule_message_path!(key, message_file)
      File.write(path, attrs["content"].to_s)
      { message_file: message_file, content: attrs["content"].to_s }
    end

    def create_schedule(attrs)
      created = schedule_registry.create(attrs)
      schedule(created.key)
    rescue ScheduleRegistry::Error => e
      raise Error.new(e.message, status: 400)
    end

    def create_agent_loop(key, attrs)
      now = Time.now
      agents = load_all_agents
      agent = agents.find { |candidate| candidate.key == key.to_s }
      raise Error.new("Unknown agent: #{key}", status: 404) unless agent
      reject_personal_assistant_control!(agent)

      interval = Integer(attrs["interval_minutes"].to_s, 10)
      ends_at = Time.iso8601(required_text(attrs, "ends_at", fallback: "ends_at"))
      schedule_key = required_text(attrs, "schedule_key", fallback: "schedule_key").strip
      name = attrs["name"].to_s.strip
      name = "Loop #{agent.name || agent.key}" if name.empty?
      message = required_text(attrs, "message", fallback: "message").strip
      result = scheduler.create_agent_loop!(
        agent:, agents: sort_agents(agents), schedule_key:, name:, interval_minutes: interval,
        ends_at:, message:, now:
      )

      {
        schedule: result.fetch(:schedule),
        agent: agent_payload(result.fetch(:agent)),
        daemon: ensure_loop_schedule_daemon
      }
    rescue ArgumentError, TypeError
      raise Error.new("Loop interval and end time must be valid", status: 400)
    rescue Scheduler::LoopStartError => e
      raise Error.new(e.message, status: 409)
    rescue ScheduleRegistry::Error => e
      raise Error.new(e.message, status: 400)
    end

    def update_schedule(key, attrs)
      schedule_registry.update(key, attrs)
      schedule(key)
    rescue ScheduleRegistry::Error => e
      raise Error.new(e.message, status: e.message.start_with?("Unknown schedule:") ? 404 : 400)
    end

    def delete_schedule(key)
      result = scheduler.remove(key)
      detached_agents = result.fetch(:agents)
      {
        deleted: true,
        key: key.to_s,
        detached_agent_keys: detached_agents.map(&:key),
        agents: detached_agents.map { |agent| agent_payload(agent) },
        agent: detached_agents.one? ? agent_payload(detached_agents.first) : nil
      }
    rescue ScheduleRegistry::Error => e
      raise Error.new(e.message, status: 404)
    end

    def schedule_message(key)
      schedule_message_payload(schedule_definition!(key))
    rescue ScheduleRegistry::Error => e
      raise Error.new(e.message, status: 404)
    end

    def update_schedule_message(key, attrs)
      schedule = schedule_definition!(key)
      raise ScheduleRegistry::Error, "Schedule #{key.inspect} does not use a message_file" unless schedule.message_source == "file"

      File.write(schedule.message_path, attrs["content"].to_s)
      schedule_message_payload(schedule)
    rescue ScheduleRegistry::Error => e
      raise Error.new(e.message, status: 404)
    end

    def run_schedule(key)
      schedule_result(scheduler.run_now(key))
    rescue ScheduleRegistry::Error => e
      raise Error.new(e.message, status: 404)
    end

    def schedule_result(result)
      if result.fetch(:status) == :failed
        raise Error.new(result.fetch(:error), status: 409)
      end
      unless result.fetch(:status) == :started
        raise Error.new("Schedule did not start: #{result.fetch(:status)}", status: 409)
      end

      {
        schedule: result.fetch(:schedule),
        agent: result[:agent] ? agent_payload(result[:agent]) : nil
      }.compact
    end

    def refresh_schedule_session(key)
      schedule_result(scheduler.refresh_session(key))
    rescue Scheduler::RefreshError => e
      raise Error.new(e.message, status: 409)
    rescue ScheduleRegistry::Error => e
      raise Error.new(e.message, status: 404)
    end

    def pause_schedule(key)
      scheduler.pause(key)
    rescue ScheduleRegistry::Error => e
      raise Error.new(e.message, status: 404)
    end

    def resume_schedule(key)
      result = scheduler.resume(key)
      if result.fetch(:status) == :failed
        raise Error.new(result.fetch(:error), status: 409)
      end

      {
        schedule: result.fetch(:schedule),
        agent: result[:agent] ? agent_payload(result[:agent]) : nil
      }.compact
    rescue ScheduleRegistry::Error => e
      raise Error.new(e.message, status: 404)
    end

    def resume_and_run_schedule(key)
      schedule_result(scheduler.resume_and_run_now(key))
    rescue ScheduleRegistry::Error => e
      raise Error.new(e.message, status: 404)
    end

    def reload_schedules
      scheduler.validate!
      { ok: true }
    rescue ScheduleRegistry::Error => e
      raise Error.new(e.message, status: 400)
    end

    def start_schedule_daemon(attrs = {})
      scheduler.validate!
      schedule_daemon_supervisor.start!(
        interval: attrs["interval"],
        dry_run: truthy?(attrs["dry_run"])
      )
    rescue ScheduleRegistry::Error => e
      raise Error.new(e.message, status: 400)
    rescue ScheduleDaemonSupervisor::Error => e
      raise Error.new(e.message, status: 409)
    end

    def stop_schedule_daemon
      schedule_daemon_supervisor.stop!
    rescue ScheduleDaemonSupervisor::Error => e
      raise Error.new(e.message, status: 409)
    end

    def restart_schedule_daemon(attrs = {}, command: nil)
      scheduler.validate!
      schedule_daemon_supervisor.restart!(
        interval: attrs["interval"],
        dry_run: truthy?(attrs["dry_run"]),
        command: command
      )
    rescue ScheduleRegistry::Error => e
      raise Error.new(e.message, status: 400)
    rescue ScheduleDaemonSupervisor::Error => e
      raise Error.new(e.message, status: 409)
    end

    def restart_running_schedule_daemon(command:)
      scheduler.validate!
      schedule_daemon_supervisor.restart_if_running!(command: command)
    rescue ScheduleRegistry::Error => e
      raise Error.new(e.message, status: 400)
    rescue ScheduleDaemonSupervisor::Error => e
      raise Error.new(e.message, status: 409)
    end

    def attachment(id)
      agent, attachment = find_attachment!(id)
      payload = attachment_payload(agent, attachment)
      return payload unless payload["type"].to_s == "file"
      return payload unless %w[html markdown text].include?(payload["format"].to_s)

      path = attachment_file_path(attachment, agent.workspace)
      unless path && File.file?(path)
        payload["content_error"] = "Attachment file is not readable."
        return payload
      end

      size = File.size(path)
      payload["content"] = File.open(path, "rb") { |file| file.read(ATTACHMENT_CONTENT_LIMIT) }.to_s.scrub
      payload["content_truncated"] = size > ATTACHMENT_CONTENT_LIMIT
      if payload["format"].to_s == "html" && !payload["content_truncated"]
        payload["preview_assets"] = html_preview_assets(payload["content"], path, agent.workspace)
      end
      payload
    rescue SystemCallError => e
      payload["content_error"] = e.message
      payload
    end

    def attachment_blob(id)
      agent, attachment = find_attachment!(id)
      raise Error.new("Attachment file not found", status: 404) unless attachment["type"].to_s == "file"

      path = attachment_file_path(attachment, agent.workspace)
      raise Error.new("Attachment file is not readable", status: 404) unless path && File.file?(path)

      {
        status: 200,
        content_type: attachment_content_type(attachment, path),
        headers: {
          "Cache-Control" => "private, max-age=60",
          "Content-Disposition" => "attachment; filename=\"#{http_quoted_filename(File.basename(path))}\"",
          "X-Content-Type-Options" => "nosniff"
        },
        body: File.binread(path)
      }
    rescue SystemCallError => e
      raise Error.new(e.message, status: 404)
    end

    def delete_attachment(id)
      agents = load_all_agents
      target_agent = nil
      target_attachment = nil

      agents.each do |agent|
        attachment = agent.attachments.find { |item| attachment_id(agent, item) == id.to_s }
        next unless attachment

        target_agent = agent
        target_attachment = attachment
        break
      end
      raise Error.new("Attachment not found", status: 404) unless target_agent && target_attachment
      reject_personal_assistant_control!(target_agent)

      deleted = target_agent.delete_attachment!(target_attachment)
      cleanup_uploaded_attachment_file(target_agent, target_attachment) if deleted
      save_agents(sort_agents(agents))
      {
        deleted: deleted,
        attachment_id: id.to_s,
        agent: agent_payload(target_agent)
      }
    end

    def projects
      refresh_projects!(visible_projects)
      agents_by_project = load_agents.group_by(&:project_key)
      visible_projects.map do |project|
        project_list_payload(project, agents: agents_by_project.fetch(project.key, []))
      end
    end

    def project(key)
      target = find_project!(key)
      refresh_project!(target)
      agents = load_agents.select { |agent| agent.project_key == target.key }
      project_detail_payload(target, agents:)
    end

    def project_git_status(key)
      project = find_project!(key)
      GitDiff.new(project.path).status_payload(project_key: project.key)
    rescue GitDiff::Error => e
      raise Error.new(e.message, status: e.status)
    end

    def project_git_diff(key, scope: nil)
      project = find_project!(key)
      GitDiff.new(project.path).diff_payload(scope:, project_key: project.key)
    rescue GitDiff::Error => e
      raise Error.new(e.message, status: e.status)
    end

    def project_workspace(key, params = {})
      project = find_project!(key)
      ProjectWorkspace.new(project.path).list(
        path: params["path"].to_s,
        offset: params["offset"],
        limit: params["limit"]
      )
    rescue ProjectWorkspace::Error => e
      raise Error.new(e.message, status: e.status, details: { code: e.code })
    end

    def project_workspace_preview(key, params = {})
      project = find_project!(key)
      ProjectWorkspace.new(project.path).preview(path: params["path"].to_s)
    rescue ProjectWorkspace::Error => e
      raise Error.new(e.message, status: e.status, details: { code: e.code })
    end

    def project_workspace_image(key, params = {})
      project = find_project!(key)
      image = ProjectWorkspace.new(project.path).image(path: params["path"].to_s)
      {
        status: 200,
        content_type: image.fetch(:mime_type),
        headers: {
          "Cache-Control" => "private, max-age=60",
          "Content-Disposition" => "inline; filename=\"#{http_quoted_filename(image.fetch(:name))}\"",
          "X-Content-Type-Options" => "nosniff"
        },
        body: image.fetch(:body)
      }
    rescue ProjectWorkspace::Error => e
      raise Error.new(e.message, status: e.status, details: { code: e.code })
    end

    def update_project_workspace_file(key, attrs)
      project = find_project!(key)
      ProjectWorkspace.new(project.path).write(
        path: attrs["path"].to_s,
        content: attrs["content"],
        expected_version: attrs["version"].to_s
      )
    rescue ProjectWorkspace::Error => e
      raise Error.new(e.message, status: e.status, details: { code: e.code })
    end

    def update_project(key, attrs)
      current = find_project!(key)
      updated = @registry.update_project!(current.key, project_attrs(current, attrs))
      raise Error.new("Unknown project: #{key}", status: 404) unless updated

      reload_projects_from_registry!
      project(current.key)
    rescue ConfigError => e
      raise Error.new(e.message)
    end

    def search_index
      {
        agents: agents,
        projects: projects
      }
    end

    def setup
      all_agents = load_all_agents
      agents = visible_agents(all_agents)
      hidden_projects = HQ::Visibility.hidden_projects(@projects)
      hidden_agent_count = HQ::Visibility.hidden_agents(all_agents, @projects).length
      {
        server_url: empty_to_nil(@server_url),
        ui_url: empty_to_nil(ui_url(@server_url)),
        public_ui_url: empty_to_nil(@public_url),
        tailscale: tailscale_payload,
        auth: {
          required: @auth_required,
          status: auth_status,
          warning: auth_warning
        },
        server: {
          restartable: @restartable,
          update: @tycho_updater.status
        },
        github: @github_client.capability,
        build: {
          version: HQ::VERSION,
          asset_version: HQ::RemoteUI.asset_version
        },
        counts: {
          projects: visible_projects.length,
          hidden_projects: hidden_projects.length,
          archived_projects: archived_project_count,
          agents: agents.length,
          hidden_agents: hidden_agent_count,
          running_agents: agents.count(&:running?),
          unread_agents: agents.count(&:unread?)
        },
        harnesses: harness_readiness,
        skill_installation: skill_installation,
        tools: tool_readiness,
        schema: schema_readiness,
        config: config_readiness,
        onboarding: onboarding_payload,
        logs: log_summary(agents),
        push: push_config,
        refresh_intervals: {
          active_ms: 5_000,
          idle_ms: 10_000,
          hidden_ms: 30_000
        },
        safety: safety_guidance
      }
    end

    def update_tycho
      @tycho_updater.update!
    rescue TychoUpdater::Error => e
      raise Error.new(e.message, status: 409)
    end

    def skill_installation
      {
        harnesses: @skill_installer.statuses
      }
    end

    def change_skills(harness, action, body)
      unless body["confirmed"] == true
        raise Error.new("Confirm this #{action} action before changing agent skills", status: 400)
      end

      result = @skill_installer.apply(harness: harness, action: action)
      {
        skill_installation: skill_installation,
        result: result
      }
    rescue SkillInstaller::InstallError => e
      status = { "permission" => 403, "network" => 502 }.fetch(e.category, 409)
      raise Error.new(e.message, status: status, details: e.to_h)
    end

    def refresh_harnesses
      HarnessCatalog.clear_cache!
      @registry.load!
      @projects = @registry.projects
      setup
    end

    def update_harness_catalog(harness_key, attrs)
      @registry.update_harness_catalog!(harness_key, attrs)
      HarnessCatalog.clear_cache!
      @projects = @registry.projects
      setup
    rescue ConfigError => e
      raise Error.new(e.message)
    end

    def create_welcome_project
      existing = @projects.find { |project| project.key == Onboarding::WELCOME_PROJECT_KEY }
      if existing
        refresh_project!(existing)
        return project_detail_payload(existing,
                                      agents: load_agents.select { |agent| agent.project_key == existing.key })
      end

      unless @projects.empty?
        raise Error.new("Welcome sandbox can only be created before projects are configured")
      end

      @registry.add_project!(Onboarding.welcome_project_attrs(agent: HQ.harness_keys.first))
      reload_projects_from_registry!
      project(Onboarding::WELCOME_PROJECT_KEY)
    rescue ConfigError => e
      raise Error.new(e.message)
    end

    def hidden_settings
      agents = load_all_agents
      agents_by_project = agents.group_by(&:project_key)
      group_names = (@registry.groups.keys + @projects.map(&:group)).map(&:to_s).reject(&:empty?).uniq.sort
      project_payloads = @projects.sort_by { |project| [project.group.to_s.downcase, project.name.to_s.downcase, project.key] }.map do |project|
        project_visibility_payload(project, agents_by_project.fetch(project.key, []))
      end
      group_payloads = group_names.map { |group_name| group_visibility_payload(group_name, project_payloads) }

      {
        groups: group_payloads,
        projects: project_payloads,
        counts: {
          groups: group_payloads.length,
          hidden_groups: group_payloads.count { |group| group[:hidden] },
          projects: project_payloads.length,
          hidden_projects: project_payloads.count { |project| project[:hidden] },
          agents: agents.length,
          hidden_agents: HQ::Visibility.hidden_agents(agents, @projects).length
        }
      }
    end

    def update_hidden_setting(attrs)
      scope = attrs["scope"].to_s
      key = attrs["key"].to_s
      hidden = hidden_setting_value(attrs)

      case scope
      when "group"
        @registry.update_group_hidden!(key, hidden)
      when "project"
        updated = @registry.update_project_hidden!(key, hidden)
        raise Error.new("Unknown project: #{key}", status: 404) unless updated
      else
        raise Error.new("Unsupported hidden setting scope: #{scope.inspect}")
      end

      reload_projects_from_registry!
      hidden_settings
    end

    def session_loop_settings
      @registry.session_loop_settings
    end

    def update_session_loop_settings(attrs)
      @registry.update_session_loop_settings!(attrs)
    rescue ConfigError => e
      raise Error.new(e.message, status: 400)
    end

    def update_session_loop_defaults(attrs)
      @registry.update_session_loop_defaults!(attrs)
    rescue ConfigError => e
      raise Error.new(e.message, status: 400)
    end

    def update_session_loop_prompt_templates(attrs)
      @registry.update_session_loop_prompt_templates!(attrs)
    rescue ConfigError => e
      raise Error.new(e.message, status: 400)
    end

    def response_style
      path = ResponseStylePolicy.path
      return { path: path, content: "", bytes: 0, exists: false } unless File.exist?(path)

      content = FileStore.read_text(path)
      {
        path: path,
        content: content,
        bytes: content.bytesize,
        exists: true
      }
    rescue StandardError => e
      raise Error.new("Unable to read response style: #{e.message}", status: 500)
    end

    def update_response_style(attrs)
      content = attrs["content"]
      raise Error.new("Response style content must be a string") unless content.is_a?(String)
      if content.bytesize > 65_536
        raise Error.new("Response style must be 64 KB or smaller")
      end

      FileStore.atomic_write(ResponseStylePolicy.path, content)
      response_style
    rescue Error
      raise
    rescue StandardError => e
      raise Error.new("Unable to save response style: #{e.message}", status: 500)
    end

    def delete_response_style
      FileUtils.rm_f(ResponseStylePolicy.path)
      response_style
    rescue StandardError => e
      raise Error.new("Unable to remove response style: #{e.message}", status: 500)
    end

    def push_config
      @web_push_notifier.config.merge(
        secure_context_required: true,
        localhost_allowed: true,
        magic_dns_https_required: true
      )
    end

    def push_status(attrs)
      @push_subscription_store.status(attrs["endpoint"]).merge(
        subscription_count: @push_subscription_store.count
      )
    end

    def save_push_subscription(attrs, user_agent: nil)
      subscription = @push_subscription_store.save_subscription(attrs, user_agent: user_agent)
      {
        subscribed: true,
        subscription_id: subscription["id"],
        subscription_count: @push_subscription_store.count
      }
    rescue ArgumentError => e
      raise Error.new(e.message)
    end

    def disable_push_subscription(attrs)
      endpoint = attrs["endpoint"].to_s
      disabled = @push_subscription_store.disable(endpoint)
      {
        subscribed: false,
        subscription_id: disabled&.fetch("id", nil),
        subscription_count: @push_subscription_store.count
      }
    end

    def send_test_push(attrs)
      result = @web_push_notifier.send_test!(endpoint: attrs["endpoint"])
      raise Error.new("No matching push subscription", status: 404) if result.fetch(:attempted).zero?

      result
    end

    def dispatch_agent_push_notifications!
      agents, events = load_agents_with_events
      visible = visible_agents(agents)
      @agent_activity_snapshot.replace!(visible)
      visible_keys = visible.map(&:key)
      dispatch_agent_push_events(events.select { |event| visible_keys.include?(event.agent_key) }, agents: visible)
    end

    def metrics_query(filters = {})
      UsageMetrics.query(filters)
    rescue ArgumentError => e
      raise Error.new(e.message, status: 400)
    end

    def metrics_backfill(attrs = {})
      UsageMetrics.backfill({
        "timezone" => attrs["timezone"],
        "include_raw" => attrs["durable_only"] != true
      })
    rescue ArgumentError, ConfigError => e
      raise Error.new(e.message, status: 400)
    end

    def skills(project_key, agent_kind)
      project = find_project!(project_key)
      agent = agent_kind.to_s.empty? ? "codex" : agent_kind.to_s
      {
        project_key: project.key,
        agent: agent,
        trigger: SkillDiscovery.trigger_for(agent),
        skills: SkillDiscovery.discover(workspace: project.path, agent_kind: agent)
      }
    end

    def conversation(key)
      target = find_agent_reference!(key)
      blocks = AgentChatLog.new(target).chat_blocks
      return conversation_messages(target) if blocks.empty?

      reference_context = delegation_reference_context
      blocks.map do |block|
        content, metadata = sanitized_delegation_block(block.content.to_s, block.metadata, reference_context:)
        {
          kind: block.kind.to_s,
          role: block.role,
          content: content,
          tool_name: block.tool_name,
          metadata: metadata,
          created_at: block.created_at
        }.compact
      end
    end

    def conversation_messages(target)
      target.conversation_messages.map do |message|
        {
          kind: "message",
          role: message.role,
          content: message.content.to_s,
          created_at: message.created_at&.iso8601,
          metadata: message.metadata
        }.compact
      end
    end

    def mark_agent_read(key)
      target = reject_personal_assistant_control!(find_agent!(key))
      if target.unread?
        target.mark_read!
        save_agent(target)
      end
      agent_payload(target)
    end

    def submit_prompt(key, attrs = {}, actor: nil, personal_assistant_lifecycle: false, **attribute_keywords)
      attrs = attribute_keywords.transform_keys(&:to_s).merge(attrs)
      actor ||= delegation_actor_from_attrs(attrs)
      target = find_agent!(key)
      reject_personal_assistant_control!(target) if target.personal_assistant? && !personal_assistant_lifecycle
      if target.personal_assistant? && !@personal_assistant.accepting_prompts?(key)
        raise Error.new("Personal Assistant is closing for daily rollover and is not accepting new prompts", status: 409)
      end
      target = associate_delegation_from_attrs!(target, attrs, actor:)
      pull_request_context = render_prompt_pull_request_contexts(target, attrs)
      attachments = import_prompt_attachments(target, attrs)
      text = prompt_text(attrs, attachments:)
      text = [text, pull_request_context].reject(&:empty?).join("\n")
      if target.running?
        begin
          target, entry = @agent_store.enqueue_prompt!(
            target.key,
            prompt: text,
            attachments:,
            id: prompt_client_request_id(attrs)
          )
          @agent_activity_snapshot.upsert!(target)
          return {
            queued: true,
            queue_entry: prompt_queue_entry_payload(target, entry),
            agent: agent_payload(target),
            conversation: conversation(target.key)
          }
        rescue ArgumentError => e
          raise unless e.message == "Agent is no longer running"

          target = find_agent!(key)
        end
      end

      if actor.parent?
        @agent_store.accept_prompt_from!(target, actor:)
        target.cancel_pending_inquiry! if target.inquiry_blocking_prompt_queue?
        target.add_user_message!(text, attachments:, metadata: target.message_author_metadata(actor))
        save_agent(target)
      else
        target = @agent_store.accept_ordinary_prompt!(
          target.key,
          text:,
          attachments:,
          actor:,
          retire_inquiry_id: attrs["retire_inquiry_id"]
        )
      end
      target = @agent_store.start_agent!(target.key) if truthy?(attrs["start"]) && !target.running?
      @agent_activity_snapshot.upsert!(target)
      { agent: agent_payload(target), conversation: conversation(target.key) }
    rescue DelegationStore::Error => e
      raise Error.new(e.message, status: actor&.parent? ? 403 : 409)
    rescue ArgumentError => e
      raise Error.new(e.message, status: e.message.start_with?("Unknown agent") ? 404 : 409)
    end

    def edit_queued_prompt(key, entry_id, attrs)
      reject_personal_assistant_control!(find_agent!(key))
      prompt = required_text(attrs, "prompt", fallback: "content")
      target, entry = @agent_store.edit_queued_prompt!(key, entry_id, prompt:)
      @agent_activity_snapshot.upsert!(target)
      { queue_entry: prompt_queue_entry_payload(target, entry), agent: agent_payload(target) }
    rescue ArgumentError => e
      status = e.message.start_with?("Unknown queued prompt") ? 404 : 409
      raise Error.new(e.message, status:)
    end

    def delete_queued_prompt(key, entry_id)
      reject_personal_assistant_control!(find_agent!(key))
      target, entry = @agent_store.delete_queued_prompt!(key, entry_id)
      Array(entry["attachments"]).each { |attachment| cleanup_uploaded_attachment_file(target, attachment) }
      @agent_activity_snapshot.upsert!(target)
      { deleted: prompt_queue_entry_payload(target, entry), agent: agent_payload(target) }
    rescue ArgumentError => e
      status = e.message.start_with?("Unknown queued prompt") ? 404 : 409
      raise Error.new(e.message, status:)
    end

    def retry_prompt_queue(key)
      reject_personal_assistant_control!(find_agent!(key))
      target = @agent_store.retry_prompt_queue!(key)
      @agent_activity_snapshot.upsert!(target)
      { agent: agent_payload(target), conversation: conversation(target.key) }
    rescue ArgumentError => e
      raise Error.new(e.message, status: e.message.start_with?("Unknown agent") ? 404 : 409)
    end

    def answer_inquiry(key, inquiry_id, attrs = {}, actor: DelegationActor.user_actor, **attribute_keywords)
      attrs = attribute_keywords.transform_keys(&:to_s).merge(attrs)
      raise Error.new("Parent-declared requests cannot answer user inquiries", status: 403) if actor.parent?

      answer = required_text(attrs, "answer", fallback: "prompt")
      feedback = attrs["feedback"].to_s.strip
      answer, feedback_embedded = inquiry_answer_with_feedback(answer, feedback, supplied: attrs.key?("feedback"))
      target = reject_personal_assistant_control!(find_agent!(key))
      attachments = import_prompt_attachments(target, attrs)
      target = @agent_store.answer_inquiry!(
        key,
        inquiry_id:,
        answer:,
        attachments:,
        feedback:,
        feedback_embedded:
      )
      target = @agent_store.start_agent!(target.key) if truthy?(attrs["start"]) && !target.running?
      @agent_activity_snapshot.upsert!(target)
      { agent: agent_payload(target), conversation: conversation(target.key) }
    rescue ArgumentError => e
      raise Error.new(e.message, status: e.message.start_with?("Unknown agent") ? 404 : 409)
    end

    def dismiss_inquiry(key, inquiry_id, actor: DelegationActor.user_actor)
      raise Error.new("Parent-declared requests cannot dismiss user inquiries", status: 403) if actor.parent?
      reject_personal_assistant_control!(find_agent!(key))

      target = @agent_store.suspend_inquiry!(key, inquiry_id)
      @agent_activity_snapshot.upsert!(target)
      { agent: agent_payload(target), conversation: conversation(target.key) }
    rescue ArgumentError => e
      raise Error.new(e.message, status: e.message.start_with?("Unknown agent") ? 404 : 409)
    end

    def restore_inquiry(key, inquiry_id, actor: DelegationActor.user_actor)
      raise Error.new("Parent-declared requests cannot restore user inquiries", status: 403) if actor.parent?
      reject_personal_assistant_control!(find_agent!(key))

      target = @agent_store.restore_inquiry!(key, inquiry_id)
      @agent_activity_snapshot.upsert!(target)
      { agent: agent_payload(target), conversation: conversation(target.key) }
    rescue ArgumentError => e
      raise Error.new(e.message, status: e.message.start_with?("Unknown agent") ? 404 : 409)
    end

    def update_agent_delegation(key, attrs)
      reject_personal_assistant_control!(find_agent!(key))
      connected = attrs["connected"]
      unless [true, false].include?(connected)
        raise Error.new("connected must be true or false", status: 422)
      end

      child, relation, counts, changed = @agent_store.set_delegation_connected!(key, connected:) do |candidate|
        unless HQ::Visibility.agent_visible?(candidate, @projects)
          raise Error.new("Unknown agent: #{key}", status: 404)
        end
      end
      {
        agent: agent_payload(child),
        relationship: {
          id: relation.fetch("id"),
          connected: relation["connected"] != false,
          changed: changed
        },
        suppressed_reports: counts.fetch(:suppressed_reports),
        cancelled_resumes: counts.fetch(:cancelled_resumes)
      }
    rescue DelegationStore::Error => e
      raise Error.new(e.message, status: 409)
    rescue ArgumentError
      if visible_archived_agent(key)
        raise Error.new("Archived agent is read-only: #{key}", status: 409)
      end

      raise Error.new("Unknown agent: #{key}", status: 404)
    end

    def start_agent(key, attrs = {}, actor: nil, **attribute_keywords)
      attrs = attribute_keywords.transform_keys(&:to_s).merge(attrs)
      actor ||= delegation_actor_from_attrs(attrs)
      target = reject_personal_assistant_control!(find_agent!(key))
      target = associate_delegation_from_attrs!(target, attrs, actor:)
      @agent_store.accept_prompt_from!(target, actor:) if target.delegation_parent
      save_agent(target)
      target = @agent_store.start_agent!(target.key) unless target.running?
      @agent_activity_snapshot.upsert!(target)
      { agent: agent_payload(target) }
    end

    def stop_agent(key)
      target = reject_personal_assistant_control!(find_agent!(key))
      target = @agent_store.stop_agent!(target.key)
      @agent_activity_snapshot.upsert!(target)
      { agent: agent_payload(target) }
    end

    def create_agent(attrs = {}, actor: nil, **attribute_keywords)
      attrs = attribute_keywords.transform_keys(&:to_s).merge(attrs)
      actor ||= delegation_actor_from_attrs(attrs)
      project = find_project!(attrs["project_key"])
      template_key = attrs["template_key"].to_s
      template_key = project.agent_templates.first&.key.to_s if template_key.empty?
      target = @agent_store.create_from_template(project, template_key)
      target.update!(**agent_attrs(target, attrs, project: project, creating: true))
      @agent_store.ensure_project_context_prompt!(target, project)
      current = load_all_agents
      current.unshift(target)
      target = associate_delegation_from_attrs!(target, attrs, agents: current, creating: true, actor:)
      @agent_store.accept_prompt_from!(target, actor:, agents: current) if target.delegation_parent
      save_agents(sort_agents(current))
      target = @agent_store.start_agent!(target.key) if truthy?(attrs["start"])
      @agent_activity_snapshot.upsert!(target)
      agent_payload(target)
    rescue DelegationStore::Error => e
      raise Error.new(e.message, status: actor&.parent? ? 403 : 409)
    end

    def update_agent(key, attrs)
      target = reject_personal_assistant_control!(find_agent!(key))
      raise Error.new("Agent is running", status: 409) if target.running?

      project = find_project!(target.project_key)
      resolved = agent_attrs(target, attrs, project: project, creating: false)
      other_keys = %i[template_key workspace prompt sandbox_mode agent model reasoning_effort response_style]
      if other_keys.all? { |key_name| resolved[key_name] == target.public_send(key_name) }
        target.rename!(resolved[:name])
      else
        target.update!(**resolved)
        @agent_store.ensure_project_context_prompt!(target, project)
      end
      save_agent(target)
      agent_payload(target)
    end

    def clone_agent(key, attrs)
      source = reject_personal_assistant_control!(find_agent!(key))
      current = load_all_agents
      source = current.find { |agent| agent.key == key.to_s } || source
      archive_source = truthy?(attrs["archive_source"])
      raise Error.new("Agent is running", status: 409) if archive_source && source.running?

      project = find_project!(source.project_key)
      target = @agent_store.clone_agent(source, existing_agents: current)
      target.update!(**agent_attrs(target, attrs, project: project, creating: false))
      @agent_store.ensure_project_context_prompt!(target, project)

      archive_path = @agent_store.archive_agent!(source.key) if archive_source
      @agent_activity_snapshot.remove!(source.key) if archive_source
      schedule_reconciled = reconcile_archived_schedule_agent(source) if archive_source
      next_agents = current.reject { |agent| agent.key == target.key || (archive_source && agent.key == source.key) }
      next_agents.unshift(target)
      save_agents(sort_agents(next_agents))
      target = @agent_store.start_agent!(target.key) if truthy?(attrs["start"])
      @agent_activity_snapshot.upsert!(target)
      HQ.hooks.publish("agent.cloned",
                       agent_key: target.key,
                       source_agent_key: source.key,
                       project_key: target.project_key,
                       name: target.name,
                       agent: target.agent,
                       model: target.model,
                       reasoning_effort: target.reasoning_effort)

      {
        agent: agent_payload(target),
        source_agent_key: source.key,
        archived: archive_source,
        archive_path: archive_path,
        schedule_reconciled: schedule_reconciled
      }.compact
    end

    def archive_agent(key)
      target = find_agent!(key)
      reject_personal_assistant_control!(target)
      raise Error.new("Agent is running", status: 409) if target.running?

      archive_path = @agent_store.archive_agent!(target.key)
      @agent_activity_snapshot.remove!(target.key)
      schedule_reconciled = reconcile_archived_schedule_agent(target)
      {
        archived: true,
        agent_key: target.key,
        archive_path: archive_path,
        schedule_reconciled: schedule_reconciled
      }
    end

    def archive_agents(attrs)
      payload = attrs || {}
      keys = Array(payload["keys"]).map { |key| key.to_s.strip }.reject(&:empty?).uniq
      raise Error.new("Missing agent keys") if keys.empty?

      current = load_all_agents
      agents_by_key = current.to_h { |agent| [agent.key, agent] }
      personal_assistant = keys.map { |key| agents_by_key[key] }.compact.find(&:personal_assistant?)
      reject_personal_assistant_control!(personal_assistant) if personal_assistant
      archived = []
      skipped = []
      failed = []

      keys.each do |key|
        target = agents_by_key[key]
        unless target
          failed << { agent_key: key, error: "Agent not found" }
          next
        end

        if target.running?
          skipped << { agent_key: key, reason: "running" }
          next
        end

        if target.personal_assistant?
          skipped << { agent_key: key, reason: "personal_assistant" }
          next
        end

        archive_path = @agent_store.archive_agent!(target.key)
        @agent_activity_snapshot.remove!(target.key)
        archived << {
          agent_key: target.key,
          archive_path: archive_path,
          schedule_reconciled: reconcile_archived_schedule_agent(target)
        }
      rescue StandardError => e
        failed << { agent_key: key, error: e.message }
      end

      {
        archived: archived,
        skipped: skipped,
        failed: failed,
        archive_count: archived.length
      }
    end

    def reject_personal_assistant_control!(target)
      if target.personal_assistant?
        raise Error.new("Personal Assistant is managed by its dedicated lifecycle and cannot be controlled through agent endpoints", status: 409)
      end

      target
    end

    def reconcile_archived_schedule_agent(agent)
      scheduler.reconcile_archived_agent!(agent.key, archived_agent: agent)
    rescue StandardError
      false
    end

    private

    def validate_ad_hoc_remote_url!(value)
      uri = URI.parse(value.to_s.strip)
      unless %w[http https].include?(uri.scheme) && ad_hoc_remote_host?(uri.host) && uri.port.positive? && uri.port <= 65_535
        raise Error.new("Ad hoc servers must use a loopback or Tailscale MagicDNS http(s) URL", status: 400)
      end
      raise Error.new("Remote server url must not include credentials", status: 400) unless uri.userinfo.to_s.empty?
    rescue URI::InvalidURIError => e
      raise Error.new("Invalid remote server url: #{e.message}", status: 400)
    end

    def ad_hoc_remote_host?(host)
      normalized = host.to_s.downcase.delete_suffix(".")
      return true if %w[127.0.0.1 localhost ::1].include?(normalized)

      normalized.end_with?(".ts.net") || normalized.end_with?(".beta.tailscale.net")
    end

    def visible_projects
      HQ::Visibility.visible_projects(@projects)
    end

    def visible_agents(agents)
      HQ::Visibility.visible_agents(agents, @projects).reject(&:personal_assistant?)
    end

    def hidden_setting_value(attrs)
      raise Error.new("Missing hidden value") unless attrs.key?("hidden")

      value = attrs["hidden"]
      return nil if value.nil?
      return value if [true, false].include?(value)

      normalized = value.to_s.strip.downcase
      return true if %w[true yes on 1].include?(normalized)
      return false if %w[false no off 0].include?(normalized)
      return nil if %w[inherit default visible].include?(normalized)

      raise Error.new("Invalid hidden value: #{value.inspect}")
    end

    def group_visibility_payload(group_name, project_payloads)
      config = @registry.groups[group_name]
      projects = project_payloads.select { |project| project[:group].to_s == group_name.to_s }
      hidden_config = config&.hidden
      hidden = hidden_config == true
      {
        name: group_name,
        hidden: hidden,
        hidden_config: hidden_config,
        visibility_source: hidden_config.nil? ? "default" : "group",
        project_count: projects.length,
        hidden_project_count: projects.count { |project| project[:hidden] },
        visible_project_count: projects.count { |project| !project[:hidden] },
        agent_count: projects.sum { |project| project[:agent_count].to_i },
        hidden_agent_count: projects.select { |project| project[:hidden] }.sum { |project| project[:agent_count].to_i }
      }
    end

    def project_visibility_payload(project, agents)
      {
        key: project.key,
        name: project.name,
        group: empty_to_nil(project.group),
        path: project.path,
        hidden: project.hidden?,
        hidden_config: project.hidden_config,
        group_hidden: project.group_hidden,
        visibility_source: project.visibility_source,
        agent_count: agents.length,
        running_agent_count: agents.count(&:running?),
        unread_agent_count: agents.count(&:unread?)
      }
    end

    def scheduler
      Scheduler.new(
        registry: @registry,
        schedule_registry: schedule_registry,
        push_notification_store: @push_notification_store,
        web_push_notifier: @web_push_notifier
      )
    end

    def ensure_loop_schedule_daemon
      daemon = schedule_daemon
      return daemon if %w[running stale untracked].include?(daemon[:status].to_s)

      schedule_daemon_supervisor.start!(interval: nil, dry_run: false).fetch(:daemon)
    rescue ScheduleDaemonSupervisor::Error => e
      { status: "stopped", error: e.message }
    end

    def schedule_registry
      ScheduleRegistry.new(projects: @projects)
    end

    def schedule_definition!(key)
      schedule = schedule_registry.find(key)
      raise ScheduleRegistry::Error, "Unknown schedule: #{key}" unless schedule

      schedule
    end

    def schedule_message_payload(schedule)
      unless schedule.message_source == "file"
        raise ScheduleRegistry::Error, "Schedule #{schedule.key.inspect} does not use a message_file"
      end

      {
        key: schedule.key,
        message_file: schedule.message_file,
        path: schedule.message_path,
        content: File.read(schedule.message_path)
      }
    end

    def find_schedule_definition!(key)
      schedule_definition = schedule_registry.find(key)
      raise Error.new("Unknown schedule: #{key}", status: 404) unless schedule_definition

      schedule_definition
    end

    def resolve_schedule_message_path!(key, message_file)
      value = message_file.to_s
      if value.start_with?("/") || value.split("/").include?("..") || !value.start_with?("schedules/")
        raise Error.new("Schedule #{key.inspect} message_file must be a relative path under schedules/")
      end

      path = File.expand_path(value.delete_prefix("schedules/"), schedule_registry.schedules_root)
      root = File.join(schedule_registry.schedules_root, "")
      unless path.start_with?(root)
        raise Error.new("Schedule #{key.inspect} message_file must stay inside schedules/")
      end

      raise Error.new("Schedule #{key.inspect} message_file does not exist: #{message_file}") unless File.file?(path)
      path
    end

    def schedule_daemon_supervisor
      @schedule_daemon_supervisor ||= ScheduleDaemonSupervisor.new
    end

    def reload_projects_from_registry!
      @projects = @registry.projects.map { |config| Project.new(config) }
      @agent_store = AgentStore.new(@projects)
    end

    def refresh_projects!(projects = @projects)
      threads = projects.map do |project|
        Thread.new { refresh_project!(project) }
      end
      threads.each(&:join)
    end

    def refresh_project!(project)
      project.refresh_metadata!
      project
    rescue StandardError => e
      HQ.logger.warn("Remote") { "Project refresh failed for #{project.key}: #{e.class} - #{e.message}" }
      project
    end

    def load_agents
      visible_agents(load_all_agents)
    end

    def load_all_agents
      agents, events = load_agents_with_events
      visible = visible_agents(agents)
      @agent_activity_snapshot.replace!(visible)
      visible_keys = visible.map(&:key)
      dispatch_agent_push_events(events.select { |event| visible_keys.include?(event.agent_key) }, agents: visible)
      agents
    end

    def load_agents_with_events
      @agent_store.load_with_poll_events
    end

    def agent_run_debug_payload(agent)
      run = agent.last_run
      {
        count: agent.run_count,
        last: run ? run.to_hash : nil,
        pid: agent.pid,
        running: agent.running?,
        started_at: agent.started_at&.iso8601,
        finished_at: agent.finished_at&.iso8601,
        last_exit_code: agent.last_exit_code,
        effective_status: agent.effective_status,
        summary: agent.last_summary,
        session_id: agent.session_id.to_s.empty? ? nil : agent.session_id
      }
    end

    def agent_debug_files(agent)
      {
        raw: file_debug_payload(agent.raw_log_path),
        memory: file_debug_payload(agent.memory_path),
        conversation: file_debug_payload(agent.conversation_log_path),
        system: file_debug_payload(agent.system_log_path),
        status: file_debug_payload(agent_private_log_path(agent, :status_file_path)),
        last_message: file_debug_payload(agent_private_log_path(agent, :last_message_file_path)),
        invalid_structured_output: file_debug_payload(
          agent_private_log_path(agent, :invalid_structured_output_file_path)
        ),
        attachments: file_debug_payload(agent.attachments_path)
      }
    end

    def file_debug_payload(path)
      exists = File.exist?(path)
      payload = {
        path: path,
        exists: exists
      }
      return payload unless exists

      stat = File.stat(path)
      payload.merge(
        size_bytes: stat.size,
        mtime: stat.mtime.iso8601
      )
    rescue StandardError => e
      {
        path: path,
        exists: false,
        error: e.message
      }
    end

    def agent_log_path(agent, type)
      case type
      when "raw"
        agent.raw_log_path
      when "memory"
        agent.memory_path
      when "conversation"
        agent.conversation_log_path
      when "system"
        agent.system_log_path
      when "status"
        agent_private_log_path(agent, :status_file_path)
      when "last_message"
        agent_private_log_path(agent, :last_message_file_path)
      when "attachments"
        agent.attachments_path
      when "app"
        LOG_FILE
      else
        raise Error.new("Unknown agent log type: #{type}", status: 400)
      end
    end

    def agent_private_log_path(agent, method_name)
      agent.send(method_name)
    end

    def bounded_tail(value, default:, max:)
      count = value.to_i
      count = default unless count.positive?
      [count, max].min
    end

    def file_tail(path, count)
      return [] unless File.file?(path)

      LogFileReader.tail_lines(path, count, chomp: true).map { |line| redact_log_line(line) }
    rescue StandardError
      []
    end

    def filtered_log_tail(path, agent_key, count)
      key = agent_key.to_s
      file_tail(path, [count * 5, 1_000].min).select { |line| line.include?(key) }.last(count)
    end

    def redact_log_line(line)
      line.to_s
          .gsub(/(Authorization:\s*Bearer\s+)[^\s]+/i, "\\1[REDACTED]")
          .gsub(/(Bearer\s+)[A-Za-z0-9._~+\/=-]{12,}/, "\\1[REDACTED]")
          .gsub(/(token["'=:\s]+)[A-Za-z0-9._~+\/=-]{12,}/i, "\\1[REDACTED]")
    end

    def count_values(values)
      values.each_with_object(Hash.new(0)) { |value, result| result[value] += 1 }.sort.to_h
    end

    def current_agent_run_lines(agent)
      return [] unless File.exist?(agent.raw_log_path)

      lines = LogFileReader.read_lines(agent.raw_log_path, chomp: true)
      marker = agent.started_at ? "=== [#{agent.started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ===" : nil
      index = marker ? lines.rindex(marker) : nil
      index ||= lines.rindex { |line| line.start_with?("=== [") }
      return lines unless index

      lines[(index + 1)..] || []
    rescue StandardError
      []
    end

    def save_agent(target)
      agents = load_all_agents
      index = agents.index { |agent| agent.key == target.key }
      raise Error.new("Unknown agent: #{target.key}", status: 404) unless index

      agents[index] = target
      save_agents(sort_agents(agents))
    end

    def save_agents(agents)
      @agent_store.save(agents)
      @agent_activity_snapshot.replace!(visible_agents(agents))
    end

    def sort_agents(agents)
      agents.sort_by(&:last_activity_at).reverse
    end

    def find_agent!(key)
      active = load_all_agents.find { |agent| agent.key == key.to_s }
      return active if active

      if visible_archived_agent(key)
        raise Error.new("Archived agent is read-only: #{key}", status: 409)
      end

      raise Error.new("Unknown agent: #{key}", status: 404)
    end

    def find_agent_reference!(key)
      load_all_agents.find { |agent| agent.key == key.to_s } ||
        visible_archived_agent(key) ||
        raise(Error.new("Unknown agent: #{key}", status: 404))
    end

    def visible_archived_agent(key)
      agent = @agent_archive_store.find(key)&.agent
      return nil unless agent && archived_agent_visible?(agent)

      agent
    end

    def pull_request_reference!(agent, id)
      PullRequestDiff.references_for_agent(agent).find { |reference| reference.id == id.to_s } ||
        raise(Error.new("Pull request not found: #{id}", status: 404))
    end

    def github_provider
      PullRequestDiff::GitHubProvider.new(client: @github_client)
    end

    def pull_request_reference_payload(reference, entry, snapshot)
      entry ||= {}
      metadata = entry["metadata"]
      freshness_metadata = metadata if entry["metadata_source"] == "github"
      payload = PullRequestDiff.reference_payload(reference, snapshot:, metadata:, freshness_metadata:)
      if metadata.is_a?(Hash)
        payload["metadata_refreshed_at"] = entry["metadata_refreshed_at"]
      end
      payload
    end

    def pull_request_catalog(agent)
      PullRequestDiff::Catalog.new(path: agent.pull_request_catalog_path)
    end

    def persist_pull_request_metadata(reference, metadata)
      return if reference.agent_key.to_s.empty?

      agent = load_agents.find { |candidate| candidate.key == reference.agent_key }
      pull_request_catalog(agent).save_metadata(reference, metadata) if agent
    end

    def refresh_pull_request_snapshot(reference)
      refresh_pull_request_snapshot_fetch(reference).fetch(:snapshot)
    end

    def refresh_pull_request_snapshot_fetch(reference)
      refreshed = coalesce_pull_request_fetch(reference, "snapshot") do
        metadata, pull = github_provider.metadata_with_pull(reference)
        { snapshot: save_pull_request_snapshot(reference, metadata), pull:, metadata: }
      end
      persist_pull_request_metadata(reference, refreshed.fetch(:metadata))
      refreshed
    end

    def save_pull_request_snapshot(reference, metadata)
      snapshot = @pull_request_diff_store.save(
        PullRequestDiff.snapshot_for(reference, provider: github_provider, metadata:)
      )
      snapshot
    end

    def coalesce_pull_request_fetch(reference, operation)
      key = [github_cache_scope, reference.id, operation].join("\0")
      leader = false
      @pull_request_fetch_lock.synchronize do
        fetch = @pull_request_fetches[key]
        unless fetch
          fetch = { condition: ConditionVariable.new, complete: false }
          @pull_request_fetches[key] = fetch
          leader = true
        end
        unless leader
          fetch[:condition].wait(@pull_request_fetch_lock) until fetch[:complete]
          raise fetch[:error] if fetch[:error]

          return fetch[:value]
        end
      end

      value = yield
      complete_pull_request_fetch(key, value:)
      value
    rescue StandardError => e
      complete_pull_request_fetch(key, error: e) if leader
      raise
    end

    def complete_pull_request_fetch(key, value: nil, error: nil)
      @pull_request_fetch_lock.synchronize do
        fetch = @pull_request_fetches.delete(key)
        return unless fetch

        fetch[:value] = value
        fetch[:error] = error
        fetch[:complete] = true
        fetch[:condition].broadcast
      end
    end

    def github_cache_scope
      return @github_client.base_url.to_s if @github_client.respond_to?(:base_url)

      @github_client.object_id.to_s
    end

    def ensure_github_enabled!
      return if @github_client.enabled?

      raise Error.new("Pull request diffs require an authenticated `gh` CLI session.",
                      status: 424)
    end

    def find_project!(key)
      visible_projects.find { |project| project.key == key.to_s } ||
        raise(Error.new("Unknown project: #{key}", status: 404))
    end

    def dispatch_agent_push_events(events, agents:)
      totals = { events: 0, sent: 0, failed: 0, attempted: 0 }
      unread_count = agents.count(&:unread?)
      event_agent_keys = Array(events).map(&:agent_key)
      candidate_keys = (event_agent_keys + agents.select(&:unread?).map(&:key)).uniq
      candidate_keys.each do |agent_key|
        agent = agents.find { |candidate| candidate.key == agent_key }
        payload = agent && agent_push_payload(agent, unread_count: unread_count)
        next unless payload

        notification_id = agent_push_notification_id(agent, payload.fetch(:event))
        next if @push_notification_store.recorded?(notification_id)

        @push_notification_store.record!(
          notification_id,
          agent_key: agent.key,
          event: payload.fetch(:event),
          status: agent.status,
          run_count: agent.run_count
        )
        result = @web_push_notifier.send_payload!(
          payload.fetch(:payload),
          urgency: payload.fetch(:event) == "input_required" ? "high" : "normal",
          ttl: payload.fetch(:event) == "input_required" ? 3600 : 900
        )
        totals[:events] += 1
        totals[:sent] += result.fetch(:sent, 0)
        totals[:failed] += result.fetch(:failed, 0)
        totals[:attempted] += result.fetch(:attempted, 0)
      end
      totals
    end

    def agent_push_payload(agent, unread_count:)
      return nil if agent.respond_to?(:no_action_needed?) && agent.no_action_needed?
      return nil if agent.last_run_from_prompt_queue?

      status = agent.status
      if status == "awaiting-input"
        event = "input_required"
        title = "Agent requires response"
      elsif %w[succeeded failed stopped blocked].include?(status)
        event = "finished"
        title = status == "succeeded" ? "Agent finished" : "Agent finished: #{status}"
      else
        return nil
      end

      group_count = [unread_count.to_i, 1].max
      body = "#{agent.display_name}: #{truncate(agent.last_summary, 120)}"
      body = "#{body} (#{group_count} unread agents)" if group_count > 1

      {
        event: event,
        payload: {
          title: title,
          body: body,
          tag: "hq:agents",
          renotify: event == "input_required",
          silent: event != "input_required",
          badge_count: group_count,
          url: "/#agent/#{agent.key}"
        }
      }
    end

    def agent_push_notification_id(agent, event)
      run = agent.last_run
      [
        agent.key,
        event,
        agent.run_count,
        run&.started_at&.iso8601 || agent.started_at&.iso8601,
        run&.finished_at&.iso8601 || agent.finished_at&.iso8601,
        agent.status
      ].join(":")
    end

    def project_list_payload(project, agents:)
      {
        key: project.key,
        name: project.name,
        group: empty_to_nil(project.group),
        path: project.path,
        status: project.status,
        agent_count: agents.length,
        unread_agent_count: agents.count(&:unread?),
        running_agent_count: agents.count(&:running?)
      }
    end

    def project_detail_payload(project, agents:)
      recent_agent = agents.max_by(&:last_activity_at)
      project_list_payload(project, agents:).merge(
        pr_url: project.pr_url,
        pr_number: project.pr_number,
        branch: project.branch,
        branch_url: project.branch_url(project.branch),
        commit_hash: project.commit_hash,
        commit_url: project.commit_url(project.commit_hash),
        dirty: project.dirty_files.to_i.positive?,
        dirty_files: project.dirty_files.to_i,
        agent: project.config.agent,
        model: project.config.model,
        reasoning_effort: project.config.reasoning_effort,
        agent_template_summaries: agent_template_summaries(project),
        managed_agent_count: agents.length,
        recent_agent_summary: recent_agent ? recent_agent_payload(recent_agent) : nil
      )
    end

    def agent_template_summaries(project)
      project.agent_templates.map do |template|
        {
          key: template.key,
          name: template.name,
          agent: template.agent,
          model: template.model,
          reasoning_effort: template.reasoning_effort,
          response_style: template.response_style,
          sandbox_mode: template.sandbox_mode,
          skill_trigger: SkillDiscovery.trigger_for(template.agent),
          prompt: template.prompt,
          prompt_preview: truncate(template.prompt, 140)
        }
      end
    end

    def recent_agent_payload(agent)
      {
        key: agent.key,
        name: agent.display_name,
        status: agent.status,
        last_result: agent.last_result_label,
        summary: agent.last_summary,
        updated_at: agent.last_activity_at&.iso8601
      }
    end

    def archived_project_count
      path = File.join(File.dirname(@registry.path), Registry::DEFAULT_ARCHIVED_BASENAME)
      return 0 unless File.exist?(path)

      data = YAML.safe_load(File.read(path), permitted_classes: [Symbol], aliases: true) || {}
      Array(data["projects"]).length
    rescue StandardError
      0
    end

    def prompt_template_count
      return 0 unless File.exist?(@registry.system_prompts_path)

      data = YAML.safe_load(File.read(@registry.system_prompts_path), permitted_classes: [Symbol], aliases: true) || {}
      data.length
    rescue StandardError
      0
    end

    def harness_readiness
      builtins = [
        harness_resolver_payload("codex", ExecutableResolver.resolve_tool("codex")),
        harness_resolver_payload("claude", ExecutableResolver.resolve_tool("claude")),
        harness_resolver_payload("opencode", ExecutableResolver.resolve_tool("opencode")),
        harness_resolver_payload("pi", ExecutableResolver.resolve_tool("pi"))
      ]
      custom = HQ.custom_harnesses.values.sort_by(&:key).map { |config| custom_harness_payload(config) }
      builtins + custom
    end

    def tool_readiness
      [
        resolver_payload("tailscale", ExecutableResolver.resolve_tool("tailscale"))
      ]
    end

    def resolver_payload(name, resolution)
      {
        name: name,
        ready: resolution.available?,
        detail: resolution.available? ? executable_detail(resolution) : "missing #{resolution.command}",
        commands: [resolution.command],
        path: resolution.path,
        source: resolution.source
      }
    end

    def harness_resolver_payload(name, resolution)
      merge_harness_catalog_config(name, resolver_payload(name, resolution).merge(HarnessCatalog.for_builtin(name, resolution)))
    end

    def custom_harness_payload(config)
      command = readiness_command_for(config.command_parts)
      resolution = command ? ExecutableResolver.resolve(command) : nil
      available = resolution&.available?
      detail = if available
                 "adapter #{config.adapter}; #{command} #{executable_detail(resolution)}"
               else
                 "adapter #{config.adapter}; missing #{command || "execution command"}"
               end
      {
        name: config.key,
        ready: resolution&.available? ? true : false,
        detail: detail,
        commands: config.command_parts,
        adapter: config.adapter,
        path: resolution&.path,
        source: resolution&.source
      }.merge(merge_harness_catalog_config(config.key, HarnessCatalog.for_custom(config)))
    end

    def merge_harness_catalog_config(name, payload)
      config = @registry.harness_catalog(name)
      return payload unless config

      source = [payload[:catalog_source], "hq.yml custom catalog"].compact.reject(&:empty?).join(" + ")
      payload.merge(
        model_suggestions: merge_model_suggestions(payload[:model_suggestions], config.models),
        reasoning_effort_suggestions: merge_effort_suggestions(payload[:reasoning_effort_suggestions], config.reasoning_efforts),
        configured_model_suggestions: config.models,
        configured_reasoning_effort_suggestions: config.reasoning_efforts,
        catalog_source: source
      )
    end

    def merge_model_suggestions(existing, configured)
      suggestions = Array(existing).dup
      seen = suggestions.each_with_object({}) do |item, memo|
        value = item.is_a?(Hash) ? item[:value].to_s : item.to_s
        memo[value] = true
      end
      Array(configured).each do |model|
        value = model.to_s.strip
        next if value.empty? || seen[value]

        suggestions << { value: value, label: value }
        seen[value] = true
      end
      suggestions
    end

    def merge_effort_suggestions(existing, configured)
      (Array(existing) + Array(configured)).map { |value| value.to_s.strip.downcase }.reject(&:empty?).uniq
    end

    def executable_detail(resolution)
      case resolution.source
      when "path"
        "available on PATH: #{resolution.path}"
      else
        "available at #{resolution.path}"
      end
    end

    def readiness_command_for(parts)
      values = Array(parts).map(&:to_s).reject(&:empty?)
      return nil if values.empty?
      return values.first unless values.first == "env"

      values.drop(1).find { |value| !value.include?("=") }
    end

    def schema_readiness
      JSON.parse(File.read(AGENT_RESULT_SCHEMA))
      { valid: true, path: AGENT_RESULT_SCHEMA }
    rescue StandardError => e
      { valid: false, path: AGENT_RESULT_SCHEMA, error: e.message }
    end

    def config_readiness
      {
        loaded: true,
        path: @registry.path,
        system_prompts_path: @registry.system_prompts_path,
        prompt_template_count: prompt_template_count,
        schedule_system_message_template: AgentStore.scheduled_system_prompt_template,
        session_loop_settings: @registry.session_loop_settings,
        active_projects: @projects.length,
        archived_projects: archived_project_count
      }
    end

    def onboarding_payload
      {
        active: @projects.empty?,
        welcome_project_key: Onboarding::WELCOME_PROJECT_KEY,
        welcome_workspace_path: Onboarding.welcome_workspace_path,
        agent_cli_guides: Onboarding.agent_cli_guides
      }
    end

    def log_summary(agents)
      {
        root: LOGS_DIR,
        agent_runs: agents.sum(&:run_count),
        agent_log_files: Dir.glob(File.join(AGENT_LOGS_DIR, "*")).count { |path| File.file?(path) },
        project_archive_dir: PROJECT_ARCHIVE_DIR
      }
    rescue StandardError
      {
        root: LOGS_DIR,
        agent_runs: agents.sum(&:run_count),
        agent_log_files: 0,
        project_archive_dir: PROJECT_ARCHIVE_DIR
      }
    end

    def tailscale_payload
      {
        available: !@public_url.empty?,
        https: @public_url.start_with?("https://"),
        magic_dns: @public_url.include?(".ts.net"),
        url: empty_to_nil(@public_url)
      }
    end

    def ui_url(base)
      value = base.to_s
      return "" if value.empty?

      "#{value.sub(%r{/+\z}, "")}/"
    end

    def agent_attrs(target, attrs, project:, creating:)
      template_key = attrs["template_key"].to_s
      template_key = target.template_key if template_key.empty?
      template = project.agent_templates.find { |candidate| candidate.key == template_key } ||
                 project.agent_templates.first
      prompt = attrs.key?("prompt") ? attrs["prompt"].to_s : target.prompt.to_s
      name = attrs.key?("name") ? attrs["name"].to_s : target.name.to_s
      workspace = attrs.key?("workspace") ? attrs["workspace"].to_s : target.workspace.to_s
      sandbox_mode = attrs.key?("sandbox_mode") ? attrs["sandbox_mode"].to_s : target.sandbox_mode.to_s
      sandbox_mode = template.sandbox_mode.to_s if sandbox_mode.empty?
      agent = (attrs.key?("agent") ? attrs["agent"].to_s : target.agent.to_s).strip.downcase
      model = attrs.key?("model") ? attrs["model"].to_s.strip : target.model.to_s
      reasoning_effort = attrs.key?("reasoning_effort") ? attrs["reasoning_effort"].to_s.strip.downcase : target.reasoning_effort.to_s
      response_style = agent_response_style_for(target, attrs, template:, creating:)
      workspace = project.path if workspace.empty? && creating

      raise Error.new("Name is required") if name.strip.empty?
      raise Error.new("Prompt is required") if prompt.strip.empty?
      raise Error.new("Workspace is required") if workspace.strip.empty?
      unless HQ.supported_harness?(agent)
        raise Error.new("Unsupported agent #{agent.inspect}. Supported agents: #{HQ.harness_keys.join(", ")}")
      end

      {
        name: name.strip,
        template_key: template.key,
        workspace: workspace.strip,
        prompt: prompt.strip,
        sandbox_mode: sandbox_mode,
        agent: agent,
        model: model.empty? ? nil : model,
        reasoning_effort: reasoning_effort.empty? ? nil : reasoning_effort,
        response_style: response_style
      }
    end

    def agent_response_style_for(target, attrs, template:, creating:)
      mode = attrs["response_style_mode"].to_s.strip.downcase
      return template.response_style if mode.empty?

      case mode
      when "global"
        nil
      when "template"
        template.response_style
      when "disabled"
        false
      when "current"
        raise Error.new("Current response style is unavailable for a new agent") if creating

        target.response_style
      else
        raise Error.new("Unsupported response style mode: #{mode.inspect}")
      end
    end

    def project_attrs(target, attrs)
      immutable_project_field!(attrs, "key", target.key)
      immutable_project_field!(attrs, "path", target.path)
      immutable_project_field!(attrs, "pr_url", target.pr_url.to_s)

      name = attrs.key?("name") ? attrs["name"].to_s.strip : target.name.to_s
      raise Error.new("Name is required") if name.empty?

      agent = attrs.key?("agent") ? attrs["agent"].to_s.strip.downcase : target.config.agent.to_s
      unless HQ.supported_harness?(agent)
        raise Error.new("Unsupported agent #{agent.inspect}. Supported agents: #{HQ.harness_keys.join(", ")}")
      end

      result = {
        "name" => name,
        "group" => attrs.key?("group") ? attrs["group"].to_s.strip : target.group.to_s,
        "agent" => agent,
        "model" => attrs.key?("model") ? attrs["model"].to_s.strip : target.config.model.to_s,
        "reasoning_effort" => attrs.key?("reasoning_effort") ? attrs["reasoning_effort"].to_s.strip.downcase : target.config.reasoning_effort.to_s
      }
      result["model"] = nil if result["model"].to_s.empty?
      result["reasoning_effort"] = nil if result["reasoning_effort"].to_s.empty?
      result
    end

    def immutable_project_field!(attrs, field, expected)
      return unless attrs.key?(field)

      value = attrs[field].to_s.strip
      return if value.empty? || value == expected.to_s

      raise Error.new("Project #{field} cannot be changed from Remote UI")
    end

    def required_text(attrs, key, fallback:)
      text = attrs[key].to_s
      text = attrs[fallback].to_s if text.strip.empty?
      raise Error.new("#{key} is required") if text.strip.empty?

      text
    end

    def prompt_text(attrs, attachments:)
      text = attrs["prompt"].to_s
      text = attrs["content"].to_s if text.strip.empty?
      return text unless text.strip.empty?
      return "Please review the attached files." if attachments.any?

      raise Error.new("prompt is required")
    end

    def render_prompt_pull_request_contexts(target, attrs)
      contexts = attrs["pull_request_contexts"]
      return "" unless contexts.is_a?(Array) && contexts.any?
      if contexts.length > MAX_PROMPT_PULL_REQUEST_CONTEXTS
        raise Error.new("Attach at most #{MAX_PROMPT_PULL_REQUEST_CONTEXTS} pull request ranges.", status: 400)
      end

      rendered = contexts.map do |raw|
        raise Error.new("Pull request context must be an object.", status: 400) unless raw.is_a?(Hash)

        reference = pull_request_reference!(target, raw["pull_request_id"])
        snapshot = @pull_request_diff_store.fetch(reference.id)
        raise Error.new("Fetch the pull request diff before attaching lines.", status: 409) unless snapshot

        rendered = PullRequestSelection.render(snapshot, raw)
        comment = raw["comment"].to_s.strip
        if comment.bytesize > MAX_PROMPT_PULL_REQUEST_COMMENT_BYTES
          raise Error.new("Pull request comments must be at most 8 KB.", status: 400)
        end
        comment.empty? ? rendered : [rendered, "Comment on this range:\n#{comment}"].join("\n")
      rescue PullRequestSelection::Error => e
        raise Error.new(e.message, status: 409)
      end
      rendered.join("\n")
    end

    def inquiry_answer_with_feedback(answer, feedback, supplied:)
      parsed = JSON.parse(answer)
      return [answer, false] unless parsed.is_a?(Hash)

      if supplied || !parsed.key?("user_feedback")
        parsed["user_feedback"] = feedback.empty? ? nil : feedback
      end
      [JSON.pretty_generate(parsed), true]
    rescue JSON::ParserError
      [answer, false]
    end

    def truthy?(value)
      value == true || %w[true yes on 1].include?(value.to_s.downcase)
    end

    def import_prompt_attachments(target, attrs)
      uploads = attrs["attachments"]
      return [] unless uploads.is_a?(Array) && uploads.any?

      AgentAttachmentStore.new(target).import_remote_uploads!(uploads)
    rescue ArgumentError => e
      raise Error.new(e.message, status: 400)
    end

    def agent_payload(agent, reference_context: nil, relationship_context: nil)
      delegation = delegation_payload(agent, reference_context:, relationship_context:)
      status = agent.status
      inquiry = inquiry_payload(agent)
      {
        key: agent.key,
        name: agent.display_name,
        project_key: agent.project_key,
        template_key: agent.template_key,
        scheduled: agent.scheduled?,
        schedule_key: agent.schedule_key,
        workspace: agent.workspace,
        prompt: agent.prompt,
        sandbox_mode: agent.sandbox_mode,
        agent: agent.agent,
        model: agent.model,
        reasoning_effort: agent.reasoning_effort,
        response_style: agent.response_style,
        response_style_source: agent.last_run&.response_style_source || agent.effective_response_style_source,
        status: status,
        running: agent.running?,
        unread: agent.unread?,
        awaiting_input: status == "awaiting-input" && !inquiry.nil?,
        blocked: status == "blocked",
        run_count: agent.run_count,
        created_at: agent.created_at&.iso8601,
        started_at: agent.started_at&.iso8601,
        finished_at: agent.finished_at&.iso8601,
        updated_at: agent.last_activity_at&.iso8601,
        pid: agent.pid,
        last_exit_code: agent.last_exit_code,
        last_result: agent.last_result_label,
        summary: agent.last_summary,
        cost_snapshot: agent.cost_snapshot,
        latest_inquiry: inquiry,
        suspended_inquiry: suspended_inquiry_payload(agent),
        prompt_queue: prompt_queue_payload(agent),
        attachments: attachment_payloads(agent),
        skills: agent.skills,
        skill_trigger: SkillDiscovery.trigger_for(agent.agent),
        session_id: agent.session_id.to_s.empty? ? nil : agent.session_id,
        log_path: agent.raw_log_path,
        memory_path: agent.memory_path,
        revision: agent_revision(agent),
        archived: agent.archived?,
        archive_path: agent.archive_path,
        archived_at: agent.archived_at&.iso8601,
        delegation: delegation
      }
    end

    def agent_list_payload(agent, reference_context: nil, relationship_context: nil)
      {
        key: agent.key,
        name: agent.display_name,
        project_key: agent.project_key,
        template_key: agent.template_key,
        scheduled: agent.scheduled?,
        schedule_key: agent.schedule_key,
        agent: agent.agent,
        model: agent.model,
        reasoning_effort: agent.reasoning_effort,
        status: agent.status,
        running: agent.running?,
        unread: agent.unread?,
        awaiting_input: agent.status == "awaiting-input",
        blocked: agent.status == "blocked",
        run_count: agent.run_count,
        created_at: agent.created_at&.iso8601,
        started_at: agent.started_at&.iso8601,
        finished_at: agent.finished_at&.iso8601,
        updated_at: agent.last_activity_at&.iso8601,
        last_exit_code: agent.last_exit_code,
        last_result: agent.last_result_label,
        summary: agent.last_summary,
        prompt_queue_count: agent.queued_prompts.length,
        prompt_queue_dispatch_error: agent.prompt_queue_dispatch_error,
        revision: agent_revision(agent),
        archived: agent.archived?,
        archived_at: agent.archived_at&.iso8601,
        delegation: delegation_payload(agent, reference_context:, relationship_context:)
      }
    end

    def positive_integer(value, default:, name:)
      text = value.to_s.strip
      return default if text.empty?

      parsed = Integer(text, 10)
      raise ArgumentError unless parsed.positive?

      parsed
    rescue ArgumentError
      raise Error.new("#{name} must be a positive integer", status: 400)
    end

    def delegation_payload(agent, reference_context: nil, relationship_context: nil)
      reference_context ||= delegation_reference_context
      relationship_context ||= delegation_relationship_context
      relationships = {
        "parent" => relationship_context.fetch(:parents)[agent.key],
        "children" => relationship_context.fetch(:children).fetch(agent.key, [])
      }
      parent_relation = relationships.fetch("parent")
      {
        server_id: @agent_store.delegation_coordinator.delegation_store.server_identity.fetch("id"),
        parent: parent_relation ? delegation_reference_payload(parent_relation, "parent", reference_context:) : nil,
        children: relationships.fetch("children").map do |relation|
          delegation_reference_payload(relation, "child", reference_context:)
        end
      }
    end

    def delegation_reference_payload(relation, side, reference_context:)
      reference_payload(relation.fetch(side), reference_context:).merge(
        relationship_id: relation.fetch("id"),
        connected: relation["connected"] != false,
        owner: relation.fetch("owner", "parent"),
        ownership_generation: relation.fetch("ownership_generation", 1),
        ownership_changed_at: relation["ownership_changed_at"],
        connection_changed_at: relation["connection_changed_at"]
      ).compact
    end

    def delegation_relationship_context
      @agent_store.delegation_coordinator.relationship_index
    end

    def delegation_reference_context(active_agents = load_all_agents)
      active = active_agents.to_h { |agent| [agent.key, agent] }
      archived = @agent_archive_store.all.to_h { |record| [record.agent.key, record.agent] }
      {
        active:,
        archived:,
        visible_keys: visible_agents(active_agents).to_h { |agent| [agent.key, true] }
      }
    end

    def reference_payload(reference, reference_context:)
      key = reference.fetch("agent_key")
      active = reference_context.fetch(:active)[key]
      archived = active ? nil : reference_context.fetch(:archived)[key]
      state = if active
                reference_context.fetch(:visible_keys)[key] ? "active" : "hidden"
              elsif archived
                archived_agent_visible?(archived) ? "archived" : "hidden"
              else
                "missing"
              end
      payload = {
        server_id: reference["server_id"],
        agent_key: key,
        state: state,
        archived: state == "archived"
      }
      unless state == "hidden"
        payload[:status] = active&.status || archived&.status
        payload[:name] = reference["name"]
        payload[:project_key] = reference["project_key"]
        payload[:run_id] = reference["run_id"]
        payload[:run_number] = reference["run_number"]
        payload[:native_session_id] = reference["native_session_id"]
      end
      payload.compact
    end

    def archived_agent_visible?(agent)
      hidden = agent.project_hidden_at_archive
      !hidden unless hidden.nil?
    end

    def associate_delegation_from_attrs!(target, attrs, agents: nil, creating: false,
                                         actor: DelegationActor.user_actor)
      parent_key = attrs["parent_agent_key"].to_s.strip
      if actor.parent?
        if !parent_key.empty? && parent_key != actor.agent_key
          raise Error.new("An agent can delegate only as itself", status: 403)
        end
      end
      if parent_key.empty?
        return target unless creating

        return @agent_store.persist_with_delegation!(agents: agents || load_all_agents, child: target, creating: true)
      end

      current = agents || load_all_agents
      parent = current.find { |agent| agent.key == parent_key }
      unless parent && HQ::Visibility.agent_visible?(parent, @projects)
        raise Error.new("Unknown parent agent: #{parent_key}", status: 404)
      end
      @agent_store.persist_with_delegation!(
        agents: current,
        child: target,
        parent_key: parent_key,
        parent_server_id: attrs["parent_server_id"],
        creating:,
        actor:
      )
    rescue DelegationStore::Error => e
      raise Error.new(e.message, status: 409)
    end

    def delegation_actor_from_attrs(attrs)
      parent_key = attrs["parent_agent_key"].to_s.strip
      return DelegationActor.user_actor if parent_key.empty?

      DelegationActor.parent_actor(parent_key)
    end

    def sanitized_delegation_block(content, metadata, reference_context:)
      data = metadata.is_a?(Hash) ? metadata.dup : metadata
      author = data.is_a?(Hash) ? data["message_author"] : nil
      if author.is_a?(Hash) && author["type"] == "agent" && !author["agent_key"].to_s.empty?
        payload = reference_payload(author, reference_context:)
        data["message_author"] = { "type" => "agent" }.merge(payload.transform_keys(&:to_s))
      end
      reference = data.is_a?(Hash) ? data["agent_reference"] : nil
      return [content, data] unless reference.is_a?(Hash)

      payload = reference_payload(reference, reference_context:)
      data["agent_reference"] = payload.transform_keys(&:to_s)
      return [content, data] unless payload[:state] == "hidden"

      data.delete("delegation_report")
      replacement = content.start_with?("Delegated agent report:") ?
        "Delegated agent report unavailable: hidden agent" : "Started hidden agent"
      [replacement, data]
    end

    def truncate(text, length)
      value = text.to_s.gsub(/\s+/, " ").strip
      return value if value.length <= length

      "#{value[0, length - 3]}..."
    end

    def time_text(time)
      time ? time.strftime("%Y-%m-%d %H:%M:%S") : "unknown time"
    end

    def empty_to_nil(value)
      text = value.to_s
      text.empty? ? nil : text
    end

    def attachment_payloads(agent)
      agent.attachments.map { |attachment| attachment_payload(agent, attachment) }
    end

    def attachment_payload(agent, attachment)
      payload = attachment.dup
      payload["id"] = attachment_id(agent, attachment)
      payload["agent_key"] = agent.key
      payload["type"] = AttachmentNormalizer.link_attachment?(payload) ? "link" : "file"
      payload["format"] = attachment_format(payload, workspace: agent.workspace)
      if payload["type"] == "file"
        payload["blob_path"] = "/attachments/#{payload["id"]}/blob"
        attach_file_version_metadata!(payload, agent)
      end
      payload
    end

    def attach_file_version_metadata!(payload, agent)
      path = attachment_file_path(payload, agent.workspace)
      return unless path && File.file?(path)

      stat = File.stat(path)
      payload["content_mtime"] = stat.mtime.iso8601
      payload["size_bytes"] = stat.size
    rescue SystemCallError
      nil
    end

    def attachment_id(agent, attachment)
      existing = attachment["id"].to_s.strip
      return existing if existing.match?(/\A[A-Za-z0-9_-]{8,80}\z/)

      Digest::SHA256.hexdigest(
        [
          agent.key,
          attachment["type"],
          attachment["kind"],
          attachment["title"],
          attachment["path"],
          attachment["url"],
          attachment["created_at"]
        ].map(&:to_s).join("\0")
      )[0, 20]
    end

    def find_attachment!(id)
      target_id = id.to_s
      load_agents.each do |agent|
        agent.attachments.each do |attachment|
          return [agent, attachment] if attachment_id(agent, attachment) == target_id
        end
      end

      raise Error.new("Attachment not found", status: 404)
    end

    def attachment_format(attachment, workspace: nil)
      return "link" if AttachmentNormalizer.link_attachment?(attachment)

      target = AttachmentNormalizer.attachment_target(attachment).downcase
      mime_type = attachment["mime_type"].to_s.downcase
      return "image" if mime_type.start_with?("image/") || target.match?(/\.(avif|gif|heic|jpe?g|png|svg|webp)\z/)

      path = attachment_file_path(attachment, workspace) unless workspace.to_s.empty?
      if path && File.file?(path)
        plain_text = plain_text_file?(path)
        return "html" if target.match?(/\.html?(?:[?#].*)?\z/) && plain_text
        return "markdown" if target.match?(/\.(md|markdown)(?:[?#].*)?\z/) && plain_text
        return plain_text ? "text" : "binary"
      end

      return "html" if mime_type == "text/html" || target.match?(/\.html?(?:[?#].*)?\z/)
      return "markdown" if target.match?(/\.(md|markdown)(?:[?#].*)?\z/)
      return "text" if mime_type.start_with?("text/") ||
                       mime_type.match?(/\Aapplication\/(json|x-ndjson)\z/) ||
                       target.match?(/\.(csv|json|jsonl|log|txt|tsv)(?:[?#].*)?\z/)

      "binary"
    end

    def plain_text_file?(path)
      sample = File.open(path, "rb") { |file| file.read(ATTACHMENT_TEXT_SNIFF_LIMIT) }.to_s
      return true if sample.empty?
      return false if sample.include?("\x00")

      utf8 = sample.dup.force_encoding(Encoding::UTF_8)
      return false unless utf8.valid_encoding?

      control_bytes = sample.bytes.count do |byte|
        byte < 32 && ![9, 10, 12, 13, 27].include?(byte)
      end
      control_bytes <= [sample.bytesize / 100, 8].max
    rescue SystemCallError
      false
    end

    def attachment_file_path(attachment, workspace)
      resolved_attachment_path(attachment["path"].to_s.empty? ? attachment["url"] : attachment["path"], workspace)
    end

    def resolved_attachment_path(target, workspace)
      value = target.to_s.strip
      return nil if value.empty?
      return resolved_file_uri_path(value) if value.match?(/\Afile:/i)
      return nil if value.match?(/\A[a-z][a-z0-9+.-]*:/i)

      base = workspace.to_s.empty? ? Dir.pwd : workspace.to_s
      value.start_with?("~") ? File.expand_path(value) : File.expand_path(value, base)
    end

    def resolved_file_uri_path(value)
      uri = URI.parse(value)
      return nil unless uri.scheme.to_s.downcase == "file"
      return nil unless uri.host.to_s.empty? || uri.host == "localhost"

      path = uri.path.to_s
      return nil if path.empty?

      File.expand_path(URI::DEFAULT_PARSER.unescape(path))
    rescue URI::InvalidURIError
      nil
    end

    def attachment_content_type(attachment, path)
      attachment["mime_type"].to_s.strip.empty? ? AttachmentNormalizer.mime_type_for_path(path) : attachment["mime_type"].to_s
    end

    def html_preview_assets(content, html_path, workspace)
      workspace_root = File.realpath(workspace.to_s)
      remaining = HTML_PREVIEW_ASSET_LIMIT
      references = content.scan(/\b(?:href|src)\s*=\s*(["'])(.*?)\1/i).map(&:last).uniq
      references.filter_map do |reference|
        next if reference.empty? || reference.start_with?("#", "/")
        next if reference.match?(/\A(?:[a-z][a-z0-9+.-]*:|\/\/)/i)

        relative = URI::DEFAULT_PARSER.unescape(reference.split(/[?#]/, 2).first.to_s)
        candidate = File.realpath(File.expand_path(relative, File.dirname(html_path)))
        next unless candidate.start_with?("#{workspace_root}#{File::SEPARATOR}")
        next unless File.file?(candidate)

        content_type = HTML_PREVIEW_ASSET_TYPES[File.extname(candidate).downcase]
        next unless content_type

        size = File.size(candidate)
        next if size > remaining

        remaining -= size
        bytes = File.binread(candidate)
        [reference, "data:#{content_type};base64,#{Base64.strict_encode64(bytes)}"]
      rescue SystemCallError, URI::InvalidURIError
        nil
      end.to_h
    rescue SystemCallError
      {}
    end

    def http_quoted_filename(value)
      name = value.to_s.empty? ? "attachment" : value.to_s
      name.gsub(/[\\"]/, "_").gsub(/[\x00-\x1f\x7f]/, "_")
    end

    def cleanup_uploaded_attachment_file(agent, attachment)
      return unless attachment["source"].to_s == "remote_upload"

      path = attachment_file_path(attachment, agent.workspace)
      return unless path

      asset_root = File.expand_path(File.join(AGENT_LOGS_DIR, "assets", agent.key.to_s))
      expanded = File.expand_path(path)
      return unless expanded.start_with?("#{asset_root}#{File::SEPARATOR}")

      FileUtils.rm_f(expanded)
      dir = File.dirname(expanded)
      FileUtils.rm_rf(dir) if dir.start_with?("#{asset_root}#{File::SEPARATOR}") && Dir.exist?(dir) && Dir.empty?(dir)
    rescue SystemCallError
      nil
    end

    def auth_status
      return "token required" if @auth_required
      return "token recommended" if token_recommended?

      "local access"
    end

    def auth_warning
      return nil unless token_recommended?

      "Set TYCHO_REMOTE_TOKEN before using non-local Remote UI URLs."
    end

    def token_recommended?
      return false if @auth_required

      public = @public_url.to_s
      return false if public.empty?
      return false if public.start_with?("http://127.") || public.start_with?("http://localhost")

      true
    end

    def safety_guidance
      lines = [
        "Running agents cannot be edited.",
        "Existing workspaces are read-only in the mobile UI."
      ]
      lines << auth_warning if auth_warning
      lines
    end

    def agent_revision(agent)
      paths = [agent.raw_log_path, agent.memory_path, agent.attachments_path, HQ::AGENTS_FILE]
      paths.filter_map do |path|
        File.mtime(path).to_f if path && File.exist?(path)
      rescue SystemCallError
        nil
      end.max.to_s
    end

    def inquiry_payload(agent)
      inquiry = agent.latest_inquiry
      return nil unless inquiry.is_a?(Hash)

      inquiry_payload_for(agent, inquiry, agent.latest_inquiry_id)
    end

    def suspended_inquiry_payload(agent)
      inquiry = agent.suspended_inquiry
      return nil unless inquiry.is_a?(Hash)

      inquiry_payload_for(agent, inquiry, agent.suspended_inquiry_id)
    end

    def inquiry_payload_for(agent, inquiry, inquiry_id)
      payload = deep_dup_hash(inquiry)
      id = inquiry_id.to_s
      payload["id"] = id unless id.empty?
      payload["session_id"] = agent.session_id.to_s unless agent.session_id.to_s.empty?
      payload["run_count"] = agent.run_count
      payload["run_started_at"] = agent.last_run&.started_at&.iso8601 || agent.started_at&.iso8601
      payload["run_finished_at"] = agent.last_run&.finished_at&.iso8601 || agent.finished_at&.iso8601
      payload
    end

    def prompt_queue_payload(agent)
      {
        "entries" => agent.queued_prompts.map { |entry| prompt_queue_entry_payload(agent, entry) },
        "dispatch_error" => agent.prompt_queue_dispatch_error,
        "blocked_by_inquiry" => agent.inquiry_blocking_prompt_queue?
      }
    end

    def prompt_client_request_id(attrs)
      value = attrs["client_request_id"].to_s.strip
      return nil unless value.match?(/\Aclient-[a-zA-Z0-9-]{1,100}\z/)

      value
    end

    def prompt_queue_entry_payload(_agent, entry)
      {
        "id" => entry["id"],
        "prompt" => entry["prompt"],
        "accepted_at" => entry["accepted_at"],
        "updated_at" => entry["updated_at"],
        "state" => entry["state"] || "queued",
        "attachments" => Array(entry["attachments"]).map do |attachment|
          attachment.slice("id", "type", "kind", "title", "mime_type", "size_bytes", "created_at")
        end
      }.compact
    end

    def deep_dup_hash(value)
      JSON.parse(JSON.generate(value))
    rescue JSON::ParserError, JSON::GeneratorError
      value.dup
    end
  end
end
