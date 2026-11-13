# frozen_string_literal: true

require_relative "support/push_safety"
require_relative "../lib/hq/remote_server"
require "securerandom"

module ProjectCreationReceiptTest
  module_function

  def assert(value, message)
    raise message unless value
  end

  def with_fixture
    Dir.mktmpdir("tycho-project-receipt-") do |temporary|
      home = File.realpath(temporary)
      config = File.join(home, "hq.yml")
      prompts = File.join(home, "prompts.yml")
      File.write(config, "projects: []\n")
      File.write(prompts, "default: Inspect this workspace.\n")
      original_home = Dir.method(:home)
      original_starter = HQ::USER_WORKSPACES_DIR
      Dir.define_singleton_method(:home) { home }
      HQ.send(:remove_const, :USER_WORKSPACES_DIR)
      HQ.const_set(:USER_WORKSPACES_DIR, File.join(home, "tycho-projects"))
      factory = -> { HQ::Registry.new(path: config, system_prompts_path: prompts) }
      yield home, config, factory
    ensure
      Dir.define_singleton_method(:home, original_home) if original_home
      if original_starter
        HQ.send(:remove_const, :USER_WORKSPACES_DIR)
        HQ.const_set(:USER_WORKSPACES_DIR, original_starter)
      end
    end
  end

  def run!
    with_fixture do |home, config, factory|
      attrs = { "key" => "atlas", "name" => "Atlas", "creation_request_id" => SecureRandom.uuid }
      result = HQ::RemoteService.new(registry: factory.call).create_project(attrs)
      assert(result[:creation_request_id] == attrs["creation_request_id"], "confirmation must bind to the submitted ID")
      assert(result[:path] == File.join(home, "tycho-projects", "atlas"), "default destination must remain unchanged")
      original = HQ::DirectoryHandle.method(:mkdir_at)
      HQ::DirectoryHandle.define_singleton_method(:mkdir_at) { |*_args| raise "replay must not create folders" }
      begin
        replay = HQ::RemoteService.new(registry: factory.call).create_project(attrs)
        assert(replay[:creation_request_id] == result[:creation_request_id], "restart/lost-reply retry must recover the same receipt")
        begin
          HQ::RemoteService.new(registry: factory.call).create_project(attrs.merge("key" => "other"))
          raise "request ID must not accept changed details"
        rescue HQ::RemoteService::Error => e
          assert(e.status == 409 && e.details[:creation_rejected], "conflict must be a definite rejection")
        end
      ensure
        HQ::DirectoryHandle.define_singleton_method(:mkdir_at, original)
      end
      data = YAML.safe_load(File.read(config))
      assert(data["projects"].size == 1 && data["project_creation_receipts"].size == 1, "one atomic registration and receipt")
      assert(!File.exist?(File.join(home, "tycho-projects", "other")), "changed request must have no folder effect")
      registry = factory.call
      registry.archive_project!("atlas")
      begin
        HQ::RemoteService.new(registry: factory.call).create_project(attrs)
        raise "archived receipt must not recreate a project"
      rescue HQ::RemoteService::Error => e
        assert(e.status == 409, "archived result must fail clearly")
      end
      assert(YAML.safe_load(File.read(config))["projects"].empty?, "archived result must stay archived")
    end

    with_fixture do |_home, config, factory|
      attrs = { "key" => "concurrent", "name" => "Concurrent", "creation_request_id" => SecureRandom.uuid }
      services = 2.times.map { HQ::RemoteService.new(registry: factory.call) }
      threads = services.map { |service| Thread.new { service.create_project(attrs) } }
      results = threads.map(&:value)
      assert(results.all? { |result| result[:key] == "concurrent" }, "concurrent replay must confirm the same project")
      assert(YAML.safe_load(File.read(config))["projects"].size == 1, "concurrent registration must occur once")
    end

    with_fixture do |_home, config, factory|
      registry = factory.call
      attrs = { "key" => "lost", "name" => "Lost reply", "creation_request_id" => SecureRandom.uuid }
      registry.define_singleton_method(:load!) { raise HQ::ConfigError, "synthetic post-commit failure" }
      begin
        HQ::RemoteService.new(registry: registry).create_project(attrs)
        raise "post-commit failure cannot claim rejection or success"
      rescue HQ::RemoteService::Error => e
        assert(e.status == 503 && !e.details, "post-commit failure must remain uncertain")
      end
      assert(YAML.safe_load(File.read(config))["projects"].size == 1, "fixture must actually commit before losing confirmation")
      recovered = HQ::RemoteService.new(registry: factory.call).create_project(attrs)
      assert(recovered[:creation_request_id] == attrs["creation_request_id"], "retry must recover committed receipt")
      assert(YAML.safe_load(File.read(config))["projects"].size == 1, "recovery must not create again")
    end
    puts "project_creation_receipt_test: ok"
  end
end

ProjectCreationReceiptTest.run!
