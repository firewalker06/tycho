# frozen_string_literal: true

require "json"
require "tmpdir"
require "time"
require_relative "../lib/hq/domain/memory_handoff"
require_relative "../lib/hq/domain/managed_agent"
require_relative "../lib/hq/domain/agent_structured_output_validator"

module MemoryHandoffTest
  module_function

  SCHEMA_PATH = File.expand_path("../config/schemas/agent_result.json", __dir__)

  def run!
    assert_contract_normalizes_only_valid_payloads
    assert_agent_run_round_trips_metadata
    assert_schema_rejects_incomplete_handoff
    assert_schema_has_strict_compatible_handoff_shape
    assert_schema_migration_is_additive
    puts "memory_handoff_test: ok"
  end

  def assert_contract_normalizes_only_valid_payloads
    handoff = {
      "outcome" => "Implemented the contract.",
      "decisions" => ["Keep provenance in Tycho."],
      "continuing_context" => "Reconcile it daily.",
      "references" => ["docs/AGENT_MEMORY.md"],
      "lessons" => ["Keep semantic fields small."]
    }
    normalized = HQ::MemoryHandoff.normalize(handoff)
    assert(normalized == handoff, "expected valid handoff to survive normalization")
    strict_optional = handoff.merge("lessons" => nil, "promotion_candidates" => nil)
    assert(HQ::MemoryHandoff.normalize(strict_optional) == handoff.reject { |key, _| key == "lessons" },
           "expected strict nullable optional fields to be omitted from persisted metadata")
    assert(HQ::MemoryHandoff.normalize(handoff.merge("outcome" => "  ")).nil?,
           "expected blank outcome to be rejected")
    assert(HQ::MemoryHandoff.normalize(handoff.merge("server" => "not-semantic")).nil?,
           "expected provenance fields to be rejected")
  end

  def assert_agent_run_round_trips_metadata
    metadata = { "memory_handoff" => { "outcome" => "Done", "decisions" => [], "continuing_context" => "", "references" => [] } }
    run = HQ::ManagedAgent::AgentRun.new(run_id: "run-1", status: "success", metadata: metadata)
    loaded = HQ::ManagedAgent::AgentRun.from_hash(run.to_hash)
    assert(loaded.metadata == metadata, "expected handoff metadata to persist through legacy-compatible run serialization")
  end

  def assert_schema_rejects_incomplete_handoff
    schema = JSON.parse(File.read(SCHEMA_PATH))
    payload = {
      "status" => "success", "summary" => "Done", "summary_sections" => nil, "inquiry" => nil, "attachments" => nil, "action_proposals" => nil,
      "memory_handoff" => { "outcome" => "", "decisions" => [] }
    }
    result = HQ::AgentStructuredOutputValidator.new(schema:).validate(payload)
    paths = result.errors.map { |error| error["path"] }
    assert(paths.include?("$.memory_handoff.continuing_context") && paths.include?("$.memory_handoff.references"),
           "expected missing handoff contract fields, got #{result.errors.inspect}")
    assert(result.errors.any? { |error| error["code"] == "too_short" },
           "expected non-empty outcome validation")
  end

  def assert_schema_has_strict_compatible_handoff_shape
    schema = JSON.parse(File.read(SCHEMA_PATH))
    handoff = schema.dig("properties", "memory_handoff")
    assert(schema.fetch("required").include?("memory_handoff"), "expected root handoff field to be required")
    assert(handoff.fetch("type") == %w[object null], "expected nullable root handoff")
    assert(handoff.fetch("required").sort == handoff.fetch("properties").keys.sort,
           "expected strict schema to require every handoff property")
    %w[lessons promotion_candidates].each do |field|
      assert(handoff.dig("properties", field, "type") == %w[array null], "expected nullable #{field}")
    end
    valid = {
      "status" => "success", "summary" => "Done", "summary_sections" => nil, "inquiry" => nil, "attachments" => nil, "action_proposals" => nil,
      "memory_handoff" => nil
    }
    assert(HQ::AgentStructuredOutputValidator.new(schema:).validate(valid).valid?,
           "expected nullable handoff to validate through Tycho's schema path")
  end

  def assert_schema_migration_is_additive
    Dir.mktmpdir("tycho-memory-handoff-schema") do |dir|
      path = File.join(dir, "agent_result.json")
      File.write(path, JSON.generate("type" => "object", "properties" => { "status" => { "type" => "string" } }))
      HQ.migrate_agent_result_schema!(path)
      migrated = JSON.parse(File.read(path))
      assert(migrated.dig("properties", "status", "type") == "string", "expected existing schema fields to survive")
      assert(migrated.fetch("required").include?("memory_handoff"), "expected required root handoff migration")
      assert(migrated.fetch("required").include?("summary_sections"), "expected required root summary sections migration")
      assert(migrated.dig("properties", "summary_sections", "type") == %w[array null],
             "expected summary sections schema migration")
      assert(migrated.dig("properties", "summary_sections", "description").to_s
                     .include?("Set summary_sections to null for simple runs"),
             "expected schema migration to install the summary sections production guidance")
      assert(migrated.dig("properties", "memory_handoff", "required") ==
             %w[outcome decisions continuing_context references lessons promotion_candidates],
             "expected strict handoff schema migration")
    end
  end

  def assert(condition, message)
    raise message unless condition
  end
end

MemoryHandoffTest.run!
