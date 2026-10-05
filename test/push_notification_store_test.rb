# frozen_string_literal: true

require "json"
require "tmpdir"

require_relative "../lib/hq/domain/push_notification_store"

module PushNotificationStoreTest
  module_function

  def run!
    assert_concurrent_duplicate_records_send_one_push
    assert_concurrent_distinct_records_remain_durable
    puts "push_notification_store_test: ok"
  end

  def assert_concurrent_duplicate_records_send_one_push
    with_store do |store, path|
      results = run_blocked_writers(path, ["same-failure", "same-failure"])
      delivered = results.select { |result| result.fetch("delivered") }

      assert(delivered.length == 1,
             "expected concurrent duplicate records to permit one push delivery")
      assert(store.all.map { |event| event.fetch("id") } == ["same-failure"],
             "expected one durable ledger record for the duplicate failure")
    end
  end

  def assert_concurrent_distinct_records_remain_durable
    with_store do |store, path|
      results = run_blocked_writers(path, ["failure-one", "failure-two"])

      assert(results.all? { |result| result.fetch("recorded") },
             "expected each distinct failure to permit its push delivery")
      assert(store.all.map { |event| event.fetch("id") }.sort == %w[failure-one failure-two],
             "expected concurrent distinct failures to remain in the durable ledger")
    end
  end

  def run_blocked_writers(path, ids)
    lock = File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600)
    lock.flock(File::LOCK_EX)
    readers = ids.map do |id|
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        recorded = HQ::PushNotificationStore.new(path:).record!(id, kind: "queue_process_failed")
        writer.write(JSON.generate("id" => id, "recorded" => recorded, "delivered" => recorded))
        writer.close
        exit! 0
      end
      writer.close
      [pid, reader]
    end

    ready = IO.select(readers.map(&:last), nil, nil, 0.2)
    assert(ready.nil?, "expected concurrent writers to wait at the ledger transaction boundary")
    lock.flock(File::LOCK_UN)
    lock.close

    readers.map do |pid, reader|
      result = JSON.parse(reader.read)
      reader.close
      status = Process.wait2(pid).last
      assert(status.success?, "expected concurrent notification writer to exit successfully")
      result
    end
  ensure
    lock&.flock(File::LOCK_UN) rescue nil
    lock&.close unless lock&.closed?
    Array(readers).each do |pid, reader|
      reader.close unless reader.closed?
      Process.wait(pid) if Process.waitpid(pid, Process::WNOHANG).nil?
    rescue Errno::ECHILD
      nil
    end
  end

  def with_store
    Dir.mktmpdir("push-notification-store-test") do |dir|
      path = File.join(dir, "push_notifications.json")
      yield HQ::PushNotificationStore.new(path:), path
    end
  end

  def assert(condition, message)
    raise message unless condition
  end
end

PushNotificationStoreTest.run!
