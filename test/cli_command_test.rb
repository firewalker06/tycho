# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "socket"
require "stringio"
require "tmpdir"
require "yaml"

require_relative "../lib/hq/cli_command"
require_relative "../lib/hq/domain/managed_agent"
require_relative "../lib/hq/domain/remote_cli_client"

module CLICommandTest
  ROOT = File.expand_path("..", __dir__)
  EXECUTABLE = File.join(ROOT, "bin", "tycho")

  module_function

  def run!
    assert_project_commands_manage_full_lifecycle
    assert_remote_server_commands_manage_full_agent_lifecycle
    assert_remote_client_reports_timeout_and_unsupported_operation
    assert_github_commands_cover_device_login_status_and_logout
    assert_debug_claude_is_listed_in_usage
    assert_metrics_commands_are_listed_in_usage
    assert_debug_claude_run_agent_uses_claude_defaults
    puts "cli_command_test: ok"
  end

  def assert_remote_server_commands_manage_full_agent_lifecycle
    Dir.mktmpdir("hq-cli-remote-test") do |dir|
      port = available_port
      token = "remote-cli-test-token"
      target_dir = File.join(dir, "target")
      local_dir = File.join(dir, "local")
      workspace = File.join(target_dir, "workspace")
      FileUtils.mkdir_p([workspace, local_dir])
      fake_codex = File.join(dir, "fake-codex")
      File.write(fake_codex, <<~SH)
        #!/bin/sh
        sleep 20
      SH
      FileUtils.chmod(0o755, fake_codex)

      target_config = File.join(target_dir, "hq.yml")
      target_prompts = File.join(target_dir, "system_prompts.yml")
      File.write(target_config, <<~YAML)
        projects:
          - key: demo
            name: Remote Demo
            path: #{workspace}
            agent: codex
      YAML
      File.write(target_prompts, "{}\n")

      local_config = File.join(local_dir, "hq.yml")
      local_prompts = File.join(local_dir, "system_prompts.yml")
      File.write(local_config, <<~YAML)
        projects: []
        remote_servers:
          - key: peer
            name: Test Peer
            url: http://127.0.0.1:#{port}
            token_env: TYCHO_TEST_PEER_TOKEN
          - key: peer-inline
            name: Inline Test Peer
            url: http://127.0.0.1:#{port}
            token: #{token}
      YAML
      File.write(local_prompts, "{}\n")

      server_env = {
        "TYCHO_CONFIG_PATH" => target_config,
        "TYCHO_SYSTEM_PROMPTS_PATH" => target_prompts,
        "TYCHO_LOGS_ROOT" => File.join(target_dir, "logs"),
        "TYCHO_REMOTE_TOKEN" => token,
        "TYCHO_CODEX_BIN" => fake_codex
      }
      local_env = {
        "TYCHO_CONFIG_PATH" => local_config,
        "TYCHO_SYSTEM_PROMPTS_PATH" => local_prompts,
        "TYCHO_LOGS_ROOT" => File.join(local_dir, "logs"),
        "TYCHO_TEST_PEER_TOKEN" => token
      }

      with_remote_server(server_env, port, File.join(dir, "server.log")) do
        projects = run_tycho(local_env, "project", "list", "--server", "peer", "--json")
        assert(projects.fetch(:status).success?, "expected remote project list: #{projects.fetch(:stderr)}")
        assert(JSON.parse(projects.fetch(:stdout)).fetch(0).fetch("key") == "demo",
               "expected remote project list payload")
        missing_external = run_tycho(local_env.except("TYCHO_TEST_PEER_TOKEN"),
                                     "project", "list", "--server", "peer")
        assert(!missing_external.fetch(:status).success? &&
               missing_external.fetch(:stderr).include?("requires environment variable TYCHO_TEST_PEER_TOKEN"),
               "expected configured external credentials to fail without falling back")
        inline_auth = run_tycho(local_env.except("TYCHO_TEST_PEER_TOKEN"),
                                "project", "list", "--server", "peer-inline", "--json")
        assert(inline_auth.fetch(:status).success? &&
               !inline_auth.fetch(:stdout).include?(token) && !inline_auth.fetch(:stderr).include?(token),
               "expected inline token auth without credential output")
        assert(inline_auth.fetch(:stderr).include?("removed in v0.11.0"),
               "expected the inline fallback to warn about its removal")

        migrated = run_tycho(local_env, "server", "migrate", "peer-inline")
        credential_path = File.join(local_dir, "remote_credentials.json")
        migrated_config = YAML.safe_load_file(local_config)
        assert(migrated.fetch(:status).success? && File.stat(credential_path).mode & 0o777 == 0o600 &&
               !migrated_config.fetch("remote_servers").find { |item| item["key"] == "peer-inline" }.key?("token"),
               "expected migration to move the inline token into a private credential file")
        unverified = run_tycho(local_env, "server", "status", "peer-inline", "--json")
        assert(JSON.parse(unverified.fetch(:stdout)).fetch("state") == "unverified",
               "expected migrated credentials to start unverified")
        verified = run_tycho(local_env, "server", "verify", "peer-inline")
        assert(verified.fetch(:status).success?, "expected explicit credential verification: #{verified.fetch(:stderr)}")
        logged_out = run_tycho(local_env, "server", "logout", "peer-inline")
        assert(logged_out.fetch(:status).success? && logged_out.fetch(:stdout).include?("Removed stored credential"),
               "expected logout to remove only the stored credential")
        logged_in = run_tycho(local_env, "server", "login", "peer-inline", "--no-verify", stdin_data: "#{token}\n")
        assert(logged_in.fetch(:status).success? && !logged_in.fetch(:stdout).include?(token) &&
               !logged_in.fetch(:stderr).include?(token),
               "expected hidden-input login to save without printing the credential")
        run_tycho(local_env, "server", "verify", "peer-inline")

        project = run_tycho(local_env, "project", "show", "demo", "--server", "peer", "--json")
        assert(project.fetch(:status).success?, "expected remote project show: #{project.fetch(:stderr)}")
        assert(JSON.parse(project.fetch(:stdout)).fetch("name") == "Remote Demo",
               "expected normalized remote project detail")

        created = run_tycho(local_env, "agent", "create", "demo", "Remote CLI lifecycle test",
                            "--name", "Remote CLI test", "--server", "peer", "--json")
        assert(created.fetch(:status).success?, "expected remote agent create: #{created.fetch(:stderr)}")
        agent_key = JSON.parse(created.fetch(:stdout)).fetch("key")

        listed = run_tycho(local_env, "agent", "list", "demo", "--server", "peer", "--json")
        listed_payload = JSON.parse(listed.fetch(:stdout))
        assert(listed_payload.any? { |agent| agent["key"] == agent_key },
               "expected remote agent list to include created agent")
        expected_agent_keys = %w[agent archive_path archived delegation finished_at key last_exit_code last_run_at
                                 log_path model name pid project_key prompt run_count running schedule_key started_at
                                 status workspace].sort
        assert(listed_payload.fetch(0).keys.sort == expected_agent_keys,
               "expected stable local/remote agent JSON fields")
        status = run_tycho(local_env, "agent", "status", agent_key, "--server", "peer", "--json")
        assert(JSON.parse(status.fetch(:stdout)).fetch("key") == agent_key,
               "expected remote agent status payload")

        started = run_tycho(local_env, "agent", "run", agent_key, "--server", "peer", "--json")
        assert(started.fetch(:status).success? && JSON.parse(started.fetch(:stdout)).fetch("running"),
               "expected remote agent run to start the target")
        stopped = run_tycho(local_env, "agent", "stop", agent_key, "--server", "peer", "--json")
        assert(stopped.fetch(:status).success? && !JSON.parse(stopped.fetch(:stdout)).fetch("running"),
               "expected remote agent stop to stop the target")

        sent = run_tycho(local_env, "agent", "send", agent_key, "Continue remotely",
                         "--server", "peer", "--json")
        assert(sent.fetch(:status).success? && JSON.parse(sent.fetch(:stdout)).fetch("running"),
               "expected remote agent send to append and start")
        run_tycho(local_env, "agent", "stop", agent_key, "--server", "peer", "--json")

        parent = run_tycho(local_env, "agent", "create", "demo", "Coordinate children",
                           "--name", "CLI parent", "--server", "peer", "--json")
        parent_key = JSON.parse(parent.fetch(:stdout)).fetch("key")
        delegated = run_tycho(local_env, "agent", "create", "demo", "Delegated work",
                              "--parent-agent", parent_key, "--server", "peer", "--json")
        delegated_payload = JSON.parse(delegated.fetch(:stdout))
        assert(delegated.fetch(:status).success? &&
               delegated_payload.dig("delegation", "parent", "agent_key") == parent_key,
               "expected remote CLI creation to attach a server-local parent")
        parent_status = run_tycho(local_env, "agent", "status", parent_key, "--server", "peer", "--json")
        assert(JSON.parse(parent_status.fetch(:stdout)).dig("delegation", "children", 0, "agent_key") ==
               delegated_payload.fetch("key"), "expected parent CLI JSON to list delegated children")
        rejected_self = run_tycho(local_env, "agent", "run", parent_key,
                                  "--parent-agent", parent_key, "--server", "peer")
        assert(!rejected_self.fetch(:status).success?, "expected CLI self-parent rejection")

        archived = run_tycho(local_env, "agent", "archive", agent_key, "--server", "peer", "--json")
        assert(archived.fetch(:status).success? && JSON.parse(archived.fetch(:stdout)).fetch("archived"),
               "expected remote agent archive")

        archived_status = run_tycho(local_env, "agent", "status", agent_key, "--server", "peer", "--json")
        assert(archived_status.fetch(:status).success?, "expected archived remote agent history to remain addressable")
        archived_list = run_tycho(local_env, "agent", "list", "--archived", "--server", "peer", "--json")
        archived_list_payload = JSON.parse(archived_list.fetch(:stdout))
        assert(archived_list.fetch(:status).success? && archived_list_payload.one? &&
               archived_list_payload.fetch(0).fetch("key") == agent_key &&
               archived_list_payload.fetch(0).fetch("archived") &&
               !archived_list_payload.fetch(0).fetch("archived_at").to_s.empty?,
               "expected remote CLI archived-agent discovery")
        local_archived_list = run_tycho(server_env, "agent", "list", "--archived", "--json")
        assert(local_archived_list.fetch(:status).success? &&
               JSON.parse(local_archived_list.fetch(:stdout)).any? { |item| item["key"] == agent_key && item["archived"] },
               "expected local CLI archived-agent discovery")
        local_archived_run = run_tycho(server_env, "agent", "run", agent_key)
        assert(!local_archived_run.fetch(:status).success? && local_archived_run.fetch(:stderr).include?("read-only"),
               "expected local CLI mutations to identify archived agents")
        conflicting_list = run_tycho(local_env, "agent", "list", "--archived", "--include-archived",
                                     "--server", "peer")
        assert(!conflicting_list.fetch(:status).success? && conflicting_list.fetch(:stderr).include?("either"),
               "expected conflicting archive list flags to fail clearly")
        active_list = JSON.parse(run_tycho(local_env, "agent", "list", "--server", "peer", "--json").fetch(:stdout))
        assert(active_list.none? { |item| item["key"] == agent_key },
               "expected the default agent list to remain active-only")
        combined_list = JSON.parse(run_tycho(local_env, "agent", "list", "--include-archived",
                                             "--server", "peer", "--json").fetch(:stdout))
        assert(combined_list.any? { |item| item["key"] == agent_key && item["archived"] } &&
               combined_list.any? { |item| item["key"] == parent_key && !item["archived"] },
               "expected remote CLI combined active and archived discovery")
        unknown = run_tycho(local_env, "agent", "list", "--server", "unknown")
        assert(!unknown.fetch(:status).success? && unknown.fetch(:stderr).include?("Unknown remote server: unknown"),
               "expected a clear unknown-server error")
        bad_auth = run_tycho(local_env.merge("TYCHO_TEST_PEER_TOKEN" => "wrong"),
                             "agent", "list", "--server", "peer")
        assert(!bad_auth.fetch(:status).success? && bad_auth.fetch(:stderr).include?("authentication failed") &&
               !bad_auth.fetch(:stderr).include?("wrong"),
               "expected an auth error without credentials")
        rejected = run_tycho(local_env, "server", "status", "peer", "--json")
        assert(JSON.parse(rejected.fetch(:stdout)).fetch("state") == "rejected",
               "expected rejected external credentials to remain visible as metadata")
        recovered = run_tycho(local_env, "server", "verify", "peer")
        assert(recovered.fetch(:status).success?, "expected explicit verification to recover rejected credentials")
        external_logout = run_tycho(local_env, "server", "logout", "peer")
        assert(external_logout.fetch(:stdout).include?("External source TYCHO_TEST_PEER_TOKEN is still active") &&
               !external_logout.fetch(:stdout).include?(token),
               "expected logout to report but never modify or print the external source")
      end

      unreachable = run_tycho(local_env, "agent", "list", "--server", "peer")
      assert(!unreachable.fetch(:status).success? && unreachable.fetch(:stderr).include?("is unreachable"),
             "expected a clear unreachable-server error")
    end
  end

  def assert_metrics_commands_are_listed_in_usage
    output = StringIO.new
    status = HQ::CLICommand.usage(nil, err: output)
    text = output.string

    assert(status.zero?, "expected metrics help rendering to succeed")
    assert(text.include?("metrics query") && text.include?("metrics backfill"),
           "expected metrics query and backfill in CLI usage")
  end

  def assert_remote_client_reports_timeout_and_unsupported_operation
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr.fetch(1)
    config = HQ::RemoteServerConfig.new(key: "slow", name: "Slow", url: "http://127.0.0.1:#{port}", token: "", token_env: "")
    thread = Thread.new do
      socket = server.accept
      sleep 0.2
      socket.close
    end
    client = HQ::RemoteCLIClient.new(config, open_timeout: 0.05, read_timeout: 0.05)
    begin
      client.request("GET", "/agents")
      raise "expected remote timeout"
    rescue HQ::RemoteCLIClient::Error => e
      assert(e.kind == :timeout && e.message.include?("timed out"), "expected a typed timeout error")
    ensure
      thread.join
      server.close
    end

    begin
      client.request("TRACE", "/agents")
      raise "expected unsupported remote operation"
    rescue HQ::RemoteCLIClient::Error => e
      assert(e.kind == :unsupported && e.message.include?("Unsupported remote operation"),
             "expected a typed unsupported-operation error")
    end


    token = "must-not-appear"
    error_server = TCPServer.new("127.0.0.1", 0)
    error_port = error_server.addr.fetch(1)
    error_thread = Thread.new do
      socket = error_server.accept
      while (line = socket.gets)
        break if line == "\r\n"
      end
      body = JSON.generate(error: "upstream echoed #{token}")
      socket.write("HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      socket.close
    end
    secret_config = HQ::RemoteServerConfig.new(
      key: "error",
      name: "Error",
      url: "http://127.0.0.1:#{error_port}",
      token: token,
      token_env: ""
    )
    begin
      HQ::RemoteCLIClient.new(secret_config).request("GET", "/agents")
      raise "expected remote API error"
    rescue HQ::RemoteCLIClient::Error => e
      assert(!e.message.include?(token) && e.message.include?("[REDACTED]"),
             "expected remote API errors to redact credentials")
    ensure
      error_thread.join
      error_server.close
    end
    end
  def assert_github_commands_cover_device_login_status_and_logout
    auth = Class.new do
      attr_reader :logged_out

      def initialize
        @polls = 0
        @logged_out = false
      end

      def start_device_flow
        {
          id: "login-id",
          user_code: "ABCD-EFGH",
          verification_uri: "https://github.com/login/device",
          interval: 1
        }
      end

      def poll_device_flow(id)
        raise "unexpected login id" unless id == "login-id"

        @polls += 1
        return { status: "pending", retry_after: 1 } if @polls == 1

        { status: "authenticated", account: "octocat" }
      end

      def capability
        {
          enabled: true,
          source: "github_app",
          app: { configured: true, authenticated: true, account: "octocat" },
          gh: { available: true, authenticated: true }
        }
      end

      def logout
        @logged_out = true
      end
    end.new
    out = StringIO.new
    err = StringIO.new
    sleeps = []

    code = HQ::CLICommand.github_login(out:, err:, auth:, sleeper: ->(seconds) { sleeps << seconds })
    assert(code == 0 && out.string.include?("Code: ABCD-EFGH") && out.string.include?("@octocat"),
           "expected CLI GitHub device login guidance and completion")
    assert(sleeps == [1, 1], "expected CLI login polling to honor GitHub's interval")

    out = StringIO.new
    assert(HQ::CLICommand.github_status(out:, err:, auth:) == 0 &&
           out.string.include?("GitHub provider: github_app"),
           "expected CLI GitHub status to identify the active provider")

    out = StringIO.new
    assert(HQ::CLICommand.github_logout(out:, err:, auth:) == 0 && auth.logged_out,
           "expected CLI GitHub logout to remove the local App session")

    usage = StringIO.new
    HQ::CLICommand.usage(nil, err: usage)
    assert(usage.string.include?("tycho github login") &&
           usage.string.include?("tycho github status") &&
           usage.string.include?("tycho github logout"),
           "expected usage to list GitHub authentication commands")
  end

  def assert_project_commands_manage_full_lifecycle
    Dir.mktmpdir("hq-cli-project-test") do |dir|
      workspace = File.join(dir, "workspace")
      config_path = File.join(dir, "hq.yml")
      prompts_path = File.join(dir, "system_prompts.yml")
      logs_root = File.join(dir, "logs")
      schedules_path = File.join(dir, "schedules.yml")
      FileUtils.mkdir_p(workspace)
      File.write(config_path, "projects: []\n")
      File.write(prompts_path, "{}\n")
      File.write(schedules_path, "schedules: []\n")
      env = {
        "TYCHO_CONFIG_PATH" => config_path,
        "TYCHO_SYSTEM_PROMPTS_PATH" => prompts_path,
        "TYCHO_LOGS_ROOT" => logs_root,
        "TYCHO_SCHEDULES_PATH" => schedules_path
      }

      created = run_tycho(env, "project", "demo", "--path", workspace, "--name", "Demo Project",
                          "--group", "Core", "--harness", "codex", "--model", "gpt-test",
                          "--reasoning-effort", "high", "--response-style", "disabled",
                          "--pr-url", "https://github.com/example/demo/pull/7", "--hidden", "true", "--json")
      assert(created.fetch(:status).success?, "expected shorthand project creation to succeed: #{created.fetch(:stderr)}")
      created_payload = JSON.parse(created.fetch(:stdout))
      assert(created_payload["key"] == "demo", "expected created project key")
      assert(created_payload["path"] == workspace, "expected created project path")
      assert(created_payload["harness"] == "codex", "expected created project harness")
      assert(created_payload["response_style"] == false, "expected disabled response style")
      assert(created_payload["hidden"] == true, "expected hidden project override")

      shown = run_tycho(env, "project", "show", "demo", "--json")
      assert(shown.fetch(:status).success?, "expected project show to succeed: #{shown.fetch(:stderr)}")
      shown_payload = JSON.parse(shown.fetch(:stdout))
      assert(shown_payload["model"] == "gpt-test", "expected project show to expose model")
      assert(shown_payload["pr_url"].end_with?("/pull/7"), "expected project show to expose PR URL")

      updated = run_tycho(env, "project", "update", "demo", "--name", "Demo Updated", "--group=",
                          "--model=", "--reasoning-effort", "low", "--response-style", "default",
                          "--pr-url=", "--hidden", "inherit", "--json")
      assert(updated.fetch(:status).success?, "expected project update to succeed: #{updated.fetch(:stderr)}")
      updated_payload = JSON.parse(updated.fetch(:stdout))
      assert(updated_payload["name"] == "Demo Updated", "expected updated project name")
      assert(updated_payload["group"].nil?, "expected project group to clear")
      assert(updated_payload["model"].nil?, "expected project model to clear")
      assert(updated_payload["reasoning_effort"] == "low", "expected project effort to update")
      assert(updated_payload["response_style"].nil?, "expected response style to return to global default")
      assert(updated_payload["pr_url"].nil?, "expected PR URL to clear")
      assert(updated_payload["hidden_override"].nil?, "expected visibility to inherit")

      explicit = run_tycho(env, "project", "create", "explicit", "--path", workspace, "--json")
      assert(explicit.fetch(:status).success?, "expected explicit project create to succeed: #{explicit.fetch(:stderr)}")
      assert(JSON.parse(explicit.fetch(:stdout))["key"] == "explicit", "expected explicit project create key")
      agent_created = run_tycho(env, "agent", "create", "explicit", "Check this project")
      assert(agent_created.fetch(:status).success?, "expected project fixture agent creation to succeed")
      agent_key = JSON.parse(File.read(File.join(logs_root, "managed_agents.json"))).fetch(0).fetch("key")
      explicit_archived = run_tycho(env, "project", "archive", "explicit", "--json")
      assert(explicit_archived.fetch(:status).success?,
             "expected project archive with agents to succeed: #{explicit_archived.fetch(:stderr)}")
      assert(JSON.parse(explicit_archived.fetch(:stdout)).fetch("archived_agent_keys") == [agent_key],
             "expected project archive to include managed agents")
      assert(JSON.parse(File.read(File.join(logs_root, "managed_agents.json"))).empty?,
             "expected project archive to remove managed agents from active state")

      archived = run_tycho(env, "project", "archive", "demo", "--json")
      assert(archived.fetch(:status).success?, "expected project archive to succeed: #{archived.fetch(:stderr)}")
      archived_payload = JSON.parse(archived.fetch(:stdout))
      assert(archived_payload.dig("project", "key") == "demo", "expected archived project payload")
      active = YAML.safe_load_file(config_path, aliases: true).fetch("projects")
      archived_config = YAML.safe_load_file(File.join(dir, "hq.archived.yml"), aliases: true).fetch("projects")
      assert(active.none? { |project| project["key"] == "demo" }, "expected archived project to leave active config")
      assert(archived_config.any? { |project| project["key"] == "demo" }, "expected archived project config")

      missing = run_tycho(env, "project", "show", "demo", "--json")
      assert(!missing.fetch(:status).success?, "expected archived project to be absent from project show")
      assert(missing.fetch(:stderr).include?("Unknown project: demo"), "expected clear missing-project error")
    end
  end

  def assert_debug_claude_is_listed_in_usage
    err = StringIO.new
    HQ::CLICommand.usage(nil, err: err)

    assert(err.string.include?("tycho debug claude [--run-agent]"),
           "expected usage to list the Claude debug command")
  end

  def assert_debug_claude_run_agent_uses_claude_defaults
    Dir.mktmpdir("hq-cli-debug-claude-test") do |dir|
      config_path = File.join(dir, "hq.yml")
      prompts_path = File.join(dir, "system_prompts.yml")
      logs_dir = File.join(dir, "logs")
      agents_file = File.join(logs_dir, "managed_agents.json")
      agent_logs_dir = File.join(logs_dir, "agents")
      FileUtils.mkdir_p(agent_logs_dir)
      File.write(config_path, <<~YAML)
        projects:
          - key: tycho
            name: Tycho
            path: #{dir}
            agent: codex
            model: gpt-5.1-codex-max
            reasoning_effort: high
      YAML
      File.write(prompts_path, <<~YAML)
        custom: Base prompt
      YAML

      with_env("TYCHO_CONFIG_PATH" => config_path, "TYCHO_SYSTEM_PROMPTS_PATH" => prompts_path) do
        with_constant(HQ, :AGENTS_FILE, agents_file) do
          with_constant(HQ, :AGENT_LOGS_DIR, agent_logs_dir) do
            with_stubbed_agent_start do |started_agents|
              out = StringIO.new
              err = StringIO.new
              code = HQ::CLICommand.debug_claude({ run_agent: true }, out: out, err: err)
              saved = JSON.parse(File.read(agents_file)).fetch(0)
              started = started_agents.fetch(0)

              assert(code == 0, "expected debug Claude managed-agent diagnostic to succeed")
              assert(err.string.empty?, "expected no stderr output")
              assert(out.string.include?("Tycho Claude managed-agent diagnostic"),
                     "expected managed-agent diagnostic header")
              assert(started.agent == "claude", "expected diagnostic to force the Claude harness")
              assert(started.model.nil?, "expected diagnostic to leave Claude model unset")
              assert(started.reasoning_effort.nil?, "expected diagnostic to leave Claude effort unset")
              assert(saved["agent"] == "claude", "expected persisted diagnostic agent to use Claude")
              assert(!saved.key?("model"), "expected persisted diagnostic agent to omit model override")
              assert(!saved.key?("reasoning_effort"), "expected persisted diagnostic agent to omit effort override")
            end
          end
        end
      end
    end
  end

  def with_stubbed_agent_start
    started_agents = []
    original_start = HQ::ManagedAgent.instance_method(:start!)
    original_poll = HQ::ManagedAgent.instance_method(:poll!)
    original_running = HQ::ManagedAgent.instance_method(:running?)
    HQ::ManagedAgent.define_method(:start!) do
      started_agents << self
      @started_at = Time.now
      @finished_at = @started_at
      @pid = 12_345
      @last_exit_code = 0
      @summary = "OK"
      @runs << HQ::ManagedAgent::AgentRun.new(
        started_at: @started_at,
        finished_at: @finished_at,
        exit_code: 0,
        status: "succeeded",
        log_path: @log_path,
        command: "claude --print"
      )
      true
    end
    HQ::ManagedAgent.define_method(:poll!) { nil }
    HQ::ManagedAgent.define_method(:running?) { false }
    yield started_agents
  ensure
    HQ::ManagedAgent.define_method(:start!, original_start) if original_start
    HQ::ManagedAgent.define_method(:poll!, original_poll) if original_poll
    HQ::ManagedAgent.define_method(:running?, original_running) if original_running
  end

  def run_tycho(env, *args, stdin_data: "")
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, EXECUTABLE, *args,
                                            chdir: ROOT, stdin_data: stdin_data)
    { stdout: stdout, stderr: stderr, status: status }
  end

  def available_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr.fetch(1)
  ensure
    server&.close
  end

  def with_remote_server(env, port, log_path)
    log = File.open(log_path, "w")
    pid = Process.spawn(
      env,
      RbConfig.ruby,
      EXECUTABLE,
      "serve",
      "--host",
      "127.0.0.1",
      "--port",
      port.to_s,
      chdir: ROOT,
      out: log,
      err: log
    )
    deadline = Time.now + 10
    loop do
      begin
        socket = TCPSocket.new("127.0.0.1", port)
        socket.close
        break
      rescue Errno::ECONNREFUSED
        raise "remote test server did not start:\n#{File.read(log_path)}" if Time.now >= deadline

        sleep 0.05
      end
    end
    yield
  ensure
    if pid
      begin
        Process.kill("TERM", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
    log&.close
  end

  def with_env(values)
    previous = values.each_with_object({}) { |(key, _), memo| memo[key] = ENV.key?(key) ? ENV[key] : :__unset__ }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each do |key, value|
      value == :__unset__ ? ENV.delete(key) : ENV[key] = value
    end
  end

  def with_constant(scope, name, value)
    old_value = scope.const_get(name)
    scope.send(:remove_const, name)
    scope.const_set(name, value)
    yield
  ensure
    scope.send(:remove_const, name)
    scope.const_set(name, old_value)
  end

  def assert(condition, message)
    raise message unless condition
  end
end

CLICommandTest.run! if $PROGRAM_NAME == __FILE__
