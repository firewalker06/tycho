# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"

require_relative "../lib/hq/version"

Dir.mktmpdir("tycho-startup-test-") do |dir|
  env = {
    "TYCHO_HOME" => dir,
    "TYCHO_LOGS_ROOT" => File.join(dir, "logs"),
    "TYCHO_PROCESS_NAME_BOOTSTRAPPED" => nil,
    "RUBYLIB" => nil
  }
  executable = File.expand_path("../bin/tycho", __dir__)
  stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, executable, "--version")
  raise "Fresh runtime startup failed: #{stderr}" unless status.success?
  raise "Unexpected version output: #{stdout.inspect}" unless stdout.strip == "Tycho #{HQ::VERSION}"

  if RUBY_PLATFORM.include?("darwin")
    runtime = File.join(dir, "logs", "runtime", "tycho")
    raise "Expected macOS startup to create the named runtime" unless File.executable?(runtime)
    raise "Named runtime must not hardlink the Ruby executable" if File.identical?(RbConfig.ruby, runtime)
  end
end

puts "startup_test: ok"
