# frozen_string_literal: true

require_relative "../lib/hq/domain/queue_work"

module QueueWorkTest
  module_function

  def run!
    assert_projection_preserves_fifo_and_prioritizes_instructions
    assert_disposition_validation_and_idempotency
    assert_legacy_claim_migration
    puts "queue_work_test: ok"
  end

  def assert_projection_preserves_fifo_and_prioritizes_instructions
    entries = [
      entry("report-1", "structured report one", "delegation_callback"),
      entry("user-1", "do the user instruction", "user", attachments: [{ "type" => "link", "url" => "https://example.test", "title" => "Spec" }]),
      entry("report-2", "structured report two", "delegation_callback")
    ]
    batch = HQ::QueueWork.build_batch(entries, id: "batch-1", opened_at: Time.utc(2026, 9, 19))
    projection = HQ::QueueWork.projection(batch)
    contract = HQ::QueueWork.contract(batch, agent_key: "agent-1")

    assert(batch["entries"].map { |item| item["id"] } == %w[report-1 user-1 report-2],
           "canonical entries must remain FIFO")
    assert(projection["required_actions"].map { |item| item["id"] } == ["user-1"] &&
           projection["contextual_reports"].map { |item| item["id"] } == %w[report-1 report-2],
           "required actions must project user instructions before contextual reports")
    assert(contract.index("do the user instruction") < contract.index("structured report one") &&
           contract.include?('"entry_ids":["report-1","user-1","report-2"]') &&
           contract.include?("Tycho blocks successful finalization"),
           "native work contracts must lead with counts, stable IDs, and the completion gate")
    assert(projection.dig("required_actions", 0, "attachments") == entries[1]["attachments"],
           "required-action projection must preserve attachments")
  end

  def assert_disposition_validation_and_idempotency
    batch = HQ::QueueWork.build_batch([
      entry("user-1", "instruction", "user"),
      entry("report-1", "report", "delegation_callback")
    ], id: "batch-2")

    incomplete = HQ::QueueWork.apply_dispositions!(batch, [
      { "entry_id" => "user-1", "outcome" => "completed" },
      { "entry_id" => "unknown", "outcome" => "completed" }
    ])
    assert(!incomplete["accepted"] && incomplete["unresolved_entry_ids"] == ["report-1"] &&
           batch.dig("dispositions", "user-1", "outcome") == "completed",
           "valid progress must persist while unknown entries leave the batch open")

    invalid = HQ::QueueWork.apply_dispositions!(batch, [
      { "entry_id" => "report-1", "outcome" => "superseded_with_reason" },
      { "entry_id" => "report-1", "outcome" => "incorporated" }
    ])
    assert(!invalid["accepted"] && invalid["errors"].any? { |error| error["code"] == "duplicate_entry" } &&
           invalid["unresolved_entry_ids"] == ["report-1"],
           "duplicates and missing reasons must not resolve work")

    complete = HQ::QueueWork.apply_dispositions!(batch, [
      { "entry_id" => "user-1", "outcome" => "completed" },
      { "entry_id" => "report-1", "outcome" => "incorporated" }
    ])
    identical = HQ::QueueWork.apply_dispositions!(batch, [
      { "entry_id" => "user-1", "outcome" => "completed" },
      { "entry_id" => "report-1", "outcome" => "incorporated" }
    ])
    assert(complete["accepted"] && identical["accepted"] && batch["state"] == "resolved" &&
           complete["batch"]["dispositions"] == identical["batch"]["dispositions"],
           "complete identical dispositions must be idempotent")

    blocked = HQ::QueueWork.build_batch([entry("user-2", "ask", "user")], id: "batch-3")
    result = HQ::QueueWork.apply_dispositions!(blocked, [{ "entry_id" => "user-2", "outcome" => "needs_input" }])
    assert(result["accepted"] && blocked["state"] == "blocked",
           "needs-input outcomes must remain operator-visible")
  end

  def assert_legacy_claim_migration
    legacy = {
      "id" => "legacy-claim",
      "entries" => [entry("legacy-entry", "legacy work", "user")],
      "claimed_at" => "2026-09-19T00:00:00Z",
      "message_appended" => true
    }
    store = HQ::QueueWork.normalize(nil, legacy_claim: legacy)
    batch = HQ::QueueWork.active(store)
    assert(batch && batch["id"] == "legacy-claim" && batch["state"] == "in_progress" &&
           batch["legacy_prompt_queue_claim"] == true,
           "legacy durable claims must migrate to open queue work")
  end

  def entry(id, prompt, source, attachments: [])
    {
      "id" => id,
      "prompt" => prompt,
      "source" => source,
      "attachments" => attachments,
      "accepted_at" => "2026-09-19T00:00:00Z",
      "authority" => { "relationship_id" => "relation-1", "owner" => "user", "generation" => 2 }
    }
  end

  def assert(condition, message)
    raise message unless condition
  end
end

QueueWorkTest.run! if $PROGRAM_NAME == __FILE__
