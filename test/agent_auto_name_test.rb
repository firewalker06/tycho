# frozen_string_literal: true

require "tmpdir"
require_relative "../lib/hq/domain/agent_store"

module AgentAutoNameTest
  module_function

  def assert(value, message)
    raise message unless value
  end

  def agent(dir, name: "Project custom 1", tracked: true, adapter: "codex")
    HQ::ManagedAgent.new(key: "auto-name", name:, project_key: "project", template_key: "custom",
                         workspace: dir, prompt: "Fix the export", agent: adapter,
                         auto_name_default: tracked ? "Project custom 1" : nil,
                         log_path: File.join(dir, "#{rand(1_000_000)}.raw.log"))
  end

  def first_run(target)
    run = HQ::ManagedAgent::AgentRun.new(started_at: Time.now, status: "success", run_id: "first",
                           metadata: { "agent_title_requested" => true })
    target.send(:record_run!, run)
  end

  def result(target, title)
    payload = { "status" => "success", "summary" => "The export works.", "agent_title_suggestion" => title }
    target.define_singleton_method(:read_structured_result_payload_from_log) { payload }
    target.build_summary!
  end

  def run!
    Dir.mktmpdir("agent-auto-name") do |dir|
      ["codex", "claude", "opencode", "pi"].each do |adapter|
        target = agent(dir, adapter:)
        first_prompt = target.send(:prompt_for_execution)
        assert(first_prompt.include?("agent_title_suggestion"), "#{adapter}: missing first prompt request")
        first_run(target)
        assert(target.send(:prompt_for_execution).include?("only if the user asks"), "#{adapter}: missing later title request boundary")
        target = HQ::ManagedAgent.from_hash(target.to_hash)
        assert(!target.send(:prompt_for_execution).include?("For this first prompt only"), "#{adapter}: repeated request after reload")
        result(target, "Export Repair")
        assert(target.name == "Export Repair", "#{adapter}: default not renamed")
        assert(target.summary == "The export works.", "title changed summary")
        result(target, "Late Replacement")
        assert(target.name == "Export Repair", "summary rebuild changed title")
      end

      [nil, "", "   ", 42, [], "one two three four", "one\u00a0two\u00a0three\u00a0four", "x" * 40, "x" * 41, "line\nbreak", "\e[31mred", "---"].each do |title|
        target = agent(dir)
        first_run(target)
        result(target, title)
        assert(target.name == "Project custom 1", "invalid title renamed agent: #{title.inspect}")
        result(target, "Later Title")
        assert(target.name == "Project custom 1", "invalid first title was retried during summary rebuild")
      end
      ["x" * 39, "Three Word Name", "日本語の名前"].each do |title|
        target = agent(dir)
        first_run(target)
        result(target, title)
        assert(target.name == title, "valid boundary title rejected")
      end
      [["Manual Name", true], ["Project custom 1", false], ["My Project custom 1 notes", false]].each do |name, tracked|
        target = agent(dir, name:, tracked:)
        first_run(target)
        result(target, "Export Repair")
        assert(target.name == name, "manual or legacy name replaced")
      end
      target = agent(dir)
      first_run(target)
      target.rename!("User Choice")
      target.rename!("Project custom 1")
      target = HQ::ManagedAgent.from_hash(target.to_hash)
      result(target, "Export Repair")
      assert(target.name == "Project custom 1", "user rename race lost after reload")
      target = agent(dir)
      first_run(target)
      target.send(:record_run!, HQ::ManagedAgent::AgentRun.new(started_at: Time.now, status: "success", run_id: "second", metadata: {}))
      result(target, "Delayed Title")
      assert(target.name == "Delayed Title", "later run did not replace a tracked default title")
      clone = HQ::AgentStore.new([]).clone_agent(agent(dir), existing_agents: [])
      first_run(clone)
      result(clone, "Clone Rename")
      assert(clone.name == "Project custom 1", "clone name changed")

      failed = agent(dir)
      first_run(failed)
      failed.last_run.status = "failed"
      failed = HQ::ManagedAgent.from_hash(failed.to_hash)
      assert(!failed.send(:prompt_for_execution).include?("For this first prompt only"), "failed launch retry repeated title request")

      live = agent(dir)
      first_run(live)
      live.last_run.status = "running"
      result(live, "Early Title")
      assert(live.name == "Project custom 1", "live summary rebuild consumed the title")
      live.last_run.status = "success"
      result(live, "Final Title")
      assert(live.name == "Final Title", "terminal title was lost after live rebuild")
      legacy = agent(dir)
      legacy.send(:record_run!, HQ::ManagedAgent::AgentRun.new(started_at: Time.now, status: "success"))
      result(legacy, "Legacy Title")
      assert(legacy.name == "Legacy Title", "tracked default title required a first-run request flag")

      # Replay the reported follow-up after the first run and a cold reload.
      [true, false].each do |tracked|
        target = agent(dir, tracked:)
        first_run(target)
        result(target, nil)
        retry_run = HQ::ManagedAgent::AgentRun.new(started_at: Time.now, status: "success", run_id: "retry",
                                                  metadata: {})
        target.send(:record_run!, retry_run)
        target = HQ::ManagedAgent.from_hash(target.to_hash)
        result(target, "Title Retry")
        expected = tracked ? "Title Retry" : "Project custom 1"
        assert(target.name == expected, "later title did not respect default-name provenance after reload")
        result(target, "Stale Replacement")
        assert(target.name == expected, "summary rebuild reapplied a later title")
        target.send(:record_run!, HQ::ManagedAgent::AgentRun.new(started_at: Time.now, status: "success", run_id: "third",
                                metadata: {}))
        result(target, "Another Title")
        assert(target.name == expected, "later suggestion replaced a non-default title")
      end

      target = agent(dir, name: "Manual Name", tracked: false)
      first_run(target)
      target.send(:record_run!, HQ::ManagedAgent::AgentRun.new(started_at: Time.now, status: "success", run_id: "manual",
                              metadata: {}))
      result(target, "Title Again Fix")
      assert(target.name == "Manual Name", "valid suggestion replaced a manual title")

      [nil, "", "one two three four", "x" * 40, "line\nbreak"].each do |title|
        target = agent(dir)
        first_run(target)
        target.send(:record_run!, HQ::ManagedAgent::AgentRun.new(started_at: Time.now, status: "success", run_id: "invalid",
                                metadata: {}))
        result(target, title)
        assert(target.name == "Project custom 1", "invalid later title changed a default name")
      end

      target = agent(dir)
      first_run(target)
      target.send(:record_run!, HQ::ManagedAgent::AgentRun.new(started_at: Time.now, status: "running", run_id: "rename",
                              metadata: {}))
      result(target, "Early Title")
      assert(target.name == "Project custom 1", "live later title changed the name")
      target.rename!("User Choice")
      target.rename!("Project custom 1")
      target.last_run.status = "success"
      target = HQ::ManagedAgent.from_hash(target.to_hash)
      result(target, "Stale Title")
      assert(target.name == "Project custom 1", "manual rename during the run was overwritten")

      payload = { "status" => "input_required", "summary" => "Choose an export.",
                  "agent_title_suggestion" => "Export Choice", "inquiry" => { "message" => "Which export?" } }
      events = [payload, { "type" => "result", "structured_output" => payload },
                { "type" => "item.completed", "item" => { "type" => "agent_message", "text" => JSON.generate(payload) } },
                { "type" => "message_end", "message" => { "role" => "assistant", "content" => [{ "type" => "text", "text" => JSON.generate(payload) }] } }]
      events.each do |event|
        parsed = HQ::AgentStructuredResult.normalize_payload(event)
        normalized = HQ::AgentResultNormalizer.new(workspace: dir).normalize_structured_result(parsed)
        assert(normalized["agent_title_suggestion"] == "Export Choice", "terminal parser lost title")
        assert(normalized["inquiry"]["message"] == "Which export?", "title broke inquiry")
      end
      codex = agent(dir)
      command = codex.send(:build_command).fetch(:command)
      native_path = command.fetch(command.index("--output-schema") + 1)
      native_schema = JSON.parse(File.read(native_path))
      assert(native_schema["properties"].keys.sort == native_schema.fetch("required").sort,
             "Invalid Codex schema: required must include every property, including agent_title_suggestion")
      assert(codex.log_files.include?(native_path), "native schema must follow agent archive cleanup")
      assert(native_path != HQ::AGENT_RESULT_SCHEMA, "Codex needs a separate strict schema")
      assert(native_schema.dig("properties", "agent_title_suggestion", "type").include?("null"), "native title must accept null")
      assert(agent(dir, adapter: "claude").send(:command_result_schema_path) == HQ::AGENT_RESULT_SCHEMA,
             "Claude should retain the optional canonical schema")
      old_payload = { "status" => "success", "summary" => "Done.", "summary_sections" => nil,
                      "inquiry" => nil, "attachments" => nil, "memory_handoff" => nil }
      canonical = JSON.parse(File.read(HQ::AGENT_RESULT_SCHEMA))
      assert(HQ::AgentStructuredOutputValidator.new(schema: canonical).validate(old_payload).valid?,
             "older payload without a title must still validate")

      [nil, "Export Repair"].each do |title|
        assert(HQ::AgentStructuredOutputValidator.new(schema: native_schema).validate(old_payload.merge("agent_title_suggestion" => title)).valid?,
               "Codex schema must accept a null or suggested title")
      end

      migration_path = File.join(dir, "old_schema.json")
      File.write(migration_path, JSON.generate("type" => "object", "properties" => { "summary" => { "type" => "string" } }, "required" => ["summary"]))
      HQ.migrate_agent_result_schema!(migration_path)
      migrated = JSON.parse(File.read(migration_path))
      assert(migrated["properties"].key?("agent_title_suggestion"), "old schema did not gain optional field")
      assert(!migrated["required"].include?("agent_title_suggestion"), "migration made title mandatory")

      schema = JSON.parse(File.read(HQ::AGENT_RESULT_SCHEMA))
      assert(schema["properties"].key?("agent_title_suggestion"), "schema missing title field")
      assert(!schema.fetch("required").include?("agent_title_suggestion"), "title must remain optional")
      puts "agent_auto_name_test: ok"
    end
  end
end

AgentAutoNameTest.run! if $PROGRAM_NAME == __FILE__
