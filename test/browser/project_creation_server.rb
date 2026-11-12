# frozen_string_literal: true

# Test-only server home. Never load this fixture from a production entry point.
require_relative "../support/test_environment"
TestEnvironment.clear_inherited_run_variables!
ENV["TYCHO_PROCESS_NAME_BOOTSTRAPPED"] = "1"
fixture_home = File.realpath(ENV.fetch("TYCHO_PROJECT_TEST_HOME"))
Dir.define_singleton_method(:home) { fixture_home }
load File.expand_path("../../bin/tycho", __dir__)
