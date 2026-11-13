# frozen_string_literal: true

require "tmpdir"
require "open3"
require "rbconfig"
require "json"
require "digest"

Dir.mktmpdir("tycho-migration-cleanup-cli-") do |dir|
  path = File.join(dir, "queues.json")
  state = { "version" => 1, "agents" => {}, "migrations" => {} }
  102.times do |index|
    key = format("synthetic-%03d", index)
    state["agents"][key] = { "generation" => "stable" }
    state["migrations"][key] = {
      "queue_sha256" => Digest::SHA256.hexdigest("{}"),
      "entry_ids" => [], "claim_id" => nil, "batch_ids" => []
    }
  end
  File.write(path, JSON.generate(state))
  env = { "TYCHO_LOGS_ROOT" => dir, "TYCHO_HOME" => dir,
          "TYCHO_CONFIG_PATH" => File.join(dir, "hq.yml"),
          "TYCHO_SYSTEM_PROMPTS_PATH" => File.join(dir, "prompts.yml") }
  command = [RbConfig.ruby, File.expand_path("../bin/tycho", __dir__), "queue-work", "cleanup-migrations"]
  stdout, stderr, status = Open3.capture3(env, *command)
  raise "CLI dry run failed: #{stderr}" unless status.success?
  report = JSON.parse(stdout)
  raise "CLI default was not dry run" unless report["mode"] == "dry_run" && report["candidates"].size == 2
  raise "CLI dry run changed queues" unless JSON.parse(File.read(path)) == state
  _stdout, _stderr, status = Open3.capture3(env, *command, "unexpected", "--apply")
  raise "CLI accepted extra cleanup arguments" if status.success?
  raise "CLI unexpected arguments changed queues" unless JSON.parse(File.read(path)) == state
  stdout, stderr, status = Open3.capture3(env, *command, "--apply")
  raise "CLI apply failed: #{stderr}" unless status.success?
  raise "CLI apply omitted result" unless JSON.parse(stdout)["removed"] == report["candidates"]
  after = JSON.parse(File.read(path))
  raise "CLI apply changed authority" unless after["agents"] == state["agents"] && after["migrations"].size == 100
  File.write(path, "invalid")
  _stdout, _stderr, status = Open3.capture3(env, *command, "--apply")
  raise "CLI corrupt state returned success" if status.success?
  raise "CLI corrupt state was repaired" unless File.read(path) == "invalid"
end

puts "queue_migration_cleanup_cli_test passed"
