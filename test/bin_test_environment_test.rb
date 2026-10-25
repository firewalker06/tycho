# frozen_string_literal: true

require "json"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "support/test_environment"

ROOT = File.expand_path("..", __dir__)
PROBE = 'puts JSON.generate(ENV.to_h.select { |name, _| name.start_with?("TYCHO_") })'

# Simulates the environment a managed agent gives to a command it runs.
def inherited_environment(extra = {})
  TestEnvironment::INHERITED_RUN_VARIABLES.to_h { |name| [name, "/inherited/#{name}"] }
                                          .merge("TYCHO_CONFIG_PATH" => "/inherited/hq.yml")
                                          .merge(extra)
end

def probe(env, *ruby_args)
  out, status = Open3.capture2(env, RbConfig.ruby, *ruby_args, "-rjson", "-e", PROBE, chdir: ROOT)
  raise "probe failed: #{status.inspect}" unless status.success?

  JSON.parse(out)
end

# 1. The environment bin/test gives each command drops every inherited variable.
Dir.mktmpdir("tycho-bin-test-env-") do |home|
  seen = probe(inherited_environment.merge(TestEnvironment.command_env(home)))
  leaked = seen.keys & (TestEnvironment::INHERITED_RUN_VARIABLES + TestEnvironment::CONFIG_OVERRIDES)
  raise "bin/test leaked #{leaked.sort.join(", ")}" unless leaked.empty?
  raise "missing logs root" unless seen["TYCHO_LOGS_ROOT"] == File.join(home, "logs")
  raise "missing home" unless seen["TYCHO_HOME"] == home
end

# 2. Standalone runs that preload the shared support also drop them.
seen = probe(inherited_environment, "-r", File.join(ROOT, "test/support/push_safety.rb"))
leaked = seen.keys & TestEnvironment::INHERITED_RUN_VARIABLES
raise "push_safety leaked #{leaked.sort.join(", ")}" unless leaked.empty?

# 3. Variables a test sets for itself after the helper loads are kept.
code = 'ENV["TYCHO_AGENT_KEY"] = "intentional"; ' + PROBE
out, status = Open3.capture2(inherited_environment, RbConfig.ruby, "-rjson", "-r",
                             File.join(ROOT, "test/support/push_safety.rb"), "-e", code, chdir: ROOT)
raise "probe failed" unless status.success?
raise "intentional variable was cleared" unless JSON.parse(out)["TYCHO_AGENT_KEY"] == "intentional"

# 4. bin/test uses the shared environment, and every spawn-time variable is listed.
raise "bin/test does not use TestEnvironment.command_env" unless
  File.read(File.join(ROOT, "bin/test")).include?("TestEnvironment.command_env")
spawned = File.read(File.join(ROOT, "lib/hq/domain/managed_agent.rb"))
                .scan(/"(TYCHO_[A-Z_]+)" => (?:status_path|pid_path|@key|File\.join|File\.expand_path|@log_path|memory_path|harness_adapter|run\.run_id|sleep_incident_file_path|native_\w+|Process\.pid)/)
                .flatten
missing = spawned - TestEnvironment::INHERITED_RUN_VARIABLES
raise "managed_agent.rb sets unlisted variables: #{missing.join(", ")}" unless missing.empty?
raise "spawn-variable scan found nothing" if spawned.empty?

# 5. Test scripts cannot use broad process-name matching. Exercise the scanner
# with a synthetic script. Do not execute the fixture command.
Dir.mktmpdir("tycho-process-kill-guard-") do |root|
  FileUtils.mkdir_p(File.join(root, "bin"))
  fixture = File.join(root, "bin", "unsafe-smoke")
  File.write(fixture, "#{["pk", "ill"].join} -f 'bin/test'\n")
  unsafe = TestEnvironment.broad_process_killer_files(root)
  raise "process-kill guard missed synthetic broad killer" unless unsafe == [fixture]
end

unsafe = TestEnvironment.broad_process_killer_files(ROOT)
raise "broad process-name killer found in #{unsafe.join(", ")}" unless unsafe.empty?

rules = File.read(File.join(ROOT, "AGENTS.md"))
policy = ["pk", "ill"].join + " -f"
raise "AGENTS.md lost the process-cleanup safety rule" unless rules.include?(policy)

puts "bin_test_environment_test: ok"
