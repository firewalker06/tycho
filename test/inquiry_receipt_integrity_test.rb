# frozen_string_literal: true

require_relative "inquiry_receipt_recovery_test"

module InquiryReceiptIntegrityTest
  module_function

  def check(value, message)
    InquiryReceiptTest.check(value, message)
  end

  def run!
    InquiryReceiptRecoveryTest.fixture do |service, key, id, attrs|
      attrs["start"] = false
      attrs["attachments"] = [{ "filename" => "synthetic.txt", "mime_type" => "text/plain", "content_base64" => Base64.strict_encode64("Synthetic only") }]
      attrs["feedback"] = "Synthetic feedback"
      store = service.instance_variable_get(:@agent_store)
      service.submit_prompt(key, "prompt" => "First queued instruction", "delay" => 0, "client_request_id" => "client-queue-first", "start" => false)
      service.submit_prompt(key, "prompt" => "Second queued instruction", "delay" => 0, "client_request_id" => "client-queue-second", "start" => false)
      original = store.method(:save_unlocked)
      fail_once = true
      store.define_singleton_method(:save_unlocked) do |*args, **kwargs|
        original.call(*args, **kwargs)
        if fail_once
          fail_once = false
          raise IOError, "Synthetic after answer persistence"
        end
      end
      begin
        service.answer_inquiry(key, id, attrs)
        raise "missing injected persistence failure"
      rescue IOError
        nil
      end
      target = service.send(:find_agent!, key)
      check(target.latest_inquiry_id == id && target.inquiry_receipts.empty?, "failed acceptance transaction restores inquiry and receipt")
      check(HQ::AgentMemory.new(target).events.none? { |e| e["type"] == "inquiry_response" }, "failed acceptance leaves no duplicate answer")
      result = service.answer_inquiry(key, id, attrs)
      target = service.send(:find_agent!, key)
      check(result.dig(:answer_receipt, :accepted), "retry after rolled back acceptance works")
      batch = target.active_queue_work
      check(batch["entries"].map { |entry| entry["id"] } == %w[client-queue-first client-queue-second], "answer includes FIFO queue work")
      events = HQ::AgentMemory.new(target).events
      check(events.count { |e| e["type"] == "inquiry_response" } == 1, "one durable answer")
      check(events.count { |e| e["type"] == "user_message" && e.dig("metadata", "inquiry_feedback") } == 1, "one normalized feedback message")
      attachment_count = target.attachments.length
      2.times { service.answer_inquiry(key, id, attrs) }
      check(service.send(:find_agent!, key).attachments.length == attachment_count, "attachment import not repeated")

      # Bounded records cannot evict an unexpired result to make room for a new write.
      records = target.inquiry_receipts
      original_record = records.fetch(attrs["client_request_id"])
      (HQ::AgentStore::INQUIRY_RECEIPT_LIMIT - 1).times { |i| records["fixture-#{i}"] = original_record.dup }
      service.send(:save_agent, target)
      newer = InquiryReceiptTest.inquiry(service, key, "Capacity question")
      next_attrs = attrs.merge("client_request_id" => "client-capacity-new")
      InquiryReceiptTest.conflict(service, key, newer, next_attrs, 409)
      check(service.answer_inquiry(key, id, attrs).dig(:answer_receipt, :accepted), "capacity preserves original result")
      target = service.send(:find_agent!, key)
      target.inquiry_receipts.each_value { |record| record["created_at"] = (Time.now - HQ::AgentStore::INQUIRY_RECEIPT_TTL - 1).utc.iso8601(6) }
      service.send(:save_agent, target)
      check(service.answer_inquiry(key, newer, next_attrs).dig(:answer_receipt, :accepted), "expired records pruned for new intent")
      check(service.send(:find_agent!, key).inquiry_receipts.size == 1, "receipt index bounded")
    end

    # User acceptance changes ownership once. Replaying after parent reclaim never takes it again.
    InquiryReceiptRecoveryTest.fixture do |service, key, id, attrs|
      parent = service.create_agent("project_key" => "web", "prompt" => "Synthetic parent")
      store = service.instance_variable_get(:@agent_store)
      store.delegation_coordinator.delegation_store.attach!(parent: service.send(:find_agent!, parent[:key]), child: service.send(:find_agent!, key))
      attrs["start"] = false
      first = service.answer_inquiry(key, id, attrs)
      stamp = store.delegation_coordinator.ownership_stamp(key)
      check(first.dig(:answer_receipt, :authority) == stamp && stamp["owner"] == "user", "answer has original user ownership")
      service.submit_prompt(key, {"prompt" => "Parent reclaim", "start" => false}, actor: HQ::DelegationActor.parent_actor(parent[:key]))
      reclaimed = store.delegation_coordinator.ownership_stamp(key)
      replay = service.answer_inquiry(key, id, attrs)
      check(replay.dig(:answer_receipt, :authority) == stamp, "replay keeps original authority")
      check(store.delegation_coordinator.ownership_stamp(key) == reclaimed && reclaimed["owner"] == "parent", "replay does not take over parent")
    end
    puts "inquiry_receipt_integrity_test: ok"
  end
end

InquiryReceiptIntegrityTest.run! if $PROGRAM_NAME == __FILE__
