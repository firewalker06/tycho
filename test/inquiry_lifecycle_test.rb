# frozen_string_literal: true

require_relative "inquiry_receipt_test"

module InquiryLifecycleTest
  module_function

  def fixture
    RemoteServerTest.with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      RemoteServerTest.write_project_workspace(workspace)
      registry = RemoteServerTest.registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry:, web_push_notifier: RemoteServerTest::RecordingPushNotifier.new,
                                     agent_list_cache: HQ::AgentListCache.new(max_age: 60))
      key = service.create_agent("project_key" => "web", "prompt" => "Synthetic only").fetch(:key)
      id = InquiryReceiptTest.inquiry(service, key)
      yield service, service.instance_variable_get(:@agent_store), key, id
    end
  end

  def check(value, message)
    raise message unless value
  end

  def rejects(error, message)
    begin
      yield
    rescue error => e
      check(e.message.include?(message), "expected #{message.inspect}, got #{e.message.inspect}")
      return e
    end
    raise "expected #{error}: #{message}"
  end

  def run!
    fixture do |service, store, key, id|
      # A stale signature must stay on the read-only path.
      service.define_singleton_method(:load_all_agents) { raise "lifecycle action polled the fleet" }
      service.define_singleton_method(:conversation) { |*| raise "lifecycle action rebuilt conversation" }
      store.define_singleton_method(:load_with_poll_events_unlocked) { |**| raise "memory action polled the fleet" }
      stored = File.binread(HQ::AGENTS_FILE)
      2.times do
        service.send(:read_all_agents)
        # Atomic replacement invalidates even a warmed list cache.
        File.write("#{HQ::AGENTS_FILE}.next", stored)
        File.rename("#{HQ::AGENTS_FILE}.next", HQ::AGENTS_FILE)
        dismissed = service.dismiss_inquiry(key, id)
        check(!dismissed.key?(:conversation), "dismiss must omit unused conversation")
        check(dismissed.dig(:agent, :latest_inquiry).nil?, "dismiss projects current inquiry state")
        check(dismissed.dig(:agent, :suspended_inquiry, "id") == id, "dismiss projects restorable inquiry")
        File.write("#{HQ::AGENTS_FILE}.next", stored)
        File.rename("#{HQ::AGENTS_FILE}.next", HQ::AGENTS_FILE)
        restored = service.restore_inquiry(key, id)
        check(restored.dig(:agent, :latest_inquiry, "id") == id, "restore projects active inquiry")
        check(File.binread(HQ::AGENTS_FILE) == stored, "memory actions must not rewrite stored records")
      end
      service.instance_variable_set(:@agent_list_cache, HQ::AgentListCache.new(max_age: 60))
      service.dismiss_inquiry(key, id)
      service.restore_inquiry(key, id)
      %i[dismiss_inquiry restore_inquiry].each do |action|
        error = rejects(HQ::RemoteService::Error, "Unknown agent") { service.public_send(action, "missing", id) }
        check(error.status == 404, "unknown key must return 404")
      end
    end

    fixture do |_service, store, key, id|
      File.write("#{HQ::AGENTS_FILE}.bak", File.binread(HQ::AGENTS_FILE))
      memory_path = store.read_snapshot.first.fetch(0).memory_path
      memory = File.binread(memory_path)
      ["{corrupt", "{}", "[null]"].each do |invalid|
        File.write(HQ::AGENTS_FILE, invalid)
        %i[suspend_inquiry! restore_inquiry!].each do |action|
          rejects(IOError, "Invalid agent store") { store.public_send(action, key, id) }
        end
      end
      check(File.binread(memory_path) == memory, "invalid primary must not append memory from a backup")
    end

    fixture do |service, store, key, id|
      record = JSON.parse(File.read(HQ::AGENTS_FILE)).first
      memory_path = HQ::ManagedAgent.from_hash(record).memory_path
      store.archive_agent!(key)
      check(!File.exist?(memory_path), "archive moves live memory away")
      %i[dismiss_inquiry restore_inquiry].each do |action|
        error = rejects(HQ::RemoteService::Error, "Archived agent is read-only") { service.public_send(action, key, id) }
        check(error.status == 409, "preserve archived read-only conflict")
      end
      # Reappearing records in the primary file must also obey the retired ledger.
      File.write(HQ::AGENTS_FILE, JSON.generate([record]))
      %i[suspend_inquiry! restore_inquiry!].each do |action|
        rejects(ArgumentError, "Unknown agent") { store.public_send(action, key, id) }
      end
      check(!File.exist?(memory_path), "retired records must not recreate live memory")
      # A valid backup must not hide a corrupt primary.
      File.write("#{HQ::AGENTS_FILE}.bak", JSON.generate([record]))
      File.write(HQ::AGENTS_FILE, "{corrupt")
      %i[suspend_inquiry! restore_inquiry!].each do |action|
        rejects(IOError, "Invalid agent store") { store.public_send(action, key, id) }
      end
      check(!File.exist?(memory_path), "backup must not recreate retired live memory")
      FileUtils.rm_f(HQ::AGENTS_FILE)
      rejects(ArgumentError, "Unknown agent") { store.suspend_inquiry!(key, id) }
      check(!File.exist?(memory_path), "missing primary must not read backup")
    end
    puts "inquiry_lifecycle_test: ok"
  end
end

InquiryLifecycleTest.run! if $PROGRAM_NAME == __FILE__
