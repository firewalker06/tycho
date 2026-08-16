# frozen_string_literal: true

require "json"
require "tmpdir"

require_relative "../lib/hq/domain/agent_event_journal"

module AgentEventJournalTest
  module_function

  def run!
    assert_monotonic_sequence_and_deduplication
    assert_concurrent_writers_share_one_sequence
    assert_legacy_replacement_assigns_sequences
    assert_append_migrates_legacy_prefix_before_new_event
    puts "agent_event_journal_test: ok"
  end

  def assert_append_migrates_legacy_prefix_before_new_event
    Dir.mktmpdir("tycho-event-journal-append-legacy") do |dir|
      path = File.join(dir, "memory.jsonl")
      File.write(path, JSON.generate("type" => "user_message", "content" => "legacy") + "\n")
      journal = HQ::AgentEventJournal.new(path)
      journal.append({ "type" => "assistant_message", "content" => "new" }, event_id: "new")

      events = journal.events
      assert(events.map { |event| event["sequence"] } == [1, 2], "expected migrated legacy prefix")
      assert(events.map { |event| event["content"] } == %w[legacy new], "expected legacy order before new event")
    end
  end

  def assert_monotonic_sequence_and_deduplication
    Dir.mktmpdir("tycho-event-journal") do |dir|
      journal = HQ::AgentEventJournal.new(File.join(dir, "memory.jsonl"))
      first = journal.append({ "type" => "assistant_message", "content" => "first" }, event_id: "first")
      second = journal.append({ "type" => "delegation_event", "content" => "second" }, event_id: "second")
      duplicate = journal.append({ "type" => "assistant_message", "content" => "changed" }, event_id: "first")

      assert(first["sequence"] == 1, "expected first sequence")
      assert(second["sequence"] == 2, "expected second sequence")
      assert(duplicate == first, "expected duplicate append to return existing event")
      assert(journal.events.map { |event| event["content"] } == %w[first second], "expected one durable copy")
    end
  end

  def assert_concurrent_writers_share_one_sequence
    Dir.mktmpdir("tycho-event-journal-concurrent") do |dir|
      path = File.join(dir, "memory.jsonl")
      pids = 4.times.map do |writer|
        fork do
          journal = HQ::AgentEventJournal.new(path)
          10.times do |index|
            journal.append(
              { "type" => "assistant_message", "content" => "#{writer}-#{index}" },
              event_id: "#{writer}-#{index}"
            )
          end
          exit! 0
        end
      end
      statuses = pids.map { |pid| Process.wait2(pid).last }
      assert(statuses.all?(&:success?), "expected every journal writer process to succeed")

      events = HQ::AgentEventJournal.new(path).events
      assert(events.length == 40, "expected every concurrent event")
      assert(events.map { |event| event["sequence"] } == (1..40).to_a, "expected gap-free durable order")
      File.foreach(path) { |line| JSON.parse(line) }
    end
  end

  def assert_legacy_replacement_assigns_sequences
    Dir.mktmpdir("tycho-event-journal-legacy") do |dir|
      journal = HQ::AgentEventJournal.new(File.join(dir, "memory.jsonl"))
      journal.replace([
                        { "type" => "user_message", "content" => "legacy one" },
                        { "type" => "assistant_message", "content" => "legacy two" }
                      ])

      events = journal.events
      assert(events.map { |event| event["sequence"] } == [1, 2], "expected legacy sequence assignment")
      assert(events.all? { |event| !event["event_id"].to_s.empty? }, "expected durable identities")
    end
  end

  def assert(condition, message)
    raise message unless condition
  end
end

AgentEventJournalTest.run! if $PROGRAM_NAME == __FILE__
