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
require_relative "../lib/hq/version"
require_relative "../lib/hq/domain/managed_agent"
require_relative "../lib/hq/domain/remote_cli_client"

module CLICommandTest
  ROOT = File.expand_path("..", __dir__)
  EXECUTABLE = File.join(ROOT, "bin", "tycho")

  module_function

  def run!
    assert_version_output
    assert_project_commands_manage_full_lifecycle
    assert_project_command_and_help_paths_do_not_create_projects
    assert_agent_queue_notice_and_read_outputs
    assert_remote_server_commands_manage_full_agent_lifecycle
    assert_remote_client_reports_timeout_and_unsupported_operation
    assert_debug_claude_is_listed_in_usage
    assert_metrics_commands_are_listed_in_usage
    assert_debug_claude_run_agent_uses_claude_defaults
    puts "cli_command_test: ok"
  end

  def assert_version_output
    %w[--version -v].each do |flag|
      result = run_tycho({}, flag)
      assert(result.fetch(:status).success? && result.fetch(:stdout) == "Tycho #{HQ::VERSION}\n" &&
             result.fetch(:stderr).empty?, "expected #{flag} to print the Tycho version")
    end
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
      target_schedules = File.join(target_dir, "schedules.yml")
      File.write(target_config, <<~YAML)
        projects:
          - key: demo
            name: Remote Demo
            path: #{workspace}
            agent: codex
      YAML
      File.write(target_prompts, "{}\n")
      File.write(target_schedules, "schedules: []\n")

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
        "TYCHO_SCHEDULES_PATH" => target_schedules,
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
        assert(inline_auth.fetch(:stderr).include?("inline token") &&
               inline_auth.fetch(:stderr).include?("tycho server migrate peer-inline"),
               "expected the inline fallback to warn with its migration command")

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

        updated_project = run_tycho(local_env, "project", "update", "demo", "--name", "Renamed Remote Demo",
                                    "--server", "peer", "--json")
        assert(updated_project.fetch(:status).success? &&
               JSON.parse(updated_project.fetch(:stdout)).fetch("name") == "Renamed Remote Demo",
               "expected remote project update to use PATCH")
        rejected_project_create = run_tycho(local_env, "project", "create", "not-local", "--server", "peer", "--json")
        assert(!rejected_project_create.fetch(:status).success? && rejected_project_create.fetch(:stderr).empty? &&
               JSON.parse(rejected_project_create.fetch(:stdout)).fetch("ok") == false,
               "expected remote project create to fail as JSON without changing the local registry")

        doctor = run_tycho(local_env, "doctor", "--server", "peer")
        assert(doctor.fetch(:status).success? && doctor.fetch(:stdout).include?("Remote Tycho server peer: reachable"),
               "expected remote doctor human output to describe connectivity")
        schedule = run_tycho(local_env, "schedule", "create", "daily", "--name", "Daily", "--cron", "0 1 * * *",
                             "--timezone", "UTC", "--project-key", "demo", "--message", "Run", "--server", "peer", "--json")
        assert(schedule.fetch(:status).success? && JSON.parse(schedule.fetch(:stdout)).dig("schedule", "key") == "daily",
               "expected remote schedule create JSON")
        schedules = run_tycho(local_env, "schedule", "list", "--server", "peer")
        assert(schedules.fetch(:status).success? && schedules.fetch(:stdout).include?("daily") &&
               schedules.fetch(:stdout).include?("Daemon: stopped"),
               "expected remote schedule list to render populated schedules and daemon status")
        paused_schedule = run_tycho(local_env, "schedule", "pause", "daily", "--server", "peer")
        assert(paused_schedule.fetch(:status).success? && paused_schedule.fetch(:stdout) == "Paused daily.\n",
               "expected remote schedule pause human output")

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
        queued_remote = run_tycho(local_env, "agent", "send", agent_key, "Queued remote input",
                                  "--server", "peer", "--json")
        assert(queued_remote.fetch(:status).success? && JSON.parse(queued_remote.fetch(:stdout)).fetch("queued"),
               "expected remote CLI send to queue while the target is running")
        remote_agent_env = local_env.merge("TYCHO_AGENT_KEY" => agent_key)
        remote_list = JSON.parse(run_tycho(remote_agent_env, "agent", "list", "--server", "peer", "--json")
                                 .fetch(:stdout))
        assert(remote_list.fetch("agents").any? { |item| item["key"] == agent_key } &&
               remote_list.dig("queue_notice", "pending_count") == 1,
               "expected remote structured list output to include the remote queue notice")
        remote_human_list = run_tycho(remote_agent_env, "agent", "list", "--server", "peer")
        assert(remote_human_list.fetch(:stdout).include?("Pending queue for #{agent_key}: 1 entry"),
               "expected remote human list output to include the remote queue notice")
        remote_status = JSON.parse(run_tycho(remote_agent_env, "agent", "status", agent_key,
                                             "--server", "peer", "--json").fetch(:stdout))
        assert(remote_status.dig("queue_notice", "pending_count") == 1,
               "expected remote structured status output to include the remote queue notice")
        remote_human_status = run_tycho(remote_agent_env, "agent", "status", agent_key, "--server", "peer")
        assert(remote_human_status.fetch(:stdout).include?("Pending queue for #{agent_key}: 1 entry"),
               "expected remote human status output to include the remote queue notice")
        remote_json_send = JSON.parse(run_tycho(remote_agent_env, "agent", "send", agent_key,
                                                "Remote JSON notice", "--server", "peer", "--json").fetch(:stdout))
        assert(remote_json_send.dig("queue_notice", "pending_count") == 2,
               "expected remote structured send output to include the remote queue notice")
        remote_human_send = run_tycho(remote_agent_env, "agent", "send", agent_key,
                                      "Remote human notice", "--server", "peer")
        assert(remote_human_send.fetch(:stdout).include?("Pending queue for #{agent_key}: 3 entries"),
               "expected remote human send output to include the remote queue notice")

        read_remote = run_tycho(remote_agent_env, "queue", agent_key, "--server", "peer", "--json")
        assert(read_remote.fetch(:status).success?,
               "expected remote queue read to succeed: #{read_remote.fetch(:stderr)}")
        read_remote_payload = JSON.parse(read_remote.fetch(:stdout))
        assert(read_remote_payload.fetch("consumed_count") == 3 &&
               read_remote_payload.fetch("content") ==
               "Queued remote input\n\n---\n\nRemote JSON notice\n\n---\n\nRemote human notice",
               "expected remote CLI queue read to consume and return one consolidated batch")

        remote_config = HQ::RemoteServerConfig.new(
          key: "peer", name: "Test Peer", url: "http://127.0.0.1:#{port}", token:, token_env: ""
        )
        remote_client = HQ::RemoteCLIClient.new(remote_config)
        remote_client.request(
          "POST", "/agents/#{agent_key}/messages",
          body: {
            "prompt" => "Remote attachment JSON",
            "start" => true,
            "attachments" => [{
              "filename" => "remote-json.txt", "mime_type" => "text/plain",
              "content_base64" => ["remote JSON attachment"].pack("m0")
            }]
          }
        )
        attachment_read = JSON.parse(run_tycho(remote_agent_env, "queue", agent_key,
                                               "--server", "peer", "--json").fetch(:stdout))
        remote_attachment = attachment_read.fetch("attachments").fetch(0)
        assert(remote_attachment.fetch("path").end_with?("/original.txt") &&
               remote_attachment.fetch("title") == "remote-json.txt" &&
               remote_attachment.fetch("mime_type") == "text/plain" &&
               remote_attachment.fetch("source") == "remote_upload",
               "expected remote structured reads to return attachment targets and metadata")
        remote_conversation = remote_client.request("GET", "/agents/#{agent_key}/conversation").fetch("conversation")
        remote_read_event = remote_conversation.find do |event|
          event.dig("metadata", "queue_read") == true &&
            event.dig("metadata", "attachments") == attachment_read.fetch("attachments")
        end
        assert(remote_read_event,
               "expected the Remote read response attachments to match the single Read queue event")

        remote_client.request(
          "POST", "/agents/#{agent_key}/messages",
          body: {
            "prompt" => "Remote attachment human",
            "start" => true,
            "attachments" => [{
              "filename" => "remote-human.txt", "mime_type" => "text/plain",
              "content_base64" => ["remote human attachment"].pack("m0")
            }]
          }
        )
        human_attachment_read = run_tycho(remote_agent_env, "queue", agent_key, "--server", "peer")
        assert(human_attachment_read.fetch(:stdout).include?("Attachments:") &&
               human_attachment_read.fetch(:stdout).include?("remote-human.txt") &&
               human_attachment_read.fetch(:stdout).include?("\"source\":\"remote_upload\""),
               "expected remote human reads to return attachment targets and metadata")
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
               delegated_payload.dig("delegation", "parent", "agent_key") == parent_key &&
               delegated_payload.dig("delegation", "parent", "connected") == true,
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

      created = run_tycho(env, "project", "create", "demo", "--path", workspace, "--name", "Demo Project",
                          "--group", "Core", "--harness", "codex", "--model", "gpt-test",
                          "--reasoning-effort", "high", "--response-style", "disabled",
                          "--pr-url", "https://github.com/example/demo/pull/7", "--hidden", "true", "--json")
      assert(created.fetch(:status).success?, "expected explicit project creation to succeed: #{created.fetch(:stderr)}")
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

      no_update = run_tycho(env, "project", "update", "demo", "--json")
      assert(!no_update.fetch(:status).success? && no_update.fetch(:stderr).empty? &&
             JSON.parse(no_update.fetch(:stdout)).fetch("error") == "No fields to update",
             "expected project update JSON failures to remain machine-readable")

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
      assert(missing.fetch(:stderr).empty? && JSON.parse(missing.fetch(:stdout)).fetch("error") == "Unknown project: demo",
             "expected clear JSON missing-project error")
    end
  end

  def assert_agent_queue_notice_and_read_outputs
    Dir.mktmpdir("hq-cli-queue-test") do |dir|
      workspace = File.join(dir, "workspace")
      logs_root = File.join(dir, "logs")
      agent_logs = File.join(logs_root, "agents")
      config_path = File.join(dir, "hq.yml")
      prompts_path = File.join(dir, "system_prompts.yml")
      FileUtils.mkdir_p([workspace, agent_logs])
      File.write(config_path, <<~YAML)
        projects:
          - key: demo
            name: Demo
            path: #{workspace}
            agent: codex
      YAML
      File.write(prompts_path, "{}\n")
      pid = Process.spawn(RbConfig.ruby, "-e", "sleep 60", pgroup: true, out: File::NULL, err: File::NULL)
      now = Time.now
      agent = HQ::ManagedAgent.new(
        key: "queue-cli-agent", name: "Queue CLI", project_key: "demo", template_key: "custom",
        workspace:, prompt: "Work", agent: "codex", pid:, started_at: now,
        runs: [HQ::ManagedAgent::AgentRun.new(started_at: now, status: "running",
                                              log_path: File.join(agent_logs, "queue-cli.raw.log"))],
        log_path: File.join(agent_logs, "queue-cli.raw.log")
      )
      attachment_path = File.join(workspace, "queue-cli.txt")
      File.write(attachment_path, "CLI attachment")
      expected_attachments = [
        { "type" => "link", "title" => "Review", "url" => "https://example.test/cli-review",
          "description" => "Delegated CLI target", "source" => "delegate" },
        { "type" => "file", "title" => "CLI note", "path" => attachment_path,
          "mime_type" => "text/plain", "description" => "User CLI context", "source" => "user" }
      ]
      agent.enqueue_prompt!(prompt: "Delegated CLI result", source: "delegation_callback",
                            attachments: [expected_attachments.fetch(0)])
      agent.enqueue_prompt!(prompt: "User CLI follow-up", source: "user",
                            attachments: [expected_attachments.fetch(1)])
      File.write(File.join(logs_root, "managed_agents.json"), JSON.pretty_generate([agent.to_hash]))
      env = {
        "TYCHO_CONFIG_PATH" => config_path,
        "TYCHO_SYSTEM_PROMPTS_PATH" => prompts_path,
        "TYCHO_LOGS_ROOT" => logs_root,
        "TYCHO_AGENT_KEY" => agent.key
      }

      json_status = run_tycho(env, "agent", "status", agent.key, "--json")
      notice = JSON.parse(json_status.fetch(:stdout)).fetch("queue_notice")
      assert(notice == {
               "agent_key" => agent.key,
               "pending_count" => 2,
               "delegated_reply_count" => 1,
               "user_prompt_count" => 1,
               "read_command" => "tycho queue #{agent.key}"
             }, "expected additive structured queue notice counts")

      json_list = run_tycho(env, "agent", "list", "--json")
      list_payload = JSON.parse(json_list.fetch(:stdout))
      assert(list_payload.fetch("agents").any? { |item| item["key"] == agent.key } &&
             list_payload.fetch("queue_notice") == notice,
             "expected local structured agent list output to include the queue notice envelope")

      human_list = run_tycho(env, "agent", "list")
      assert(human_list.fetch(:stdout).include?(agent.key) &&
             human_list.fetch(:stdout).include?("Pending queue for #{agent.key}: 2 entries"),
             "expected local human agent list output to include the queue notice")

      human_status = run_tycho(env, "agent", "status", agent.key)
      assert(human_status.fetch(:stdout).include?("Pending queue for #{agent.key}: 2 entries (1 delegated, 1 user).") &&
             human_status.fetch(:stdout).include?("Run `tycho queue #{agent.key}` to read and consume the batch."),
             "expected compatible human queue notice output")

      read = run_tycho(env, "queue", agent.key, "--json")
      payload = JSON.parse(read.fetch(:stdout))
      assert(read.fetch(:status).success? && payload.fetch("consumed_count") == 2 &&
             payload.fetch("delegated_reply_count") == 1 && payload.fetch("user_prompt_count") == 1 &&
             payload.fetch("content") == "Delegated CLI result\n\n---\n\nUser CLI follow-up" &&
             payload.fetch("attachments").map { |attachment| attachment["description"] } ==
             ["Delegated CLI target", "User CLI context"],
             "expected structured queue read output to return one mixed batch with complete attachments")

      json_send = run_tycho(env, "agent", "send", agent.key, "JSON queued prompt", "--json")
      assert(JSON.parse(json_send.fetch(:stdout)).dig("queue_notice", "pending_count") == 1,
             "expected local structured send output to include the queue notice")
      requeued = run_tycho(env, "agent", "send", agent.key, "Human queue read")
      assert(requeued.fetch(:status).success? && requeued.fetch(:stdout).include?("Pending queue for #{agent.key}: 2 entries"),
             "expected local human send output to surface the queue notice")
      human_read = run_tycho(env, "queue", agent.key)
      assert(human_read.fetch(:status).success? &&
             human_read.fetch(:stdout).include?("Read queue for #{agent.key}: 2 entries (0 delegated, 2 user)") &&
             human_read.fetch(:stdout).end_with?("Human queue read\n"),
             "expected compatible human queue read output")

      persisted_path = File.join(logs_root, "managed_agents.json")
      persisted = JSON.parse(File.read(persisted_path)).map { |attrs| HQ::ManagedAgent.from_hash(attrs) }
      persisted_agent = persisted.find { |candidate| candidate.key == agent.key }
      persisted_agent.enqueue_prompt!(
        prompt: "Human attachment read", source: "user",
        attachments: [{ "type" => "link", "title" => "Human target",
                        "url" => "https://example.test/human", "description" => "Human metadata" }]
      )
      File.write(persisted_path, JSON.pretty_generate(persisted.map(&:to_hash)))
      human_attachment_read = run_tycho(env, "queue", agent.key)
      assert(human_attachment_read.fetch(:status).success? &&
             human_attachment_read.fetch(:stdout).include?("Attachments:") &&
             human_attachment_read.fetch(:stdout).include?("https://example.test/human") &&
             human_attachment_read.fetch(:stdout).include?("\"description\":\"Human metadata\""),
             "expected local human queue reads to return attachment targets and metadata")

      empty = run_tycho(env, "queue", agent.key)
      assert(!empty.fetch(:status).success? && empty.fetch(:stderr).include?("No pending queue entries"),
             "expected repeated reads not to consume or invent work")
    ensure
      if pid
        Process.kill("TERM", -pid)
        Process.wait(pid)
      end
    end
  end

  def assert_project_command_and_help_paths_do_not_create_projects
    Dir.mktmpdir("hq-cli-project-command-test") do |dir|
      workspace = File.join(dir, "workspace")
      config_path = File.join(dir, "hq.yml")
      prompts_path = File.join(dir, "system_prompts.yml")
      initial_registry = "projects: []\n"
      FileUtils.mkdir_p(workspace)
      File.write(config_path, initial_registry)
      File.write(prompts_path, "{}\n")
      env = {
        "TYCHO_CONFIG_PATH" => config_path,
        "TYCHO_SYSTEM_PROMPTS_PATH" => prompts_path,
        "TYCHO_LOGS_ROOT" => File.join(dir, "logs")
      }

      %w[--help -h].each do |help_flag|
        root_help = run_tycho(env, "project", help_flag)
        assert_successful_help(root_help, "project #{help_flag}", "Create a project")
        assert_registry_unchanged(config_path, initial_registry, "project #{help_flag}")
      end

      %w[create list show update archive].each do |command|
        %w[--help -h].each do |help_flag|
          result = run_tycho(env, "project", command, help_flag)
          assert_successful_help(result, "project #{command} #{help_flag}", "tycho project #{command}")
          assert_registry_unchanged(config_path, initial_registry, "project #{command} #{help_flag}")
        end
      end

      missing_command = run_tycho(env, "project")
      assert_failed_command(missing_command, "project", status: 64, error: "Missing project command")
      assert(missing_command.fetch(:stderr).include?("tycho project create <project-key> [options]"),
             "expected project usage to advertise explicit creation")
      assert_registry_unchanged(config_path, initial_registry, "project")

      help = run_tycho(env, "project", "help")
      assert_failed_command(help, "project help", status: 1, error: "Unexpected argument for tycho project: help")
      assert_registry_unchanged(config_path, initial_registry, "project help")

      list = run_tycho(env, "project", "list")
      assert(list.fetch(:status).success?, "expected project list to succeed: #{list.fetch(:stderr)}")
      assert(list.fetch(:stdout) == "No projects found.\n", "expected empty project list on stdout")
      assert(list.fetch(:stderr).empty?, "expected project list stderr to be empty")
      assert_registry_unchanged(config_path, initial_registry, "project list")

      %w[show update archive].each do |command|
        result = run_tycho(env, "project", command)
        assert_failed_command(result, "project #{command}", status: 1)
        assert_registry_unchanged(config_path, initial_registry, "project #{command}")
      end

      shorthand = run_tycho(env, "project", "demo", "--path", workspace)
      assert_failed_command(shorthand, "project demo", status: 1, error: 'ERROR: "tycho project" was called with arguments')
      assert_registry_unchanged(config_path, initial_registry, "project demo")

      missing_key = run_tycho(env, "project", "create")
      assert_failed_command(missing_key, "project create", status: 1)
      assert_registry_unchanged(config_path, initial_registry, "project create")

      malformed_commands = [
        ["project", "create", "demo", "extra"],
        ["project", "list", "extra"],
        ["project", "list", "--unknown-option"],
        ["project", "--path", workspace]
      ]
      malformed_commands.each do |args|
        result = run_tycho(env, *args)
        command = args.join(" ")
        assert_failed_command(result, command, status: 1)
        assert_registry_unchanged(config_path, initial_registry, command)
      end

      explicit = run_tycho(env, "project", "create", "demo", "--path", workspace,
                           "--agent", "codex", "--json")
      assert(explicit.fetch(:status).success?, "expected project create to remain intentional and clear: #{explicit.fetch(:stderr)}")
      assert(explicit.fetch(:stderr).empty?, "expected explicit project create stderr to be empty")
      explicit_payload = JSON.parse(explicit.fetch(:stdout))
      assert(explicit_payload.fetch("key") == "demo", "expected explicit project create key")
      assert(explicit_payload.fetch("harness") == "codex", "expected --agent alias to set the harness")
      assert(YAML.safe_load_file(config_path, aliases: true).fetch("projects").map { |project| project.fetch("key") } == ["demo"],
             "expected only explicit project creation to mutate the registry")

      created_registry = File.binread(config_path)
      malformed_existing_commands = [
        ["project", "show", "demo", "extra"],
        ["project", "update", "demo", "extra", "--name", "Mutated"],
        ["project", "archive", "demo", "extra"]
      ]
      malformed_existing_commands.each do |args|
        result = run_tycho(env, *args)
        command = args.join(" ")
        assert_failed_command(result, command, status: 1, error: "Unexpected argument for tycho project")
        assert_registry_unchanged(config_path, created_registry, command)
      end

      shown = run_tycho(env, "project", "show", "demo", "--json")
      assert(shown.fetch(:status).success?, "expected project show to remain functional: #{shown.fetch(:stderr)}")
      assert(JSON.parse(shown.fetch(:stdout)).fetch("key") == "demo", "expected project show payload")
    end
  end

  def assert_successful_help(result, command, expected_usage)
    assert(result.fetch(:status).success?, "expected #{command} help to succeed: #{result.fetch(:stderr)}")
    assert(result.fetch(:stdout).include?(expected_usage), "expected #{command} help on stdout")
    assert(!result.fetch(:stdout).include?("tycho project PROJECT_KEY"),
           "expected #{command} help not to advertise shorthand creation")
    assert(result.fetch(:stderr).empty?, "expected #{command} help stderr to be empty")
  end

  def assert_failed_command(result, command, status:, error: nil)
    assert(result.fetch(:status).exitstatus == status,
           "expected #{command} to exit #{status}, got #{result.fetch(:status).exitstatus}")
    assert(result.fetch(:stdout).empty?, "expected #{command} stdout to be empty")
    assert(!result.fetch(:stderr).empty?, "expected #{command} to explain the failure on stderr")
    assert(result.fetch(:stderr).include?(error), "expected #{command} stderr to include #{error.inspect}") if error
  end

  def assert_registry_unchanged(config_path, initial_registry, command)
    assert(File.binread(config_path) == initial_registry, "expected #{command} not to mutate the project registry")
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
    env = { "TYCHO_AGENT_KEY" => nil }.merge(env)
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
