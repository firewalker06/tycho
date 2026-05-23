# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "rbconfig"
require "base64"

require_relative "../lib/hq/remote_server"

module RemoteServerTest
  module_function

  def run!
    assert_remote_agent_lifecycle
    assert_remote_agent_clone_archives_source_with_editable_name
    assert_remote_agent_payload_has_revision
    assert_remote_inquiry_payload_has_stable_id_and_guarded_answer
    assert_remote_agent_payload_includes_attachments
    assert_remote_prompt_accepts_uploaded_attachments
    assert_remote_prompt_start_accepts_dash_prefixed_message
    assert_remote_agent_conversation_keeps_run_summary
    assert_remote_project_payloads_include_status_and_detail
    assert_remote_schedule_routes
    assert_remote_setup_payload_includes_readiness
    assert_remote_setup_warns_when_public_url_has_no_token
    assert_remote_server_restart_route_schedules_restart
    assert_server_detects_unauthenticated_non_loopback_bind
    assert_remote_push_subscription_lifecycle
    assert_remote_agent_push_notifications
    assert_remote_search_index_includes_agents_and_projects
    assert_remote_skills_payload_uses_discovery
    assert_remote_project_action_requires_confirmation
    assert_remote_ui_routes_load_without_auth
    assert_write_http_keeps_keyword_body_compatibility
    assert_server_prints_public_url
    assert_server_prints_startup_messages
    assert_server_prints_public_url_qr
    assert_server_prints_request_logs
    puts "remote_server_test: ok"
  end

  def assert_remote_agent_lifecycle
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
      assert(created[:key].start_with?("web-agent-"), "expected created agent key")
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
      replace_constant(HQ, :AGENT_LOGS_DIR, old_logs_dir) if old_logs_dir
      replace_constant(HQ, :AGENT_ARCHIVE_DIR, old_archive_dir) if old_archive_dir
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

  def assert_remote_inquiry_payload_has_stable_id_and_guarded_answer
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace, apps: false)
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
        "start" => false
      )
      assert(result[:conversation].any? { |message| message[:role] == "user" && message[:content].include?("current session") },
             "expected accepted inquiry answer to be recorded as a user message")
      inquiry_reply = result[:conversation].find do |message|
        message[:role] == "user" && message.dig(:metadata, "inquiry_response")
      end
      assert(inquiry_reply, "expected accepted inquiry answer to be marked as an inquiry response")
      assert(result[:agent][:latest_inquiry].nil?, "expected accepted inquiry answer to clear the pending inquiry")
      response = HQ::AgentMemory.new(agent).events.reverse.find { |event| event["type"] == "inquiry_response" }
      assert(response.dig("metadata", "inquiry_id") == inquiry_id,
             "expected inquiry response memory to retain the answered inquiry id")
    end
  end

  def assert_remote_agent_payload_includes_attachments
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace, apps: true)
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
      File.write(File.join(workspace, "docs/release.txt"), "Plain release checklist\n")
      File.write(File.join(workspace, "docs/notes.md"), "# Notes\n\n- Check attachment viewer\n")
      file_uri_notes_path = File.join(workspace, "docs/file-uri-notes.md")
      File.write(file_uri_notes_path, "# File URI Notes\n\n- Render this from a file URL\n")
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
          "kind" => "image",
          "title" => "UI screenshot",
          "url" => image_path
        },
        created_at: Time.parse("2026-04-05 17:59:00")
      )

      payload = service.agent(created[:key])
      attachments = payload[:attachments]
      assert(attachments.map { |item| item["type"] } == %w[link file file file file],
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
      assert(list_payload[:attachments].length == 5,
             "expected Remote agents list payload to include attachments for detail rendering")
      assert(!list_payload[:updated_at].to_s.empty?,
             "expected Remote agents list payload to expose last update time for compact list metadata")
      plain_attachment = service.attachment(attachments.find { |item| item["title"] == "Release checklist" }["id"])
      assert(plain_attachment["format"] == "text", "expected txt documents to render as plain text")
      assert(plain_attachment["content"].include?("Plain release checklist"),
             "expected plain text attachment viewer content")
      markdown_attachment = service.attachment(attachments.find { |item| item["title"] == "Markdown notes" }["id"])
      assert(markdown_attachment["format"] == "markdown", "expected markdown documents to be marked for markdown rendering")
      assert(markdown_attachment["content"].include?("# Notes"), "expected markdown attachment content")
      file_uri_attachment = service.attachment(attachments.find { |item| item["title"] == "File URI notes" }["id"])
      assert(file_uri_attachment["format"] == "markdown",
             "expected file URI markdown documents to be marked for markdown rendering")
      assert(file_uri_attachment["content"].include?("# File URI Notes"),
             "expected file URI markdown attachment content")
      link_attachment = service.attachment(attachments.find { |item| item["title"] == "Implementation PR" }["id"])
      assert(!link_attachment.key?("content"), "expected link attachments to skip local file content")
      image_attachment = service.attachment(attachments.find { |item| item["title"] == "UI screenshot" }["id"])
      assert(image_attachment["format"] == "image", "expected image attachments to be marked as images")
      assert(image_attachment["blob_path"].end_with?("/blob"), "expected image attachments to expose a blob route")
      image_blob = service.attachment_blob(image_attachment["id"])
      assert(image_blob[:content_type] == "image/png", "expected image blob route to preserve image MIME type")
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
    end
  end

  def assert_remote_prompt_accepts_uploaded_attachments
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace, apps: false)
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
          }
        ]
      )

      uploads = result[:agent][:attachments].select { |attachment| attachment["source"] == "remote_upload" }
      assert(uploads.length == 2, "expected uploaded prompt attachments in the agent payload")
      assert(uploads.all? { |attachment| attachment["id"].start_with?("att_") },
             "expected uploaded prompt attachments to keep generated IDs")
      assert(uploads.all? { |attachment| attachment["type"] == "file" },
             "expected uploaded prompt attachments to use file attachment type")
      assert(uploads.all? { |attachment| attachment["path"].start_with?("/") },
             "expected uploaded prompt attachments to use absolute local file paths")
      assert(uploads.all? { |attachment| File.file?(attachment["path"]) },
             "expected uploaded prompt attachments to be written under the agent asset store")
      conversation_message = result[:conversation].find { |block| block[:kind] == "message" && block[:role] == "user" }
      assert(conversation_message.dig(:metadata, "attachments").length == 2,
             "expected conversation messages to expose uploaded attachment metadata")

      document = service.attachment(uploads.find { |item| item["title"] == "prompt-notes.md" }["id"])
      assert(document["content"].include?("Prompt Notes"), "expected uploaded markdown document preview")
      image = service.attachment(uploads.find { |item| item["title"] == "screenshot.png" }["id"])
      assert(image["blob_path"].end_with?("/blob"), "expected uploaded image to expose a blob path")
      blob = service.attachment_blob(image["id"])
      assert(blob[:body] == image_bytes, "expected uploaded image blob to be served unchanged")

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
        exit 0 if ARGV.include?("--")

        prompt = ARGV.reverse.find { |argument| argument.include?("inquiry reply") }
        if prompt&.start_with?("-")
          warn "error: unexpected argument " + prompt.inspect
          warn "For more information, try '--help'."
          exit 2
        end
      RUBY
      File.chmod(0o755, fake_codex)
      ENV["TYCHO_CODEX_BIN"] = fake_codex

      registry = registry_for_project(dir, workspace, apps: false)
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

  def assert_remote_agent_conversation_keeps_run_summary
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
      HQ::AgentMemory.new(agent).append_run_summary!(
        summary: "A detailed run summary that should stay readable in the conversation.",
        status: "succeeded",
        created_at: Time.now
      )

      summary = service.conversation(created[:key]).find { |block| block[:kind] == "run_summary" }
      assert(summary, "expected Remote UI conversation payload to include the run summary")
      assert(summary[:content].include?("A detailed run summary"),
             "expected the full run summary to remain readable in the conversation")
    ensure
      replace_constant(HQ, :AGENTS_FILE, old_agents_file) if old_agents_file
      replace_constant(HQ, :AGENT_LOGS_DIR, old_logs_dir) if old_logs_dir
      replace_constant(HQ, :AGENT_ARCHIVE_DIR, old_archive_dir) if old_archive_dir
    end
  end

  def assert_remote_project_payloads_include_status_and_detail
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace, apps: true)
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
      assert(project.key?(:health_status), "expected project health status")
      assert(project.key?(:latency_ms), "expected project latency")
      assert(project.key?(:action_state), "expected project action state key")
      detail = service.project("web")
      assert(detail[:pr_number] == "123", "expected PR number")
      assert(detail[:service] == "web-service", "expected parsed Kamal service")
      assert(detail[:image] == "ghcr.io/example/web", "expected parsed Kamal image")
      assert(detail[:hosts] == ["web-1"], "expected parsed Kamal hosts")
      assert(detail[:kamal_version] == "2.6.1", "expected parsed Kamal version")
      assert(detail[:rails_version] == "7.2.2", "expected parsed Rails version")
      assert(detail[:managed_agent_count] == 1, "expected managed-agent count")
      assert(detail[:agent_template_summaries].first[:prompt] == "Default prompt for web.",
             "expected Remote UI project detail to expose full template prompt for agent creation")
      assert(detail.dig(:recent_agent_summary, :key) == agent[:key], "expected recent agent summary")
    end
  end

  def assert_remote_schedule_routes
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      registry = registry_for(dir, workspace)
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
      server = HQ::RemoteServer.new

      listed = server.send(:route, service, "GET", "/schedules", {}, nil)
      assert(listed.dig(:body, :schedules).length == 1, "expected schedule list route")
      assert(listed.dig(:body, :daemon, :status) == "stopped", "expected schedule daemon status")

      paused = server.send(:route, service, "POST", "/schedules/weekday/pause", {}, nil)
      assert(paused.dig(:body, :schedule, :paused), "expected schedule pause route")

      resumed = server.send(:route, service, "POST", "/schedules/weekday/resume", {}, nil)
      assert(!resumed.dig(:body, :schedule, :paused), "expected schedule resume route")

      reloaded = server.send(:route, service, "POST", "/schedules/reload", {}, nil)
      assert(reloaded.dig(:body, :ok), "expected schedule reload route")
    end
  end

  def assert_remote_setup_payload_includes_readiness
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      write_archived_config(dir)
      registry = registry_for_project(dir, workspace, apps: true)
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
      assert(setup.dig(:counts, :projects) == 1, "expected active project count")
      assert(setup.dig(:counts, :archived_projects) == 1, "expected archived project count")
      assert(setup[:harnesses].map { |item| item[:name] }.sort == %w[claude claude-wrapper codex],
             "expected harness readiness entries")
      assert(setup[:tools].map { |item| item[:name] }.sort == %w[kamal mise tailscale],
             "expected optional tool readiness entries")
      assert(setup.dig(:schema, :valid) == true, "expected valid result schema")
      assert(setup.dig(:config, :prompt_template_count) == 1, "expected prompt template count")
      assert(setup[:safety].any? { |line| line.include?("confirmation") }, "expected safety defaults")
    end
  end

  def assert_remote_setup_warns_when_public_url_has_no_token
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace, apps: true)
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

  def assert_server_detects_unauthenticated_non_loopback_bind
    output = StringIO.new
    logger = Logger.new(StringIO.new)
    server = HQ::RemoteServer.new(host: "100.64.0.10", token: "", logger: logger, output: output)

    assert(server.send(:unauthenticated_non_loopback?), "expected tokenless non-loopback bind to be flagged")
  end

  def assert_remote_push_subscription_lifecycle
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      registry = registry_for_project(dir, workspace, apps: false)
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

      disabled = service.disable_push_subscription("endpoint" => "https://push.example.test/subscription/1")
      assert(!disabled[:subscribed], "expected unsubscribe response")
      assert(disabled[:subscription_count].zero?, "expected disabled subscription to be excluded from count")
    end
  end

  def assert_remote_agent_push_notifications
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace, apps: false)
      notifier = RecordingPushNotifier.new
      service = HQ::RemoteService.new(registry: registry, web_push_notifier: notifier)
      started_at = Time.now - 60

      input_agent = stale_running_agent(
        key: "web-agent-1",
        name: "Web input",
        workspace: workspace,
        started_at: started_at,
        structured_result: {
          "status" => "input_required",
          "summary" => "Needs deployment confirmation",
          "inquiry" => { "message" => "Deploy now?" }
        }
      )
      finished_agent = stale_running_agent(
        key: "web-agent-2",
        name: "Web done",
        workspace: workspace,
        started_at: started_at
      )
      HQ::AgentStore.new([]).save([input_agent, finished_agent])
      [input_agent, finished_agent].each do |agent|
        File.write(File.join(HQ::AGENT_LOGS_DIR, "#{agent.key}.status"), "0")
      end

      result = service.dispatch_agent_push_notifications!
      assert(result[:events] == 2, "expected two agent push events")
      assert(notifier.payloads.length == 2, "expected two push payloads")
      assert(notifier.payloads.any? { |payload| payload[:title] == "Agent requires response" },
             "expected requires-response notification")
      assert(notifier.payloads.any? { |payload| payload[:title] == "Agent finished" },
             "expected finished notification")
      assert(notifier.payloads.all? { |payload| payload[:url].start_with?("/#agent/") },
             "expected notification click URLs to target agent detail")
      agents = service.agents
      assert(agents.find { |agent| agent[:key] == "web-agent-1" }[:unread],
             "expected finalized input-required agent to be marked unread")
      assert(agents.find { |agent| agent[:key] == "web-agent-2" }[:unread],
             "expected finalized Codex agent to be marked unread")
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
      registry = registry_for_project(dir, workspace, apps: true)
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
      write_project_workspace(workspace)
      skill_dir = File.join(workspace, ".agents", "skills", "review")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), "# Review\n")
      registry = registry_for_project(dir, workspace, apps: true)
      service = HQ::RemoteService.new(registry: registry)

      payload = service.skills("web", "codex")
      assert(payload[:trigger] == "$", "expected Codex skill trigger")
      assert(payload[:skills].any? { |skill| skill["name"] == "review" }, "expected discovered skill")
    end
  end

  def assert_remote_project_action_requires_confirmation
    with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      write_project_workspace(workspace)
      registry = registry_for_project(dir, workspace, apps: true)
      service = HQ::RemoteService.new(registry: registry)

      preflight = service.project_action_preflight("web", "deploy")
      assert(preflight[:action] == "deploy", "expected deploy preflight")
      assert(preflight[:checks].any? { |check| check[:key] == "kamal" && check[:passed] },
             "expected Kamal preflight check")

      begin
        service.start_project_action("web", "deploy", {})
        raise "expected missing confirmation to fail"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 400, "expected missing confirmation to return 400")
      end
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
    assert(response[:body].include?("Tycho - its Factorio for agents"), "expected / body to include app shell title")
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
    assert(response[:body].match?(%r{href="/manifest\.webmanifest\?v=[0-9a-f]{12}"}),
           "expected root shell to link a versioned web app manifest")
    assert(response[:body].match?(%r{href="/favicon\.png\?v=[0-9a-f]{12}"}),
           "expected root favicon reference to use the Remote UI logo")
    assert(response[:body].match?(%r{href="/apple-touch-icon\.png\?v=[0-9a-f]{12}"}),
           "expected root shell to expose an Apple touch icon")
    assert(response[:body].match?(%r{src="/remote-logo\.png\?v=[0-9a-f]{12}"}),
           "expected root shell to render the Remote UI logo")
    assert(response[:body].include?("pull-refresh-spinner ui-icon"),
           "expected root shell to render the pull refresh hourglass icon")
    assert(response[:body].match?(%r{href="/ui\.css\?v=[0-9a-f]{12}"}),
           "expected root CSS reference to be asset-versioned")
    assert(response[:body].match?(%r{src="/ui\.js\?v=[0-9a-f]{12}"}),
           "expected root JavaScript reference to be asset-versioned")
    assert(response[:body].include?("agent-settings-button"), "expected root shell to expose Agent settings")
    assert(response[:body].include?("<svg class=\"ui-icon\""), "expected root shell controls to use SVG icons")
    %w[‹ ● ⌕ ▦ ⚙].each do |glyph|
      assert(!response[:body].include?(glyph), "expected root shell to avoid text icon glyph #{glyph.inspect}")
    end
    assert(!response[:body].include?("refresh-button"), "expected root shell to omit the header refresh button")

    service_worker = server.send(:route_ui, "/service-worker.js")
    assert(service_worker[:content_type].include?("javascript"), "expected service worker route to return JavaScript")
    assert(service_worker[:body].include?("skipWaiting"), "expected service worker updates to activate immediately")
    assert(service_worker[:body].include?("clients.claim"), "expected service worker updates to claim active clients")
    assert(service_worker[:body].include?("showNotification"), "expected service worker to display push notifications")
    assert(service_worker[:body].include?('payload.title || "Tycho"'),
           "expected service worker push fallback title to use Tycho")
    assert(service_worker[:body].include?('payload.body || "Tycho has an update."'),
           "expected service worker push fallback body to use Tycho")
    assert(service_worker[:body].include?('icon: "/pwa-icon-192.png"'),
           "expected service worker notifications to use the PWA logo icon")

    css = server.send(:route_ui, "/ui.css")
    assert(css[:content_type].include?("text/css"), "expected /ui.css to return CSS")
    %w[#282a36 #f8f8f2 #bd93f9 #ff79c6].each do |color|
      assert(css[:body].include?(color), "expected Remote UI CSS to include Dracula color #{color}")
    end
    assert(css[:body].include?("color-scheme: dark"), "expected Remote UI CSS to use the Dracula dark scheme")
    assert(css[:body].include?(".agent-dock"), "expected Agent detail to have a bottom dock")
    assert(css[:body].include?("position: fixed"), "expected Agent detail dock to stay pinned to the viewport")
    assert(css[:body].include?(".agent-floating-actions"),
           "expected Agent detail shortcuts to float above the dock")
    assert(css[:body].include?(".go-recent-fab"), "expected Agent detail to include Go to recent")
    assert(css[:body].include?(".agent-settings-panel"), "expected Agent settings to render in the header")
    assert(css[:body].include?(".agent-settings-actions"),
           "expected Agent settings to hide edit/archive actions behind the settings panel")
    assert(css[:body].include?(".agent-form"), "expected Remote UI to style agent lifecycle forms")
    assert(css[:body].include?(".inline-icon-button"), "expected Remote UI action buttons to support SVG icons")
    assert(css[:body].include?(".agent-summary-panel"), "expected Agent summary to render above the composer")
    assert(css[:body].include?("max-height: min(22dvh, 160px)"),
           "expected Agent summary to be constrained and scrollable")
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
           "expected mobile inquiry docks to leave room for the summary")
    assert(css[:body].include?("max-height: min(24dvh, 220px)"),
           "expected mobile inquiry fields to scroll in a compact viewport")
    assert(css[:body].include?("-webkit-line-clamp: 3"),
           "expected mobile inquiry banners to avoid consuming the dock")
    assert(css[:body].include?("@keyframes poll-refresh-hourglass"),
           "expected refresh indicators to use the hourglass animation")
    assert(css[:body].include?("transform: rotate(.5turn)"),
           "expected refresh hourglass animation to rotate by half a turn")
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
    assert(css[:body].include?("font-weight: 700"),
           "expected chat labels to render bold")
    assert(css[:body].include?(".message-group"),
           "expected internal chat messages to render in collapsed groups")
    assert(css[:body].include?(".message-group > summary"),
           "expected collapsed chat groups to expose a summary row")
    assert(css[:body].include?(".attachment-flyout"), "expected Agent detail to style attachment flyouts")
    assert(css[:body].include?(".attachment-item"), "expected Agent detail attachments to render as rows")
    assert(css[:body].include?(".pending-attachments"), "expected Agent detail to style pending prompt attachments")
    assert(css[:body].include?(".attachment-upload-button"), "expected Agent detail to style upload attachment controls")
    assert(css[:body].include?(".message-attachments"), "expected chat messages to style attached prompt files")
    assert(css[:body].include?(".attachment-text-viewer"), "expected Attachment detail to style plain text")
    assert(css[:body].include?(".attachment-image-viewer"), "expected Attachment detail to style image previews")
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
    assert(css[:body].include?(".skill-flyout"), "expected skills to use a floating picker")
    assert(css[:body].include?("min-height: min(180px, 42dvh)"),
           "expected the skill picker to show multiple skills before scrolling")
    assert(css[:body].include?(".agent-running-indicator"),
           "expected running agents to show an animated composer status icon")
    assert(css[:body].include?(".ui-icon"), "expected shared SVG icon styling")
    assert(css[:body].include?(".header-mark .brand-logo"), "expected Remote UI logo image styling")
    assert(css[:body].include?(".header-mark {\n  display: inline-grid;"),
           "expected Remote UI header logo to have dedicated borderless styling")
    assert(css[:body].include?(".app-header.header-hidden"),
           "expected detail headers to hide on scroll or footer focus")
    assert(css[:body].include?(".app-header.detail-header"),
           "expected detail headers to be fixed to the top")
    assert(css[:body].include?(".content.detail-page"),
           "expected detail pages to reserve space for fixed headers")
    assert(css[:body].include?("var(--agent-dock-height, 220px) + 62px"),
           "expected Agent detail content to reserve space for floating shortcuts")
    assert(css[:body].include?(".agent-dock:has(.skill-flyout:not(.hidden))"),
           "expected the skill flyout to stack above the floating Summary shortcut")
    assert(css[:body].include?(".agent-dock:has(.attachment-flyout:not(.hidden))"),
           "expected the attachment flyout to stack above the skill flyout")
    assert(css[:body].include?(".server-lifecycle-card"),
           "expected Setup restart lifecycle card to have distinct styling")
    assert(css[:body].include?(".restart-server-button"),
           "expected Setup restart action to have distinct button styling")
    js = server.send(:route_ui, "/ui.js")
    assert(js[:content_type].include?("javascript"), "expected /ui.js to return JavaScript")
    assert(js[:body].include?("DEFAULT_REFRESH_INTERVALS"), "expected UI JavaScript to define refresh defaults")
    assert(js[:body].include?('updateViaCache: "none"'),
           "expected service worker registration to bypass browser caches")
    assert(js[:body].include?("function resetRemoteCaches"),
           "expected Remote UI restart to clear browser Cache Storage")
    assert(js[:body].include?('url.searchParams.set("hq_restart"'),
           "expected Remote UI restart to reload with a cache-busting query")
    assert(js[:body].include?("Copied to clipboard"), "expected UI JavaScript to include copy feedback")
    assert(js[:body].include?("data-agent-dock"), "expected Agent detail composer to live in a dock")
    assert(js[:body].include?("function renderInquiryForm"),
           "expected Agent detail to render structured inquiry forms")
    assert(js[:body].include?('id="inquiry-form" class="inquiry-form"'),
           "expected inquiry answers to use a dedicated form")
    assert(js[:body].include?("I have reviewed this answer and want to send it."),
           "expected inquiry confirmation copy to stay concise")
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
    assert(js[:body].include?("normalizeInquiryInputType"),
           "expected Remote UI to normalize inquiry field input types")
    assert(js[:body].include?("function setAgentSettings"), "expected Agent metadata to move into header settings")
    assert(js[:body].include?("Push notifications"), "expected Setup screen to expose push readiness")
    assert(js[:body].include?("data-restart-server"), "expected Setup screen to expose Remote restart action")
    assert(js[:body].include?('class="danger inline-icon-button restart-server-button" type="button" data-restart-server'),
           "expected Remote restart action to use danger button styling")
    assert(js[:body].index("Refresh and preferences") < js[:body].index("data-restart-server"),
           "expected Remote restart action to stay at the bottom of the Setup screen")
    assert(js[:body].include?("function restartRemoteServer"), "expected Remote UI to handle Remote restarts")
    assert(js[:body].include?('apiPost("/server/restart"'),
           "expected Remote UI restart action to call the restart endpoint")
    assert(js[:body].include?("function waitForRemoteRestart"),
           "expected Remote UI to poll until restart comes back online")
    assert(js[:body].include?("MagicDNS push requires Tailscale HTTPS"),
           "expected Remote UI to warn when MagicDNS is not HTTPS")
    assert(js[:body].include?("navigator.serviceWorker.register"),
           "expected Remote UI to register the service worker")
    assert(js[:body].include?("function renderAgentForm"),
           "expected Remote UI to render create/edit agent forms")
    assert(!js[:body].include?('name="workspace"'),
           "expected Remote UI agent forms to omit editable workspace fields")
    assert(!js[:body].include?('formData.get("workspace")'),
           "expected Remote UI agent forms to let the server preserve/default workspace")
    assert(js[:body].include?("data-create-agent"),
           "expected Project detail to expose Add agent navigation")
    assert(js[:body].include?("data-edit-agent"),
           "expected Agent settings to expose edit navigation")
    assert(js[:body].include?("data-archive-agent"),
           "expected Agent settings to open archive choices")
    assert(js[:body].include?("Clone instead"),
           "expected archive choices to expose clone instead")
    assert(js[:body].include?("mode === \"clone\""),
           "expected Remote UI agent form to support clone mode")
    assert(js[:body].include?("els.agentSettingsPanel.addEventListener"),
           "expected Agent settings actions to work from the fixed header panel")
    assert(js[:body].include?("apiPatch"),
           "expected Remote UI to update agents through the API")
    assert(js[:body].include?("function toggleSkillFlyout"), "expected Insert Skill to use a floating slash picker")
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
    assert(js[:body].include?('data-toggle-skills aria-label="Insert skill" title="Insert skill" ${agentIsRunning(agent) ? "disabled" : ""}'),
           "expected Skill toggle to be disabled while the agent is running")
    assert(js[:body].include?("function agentComposerAction"),
           "expected Agent detail composer action to switch by running state")
    assert(js[:body].include?('class="danger" type="button" data-agent-action="stop" data-agent-key="${escapeAttr(agent.key)}">Stop agent'),
           "expected running agents to replace Send prompt with Stop agent")
    assert(js[:body].include?("iconSvg(\"squareSlash\")"), "expected Insert Skill to render a square slash SVG icon")
    assert(js[:body].include?("iconSvg(\"robot\")"), "expected Agent marks to render a robot SVG icon")
    assert(js[:body].include?("iconSvg(\"search\")"), "expected search controls to render an SVG icon")
    assert(js[:body].include?("iconSvg(\"scanText\")"), "expected Summary to render a scan-text SVG icon")
    assert(js[:body].include?("iconSvg(\"folder\")"), "expected Project marks to render a folder SVG icon")
    assert(js[:body].include?("function brandLogoHtml"), "expected HQ header mark to render the Remote UI logo")
    assert(js[:body].include?("els.mark.innerHTML = brandLogoHtml();"),
           "expected the Remote UI header mark to stay on the brand logo across routes")
    assert(!js[:body].include?("function markHtml"),
           "expected page-specific icons to stay out of the header brand mark")
    assert(js[:body].include?("function statusIcon"), "expected readiness marks to use SVG status icons")
    assert(js[:body].include?("data-agent-summary"), "expected Agent detail to expose a docked Summary panel")
    assert(js[:body].include?("data-preserve-scroll"),
           "expected Agent summary scroll position to survive polling renders")
    assert(js[:body].include?("function toggleAgentSummary"), "expected Summary to be toggleable")
    assert(js[:body].include?("function closeAgentSummary"), "expected Summary to close from outside interactions")
    assert(!js[:body].include?("Current activity"), "expected Current activity copy to move into Summary naming")
    assert(js[:body].include?("data-preserve-open"), "expected floating controls to preserve open state")
    assert(js[:body].include?("openElements"), "expected polling snapshots to preserve floating control state")
    assert(js[:body].include?("renderedViewHtml"),
           "expected polling renders to skip unchanged Remote UI view HTML")
    assert(js[:body].include?("scrollContainers"),
           "expected polling snapshots to preserve summary scroll position")
    assert(js[:body].include?("function syncPreservedOpenState"),
           "expected restored floating controls to update related button state")
    assert(js[:body].include?("const discovered = state.skills"),
           "expected discovered skills to take priority over stale per-agent skill snapshots")
    assert(!js[:body].include?("start-after-send"), "expected Send Prompt to start agents by default")
    assert(!js[:body].include?("Start run"), "expected Agent detail to omit redundant Start run")
    assert(js[:body].include?("function syncAgentDockLayout"),
           "expected Agent detail dock height to update page padding")
    assert(js[:body].include?("function updateDetailHeaderVisibility"),
           "expected detail header visibility to respond to scroll and footer focus")
    assert(js[:body].include?("function syncDetailHeaderLayout"),
           "expected detail content padding to track header height")
    assert(js[:body].include?("detailFooterFocused"),
           "expected detail header to hide while the footer is focused")
    assert(js[:body].include?("data-go-recent"), "expected Agent detail to show a Go to recent action")
    assert(js[:body].include?("function updateGoRecentVisibility"),
           "expected Agent detail to hide Go to recent at the bottom")
    assert(js[:body].include?("function scrollConversationToRecent"),
           "expected Agent detail to scroll conversations to the recent sentinel")
    assert(js[:body].include?("function scrollAgentConversationToBottom"),
           "expected Agent detail to auto-scroll to the bottom after agent-page renders")
    assert(js[:body].include?("preserveSummaryOnAutoScroll"),
           "expected automatic conversation scrolling to keep Summary open")
    assert(js[:body].include?("&& !state.preserveSummaryOnAutoScroll"),
           "expected manual scrolling to keep closing Summary")
    assert(js[:body].include?("openSummaryAfterAutoScroll"),
           "expected first-open Agent detail scrolling to reopen Summary after landing at the bottom")
    assert(js[:body].include?("function shouldOpenSummaryForSucceededAgent"),
           "expected Agent detail to open Summary when the active agent succeeds")
    assert(js[:body].include?("!agentSucceeded(previous) && agentSucceeded(next)"),
           "expected Summary to open only on a success transition")
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
    assert(js[:body].include?('if (agent.unread) return "unread";'),
           "expected unread agents to show unread as the visible status before final run status")
    assert(js[:body].scan('<span class="pill need">Unread</span>').length >= 2,
           "expected agent and search lists to render explicit Unread pills")
    assert(js[:body].include?("function shouldAutoScrollAgentConversation"),
           "expected Agent detail to auto-scroll only when conversation content changes")
    assert(js[:body].include?("function renderConversationBlocks"),
           "expected Agent detail to group internal conversation blocks before rendering")
    assert(js[:body].include?("function renderAgentAttachments"),
           "expected Agent detail to render saved attachments")
    assert(js[:body].include?("function renderAttachmentToggle"),
           "expected Agent detail to expose attachments from a composer toggle")
    assert(js[:body].include?("function renderPendingAttachments"),
           "expected Agent detail to render pending prompt attachments before sending")
    assert(js[:body].include?("function pendingAttachmentPayloads"),
           "expected Remote UI to serialize prompt attachments into API payloads")
    assert(js[:body].include?("data-add-prompt-attachment"),
           "expected Agent detail composer to expose a file picker trigger")
    assert(js[:body].include?("data-prompt-attachment-input"),
           "expected Agent detail composer to include a hidden file input")
    assert(js[:body].include?("content_base64"),
           "expected Remote UI prompt attachments to submit base64 file content")
    assert(js[:body].include?("function renderMessageAttachments"),
           "expected chat messages to render their own attachment rows")
    assert(js[:body].include?("function formatJsonObjectMessage"),
           "expected Remote UI to parse JSON object user replies for display")
    assert(js[:body].include?("function inquiryResponseBlock"),
           "expected Remote UI to detect inquiry response messages")
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
    assert(js[:body].include?("function attachmentViewerHtml"),
           "expected Attachment viewer markup to be reusable inside Agent detail")
    assert(js[:body].include?('return { type: "agentAttachment", key: parts[1], attachmentId: parts[3] };'),
           "expected Remote UI to support in-agent attachment routes")
    assert(js[:body].include?('routeHash({ type: "agentAttachment", key: agentKey, attachmentId: id })'),
           "expected document attachments to open inside the owning Agent detail")
    assert(js[:body].include?("function formDraftRouteKey"),
           "expected composer drafts to survive switching between conversation and attachment views")
    assert(js[:body].include?("function saveAgentShellFormDrafts"),
           "expected focused composer drafts to be saved before attachment route switches")
    assert(js[:body].include?("Loading file preview..."),
           "expected attachment views to avoid rendering empty content before preview data loads")
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
    assert(js[:body].include?("URL.createObjectURL"),
           "expected Remote UI to render fetched image blobs through object URLs")
    assert(js[:body].include?('class="attachment-image-viewer"'),
           "expected Remote UI to render image attachments as images")
    assert(js[:body].include?('return `/attachments/${encodeURIComponent(id)}/blob`;'),
           "expected Remote UI to load images from the attachment blob route")
    assert(js[:body].include?('return { type: "attachment", id: parts[1] };'),
           "expected Remote UI to support #attachment/:id routes")
    assert(js[:body].include?("function renderMarkdown"),
           "expected markdown attachments to render as markdown")
    assert(!js[:body].include?("CODE_LANGUAGE_BY_EXTENSION"),
           "expected syntax metadata inference to remain out of the attachment viewer")
    assert(js[:body].include?("https://cdn.jsdelivr.net/npm/marked@"),
           "expected markdown rendering to lazy-load marked from a pinned CDN URL")
    assert(js[:body].include?("https://cdn.jsdelivr.net/npm/dompurify@"),
           "expected markdown rendering to sanitize parsed HTML with DOMPurify")
    assert(js[:body].include?("function renderPlainTextMarkdown"),
           "expected markdown rendering to fall back to escaped plain text")
    assert(js[:body].include?('routeHash({ type: "attachment", id })'),
           "expected document attachments to open the attachment viewer")
    assert(js[:body].include?('target="_blank" rel="noreferrer"'),
           "expected link attachments to open in a new tab")
    assert(!js[:body].include?('const description = String(attachment?.description'),
           "expected attachment rows not to render descriptions")
    assert(js[:body].include?("function toggleAttachmentFlyout"),
           "expected Agent detail attachments to be toggleable")
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
           "expected Agent detail to keep run summaries visible in the conversation")
    assert(js[:body].include?("<details class=\"message-group\""),
           "expected Agent detail internal groups to be collapsed by default")
    assert(js[:body].include?("iconSvg(\"squareUserRound\")"),
           "expected user chat labels to render the square-user-round icon")
    assert(js[:body].include?("iconSvg(\"botMessageSquare\")"),
           "expected assistant chat labels to render the bot-message-square icon")
    assert(js[:body].include?("iconSvg(\"hammer\")"),
           "expected tool chat labels to render the hammer icon")
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
    assert(js[:body].include?("function focusSearchInput"), "expected Search tab to focus the search input after render")
    assert(js[:body].include?("sortedAgentGroups(filtered)"),
           "expected Agents tab to render project groups in sorted order")
    assert(js[:body].include?("function compareAgentProjectKeys"),
           "expected Agents tab group sorting to compare project display names")
    assert(js[:body].include?("function compareAgentsByName"),
           "expected Agents tab to sort agents alphabetically within each project group")
    assert(js[:body].include?("function relativeTimeShort"),
           "expected Remote UI list metadata to use compact relative times")
    assert(js[:body].include?("function relativeTimeBucket"),
           "expected Remote UI list metadata to bucket relative times by recency")
    assert(js[:body].include?("function relativeTimeHtml"),
           "expected Remote UI list metadata to color only relative time tokens")
    assert(js[:body].include?("function agentListSubtextHtml"),
           "expected Agents tab rows to build dedicated list subtitles")
    assert(js[:body].include?("function agentSearchSubtextHtml"),
           "expected Search agent rows to put relative time first")
    assert(js[:body].include?("function projectSearchSubtext"),
           "expected Search project rows to build dedicated subtitles")
    assert(js[:body].include?('class="relative-time ${escapeAttr(bucket)}"'),
           "expected Remote UI agent subtitles to render colorable relative time spans")
    assert(!js[:body].include?("Agent / ${agentMeta(agent)}"),
           "expected Search agent rows to omit redundant Agent prefix")
    assert(!js[:body].include?("Project / ${project.status"),
           "expected Search project rows to omit redundant Project prefix")
    assert(!js[:body].include?("${statusLabel(agent)} / ${agentMeta(agent)}"),
           "expected Agents tab rows to omit status from subtext")
    assert(!js[:body].include?("agent.project_key, agent.agent, agent.template_key"),
           "expected Remote UI list metadata to omit agent template keys")
    assert(!js[:body].include?('agent.template_key || "template"'),
           "expected Remote UI agent cards to omit agent template keys")
    assert(js[:body].include?("sortedProjects(state.projects)"),
           "expected Projects tab to render projects in sorted order")
    assert(js[:body].include?("function compareProjectsByName"),
           "expected Projects tab sorting to use a stable comparator")
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
    assert(parsed_manifest["name"] == "Tycho - its Factorio for agents",
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
          apps: false
    YAML
    File.write(prompts_path, <<~YAML)
      custom: Default prompt.
    YAML
    HQ::Registry.new(path: config_path, system_prompts_path: prompts_path)
  end

  def with_remote_temp_store
    Dir.mktmpdir("hq-remote-test") do |dir|
      old_agents_file = replace_constant(HQ, :AGENTS_FILE, File.join(dir, "managed_agents.json"))
      old_actions_file = replace_constant(HQ, :ACTIONS_FILE, File.join(dir, "actions.json"))
      old_schedules_file = replace_constant(HQ, :SCHEDULES_FILE, File.join(dir, "config", "schedules.yml"))
      old_schedules_state_file = replace_constant(HQ, :SCHEDULES_STATE_FILE, File.join(dir, "schedules.json"))
      old_scheduler_daemon_file = replace_constant(HQ, :SCHEDULER_DAEMON_FILE, File.join(dir, "scheduler_daemon.json"))
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
      yield dir
    ensure
      replace_constant(HQ, :AGENTS_FILE, old_agents_file) if old_agents_file
      replace_constant(HQ, :ACTIONS_FILE, old_actions_file) if old_actions_file
      replace_constant(HQ, :SCHEDULES_FILE, old_schedules_file) if old_schedules_file
      replace_constant(HQ, :SCHEDULES_STATE_FILE, old_schedules_state_file) if old_schedules_state_file
      replace_constant(HQ, :SCHEDULER_DAEMON_FILE, old_scheduler_daemon_file) if old_scheduler_daemon_file
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

  def registry_for_project(dir, workspace, apps:)
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
          apps: #{apps}
          pr_url: https://github.com/example/web/pull/123
    YAML
    File.write(prompts_path, <<~YAML)
      custom: Default prompt for %{project_key}.
    YAML
    HQ::Registry.new(path: config_path, system_prompts_path: prompts_path)
  end

  def write_project_workspace(workspace)
    FileUtils.mkdir_p(File.join(workspace, "config"))
    File.write(File.join(workspace, "config", "deploy.yml"), <<~YAML)
      service: web-service
      image: ghcr.io/example/web
      servers:
        web:
          hosts:
            - web-1
    YAML
    File.write(File.join(workspace, "Gemfile.lock"), <<~LOCK)
      GEM
        specs:
          kamal (2.6.1)
          rails (7.2.2)
    LOCK
  end

  def write_archived_config(dir)
    File.write(File.join(dir, HQ::Registry::DEFAULT_ARCHIVED_BASENAME), <<~YAML)
      projects:
        - key: archived
          name: Archived
          path: #{File.join(dir, "archived")}
    YAML
  end

  def wait_for_agent_terminal_status(service, key, timeout: 6.0)
    deadline = Time.now + timeout
    loop do
      payload = service.agent(key)
      return payload unless payload[:status] == "running"
      raise "expected agent #{key} to finish within #{timeout}s" if Time.now >= deadline

      sleep 0.05
    end
  end

  def assert_server_prints_request_logs
    output = StringIO.new
    logger = Logger.new(StringIO.new)
    server = HQ::RemoteServer.new(logger: logger, output: output)
    request = HQ::RemoteServer.const_get(:Request).new(
      method: "GET",
      path: "/health",
      headers: {},
      body: ""
    )

    server.send(:log_request, request, 200, Process.clock_gettime(Process::CLOCK_MONOTONIC))

    line = output.string
    assert(line.include?("[Remote]"), "expected console log to include Remote prefix")
    assert(line.include?("GET /health 200"), "expected console log to include request method, path, and status")
    assert(line.include?("ms"), "expected console log to include duration")
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
