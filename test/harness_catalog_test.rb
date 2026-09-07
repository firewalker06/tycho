# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require_relative "../lib/hq/domain/harness_catalog"

module HarnessCatalogTest
  module_function

  def run!
    assert_codex_catalog_probe_times_out_hung_cli
    assert_timeout_handles_term_exit_without_double_wait
    assert_opencode_auth_table_strips_status_glyphs
    assert_pi_models_drive_catalog_and_auth_readiness
    assert_pi_empty_model_catalog_reports_auth_not_ready
    assert_custom_profiles_probe_native_catalogs_with_prefix_and_environment
    puts "harness_catalog_test: ok"
  end

  def assert_timeout_handles_term_exit_without_double_wait
    Dir.mktmpdir("hq-harness-catalog-test") do |dir|
      executable = File.join(dir, "term-aware-probe")
      File.write(executable, <<~SH)
        #!/bin/sh
        trap 'exit 0' TERM
        sleep 30
      SH
      FileUtils.chmod(0o755, executable)

      started = Time.now
      _out, _err, success = HQ::HarnessCatalog.send(
        :capture_command_output,
        [executable],
        timeout: 0.2
      )
      elapsed = Time.now - started

      assert(elapsed < 2.0, "expected TERM-aware probe to stop promptly, took #{elapsed.round(2)}s")
      assert(!success, "expected a timed-out probe not to count a successful TERM handler exit")
    end
  end

  def assert_codex_catalog_probe_times_out_hung_cli
    Dir.mktmpdir("hq-harness-catalog-test") do |dir|
      executable = File.join(dir, "hung-codex")
      File.write(executable, <<~SH)
        #!/bin/sh
        trap '' TERM
        sleep 30
      SH
      FileUtils.chmod(0o755, executable)

      previous_timeout = replace_constant(HQ::HarnessCatalog, :COMMAND_TIMEOUT, 0.2)
      started = Time.now
      catalog = HQ::HarnessCatalog.codex_catalog(
        Struct.new(:command, keyword_init: true) do
          def available?
            true
          end
        end.new(command: executable)
      )
      elapsed = Time.now - started

      assert(elapsed < 2.0, "expected hung Codex catalog probe to time out, took #{elapsed.round(2)}s")
      assert(catalog[:catalog_source] == "codex debug models unavailable",
             "expected unavailable catalog source for hung Codex CLI")
    ensure
      replace_constant(HQ::HarnessCatalog, :COMMAND_TIMEOUT, previous_timeout) if previous_timeout
    end
  end

  def assert(condition, message)
    raise message unless condition
  end

  def assert_opencode_auth_table_strips_status_glyphs
    Dir.mktmpdir("hq-harness-catalog-test") do |dir|
      executable = File.join(dir, "opencode")
      File.write(executable, <<~SH)
        #!/bin/sh
        if [ "$1" = "auth" ] && [ "$2" = "list" ]; then
          printf '\\033[0m\\n'
          printf '┌  Credentials ~/.local/share/opencode/auth.json\\n'
          printf '│\\n'
          printf '●  Anthropic api\\n'
          printf '●  Google oauth\\n'
          printf '└  2 credentials\\n'
          exit 0
        fi
        exit 0
      SH
      FileUtils.chmod(0o755, executable)

      providers = HQ::HarnessCatalog.opencode_auth_providers(executable)
      assert(providers == %w[anthropic google],
             "expected OpenCode auth providers without table glyphs, got #{providers.inspect}")
    end
  end
  def assert_pi_models_drive_catalog_and_auth_readiness
    Dir.mktmpdir("hq-harness-catalog-test") do |dir|
      executable = File.join(dir, "pi")
      File.write(executable, <<~SH)
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf '0.73.1\n'
        elif [ "$1" = "--list-models" ]; then
          printf 'provider      model       context  max-out  thinking  images\n'
          printf 'openai-codex  gpt-5.4     272K     128K     yes       yes\n'
          printf 'anthropic     sonnet-4.5  200K     64K      yes       yes\n'
        fi
      SH
      FileUtils.chmod(0o755, executable)
      resolution = Struct.new(:command) { def available? = true }.new(executable)

      catalog = HQ::HarnessCatalog.pi_catalog(resolution)
      assert(catalog[:model_suggestions].map { |item| item[:value] } ==
             %w[openai-codex/gpt-5.4 anthropic/sonnet-4.5],
             "expected Pi provider-qualified model values")
      assert(catalog[:auth_ready] && catalog[:auth_providers] == %w[openai-codex anthropic],
             "expected Pi model availability to report authentication readiness")
      assert(catalog[:version] == "0.73.1", "expected Pi version readiness")
      assert(catalog[:safety_gaps].any? { |gap| gap.include?("no sandbox equivalent") },
             "expected explicit Pi safety gap")
    end
  end

  def assert_custom_profiles_probe_native_catalogs_with_prefix_and_environment
    Dir.mktmpdir("hq-custom-harness-catalog-test") do |dir|
      executable = File.join(dir, "profile-wrapper")
      File.write(executable, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        abort "missing profile environment" unless ENV["TYCHO_PROFILE_ENV"] == "enabled"
        abort "server token leaked" unless ENV["TYCHO_REMOTE_TOKEN"].to_s.empty?
        abort "missing command prefix" unless ARGV.shift == "--profile" && ARGV.shift == "fixture"
        case ARGV
        when ["debug", "models"]
          puts JSON.generate("models" => [{ "slug" => "custom-codex", "display_name" => "Custom Codex", "supported_reasoning_levels" => [{ "effort" => "high" }] }])
        when ["models"]
          puts "custom/provider-model"
        when ["auth", "list"]
          puts "●  Custom auth"
        when ["--list-models"]
          puts "custom provider-model"
        when ["--version"]
          puts "profile-wrapper 1.0"
        else
          exit 1
        end
      RUBY
      FileUtils.chmod(0o755, executable)
      profiles = {
        "codex" => HQ::HarnessConfig.new(
          key: "codex-profile", adapter: "codex",
          execution_command: ["env", "TYCHO_PROFILE_ENV=enabled", "TYCHO_REMOTE_TOKEN=profile-secret", executable, "--profile", "fixture"]
        ),
        "opencode" => HQ::HarnessConfig.new(
          key: "opencode-profile", adapter: "opencode",
          execution_command: ["env", "TYCHO_PROFILE_ENV=enabled", "TYCHO_REMOTE_TOKEN=profile-secret", executable, "--profile", "fixture"]
        ),
        "pi" => HQ::HarnessConfig.new(
          key: "pi-profile", adapter: "pi",
          execution_command: ["env", "TYCHO_PROFILE_ENV=enabled", "TYCHO_REMOTE_TOKEN=profile-secret", executable, "--profile", "fixture"]
        ),
        "claude" => HQ::HarnessConfig.new(
          key: "claude-profile", adapter: "claude", execution_command: executable
        )
      }
      previous_token = ENV["TYCHO_REMOTE_TOKEN"]
      ENV["TYCHO_REMOTE_TOKEN"] = "must-not-reach-profile-probe"
      HQ::HarnessCatalog.clear_cache!

      codex = HQ::HarnessCatalog.for_custom(profiles.fetch("codex"))
      opencode = HQ::HarnessCatalog.for_custom(profiles.fetch("opencode"))
      pi = HQ::HarnessCatalog.for_custom(profiles.fetch("pi"))
      claude = HQ::HarnessCatalog.for_custom(profiles.fetch("claude"))

      assert(codex[:model_suggestions].map { |item| item[:value] } == ["custom-codex"],
             "expected custom Codex profile catalog to retain prefix and env")
      assert(opencode[:model_suggestions].map { |item| item[:value] } == ["custom/provider-model"] &&
             opencode[:auth_providers] == ["custom"],
             "expected custom OpenCode profile catalog to retain prefix and env")
      assert(pi[:model_suggestions].map { |item| item[:value] } == ["custom/provider-model"] &&
             pi[:auth_ready] && pi[:version] == "profile-wrapper 1.0",
             "expected custom Pi profile catalog to retain prefix and env")
      assert(claude[:catalog_source] == "claude-compatible defaults",
             "expected existing Claude-compatible profile catalog behavior to stay stable")
    ensure
      previous_token ? ENV["TYCHO_REMOTE_TOKEN"] = previous_token : ENV.delete("TYCHO_REMOTE_TOKEN")
      HQ::HarnessCatalog.clear_cache!
    end
  end

  def assert_pi_empty_model_catalog_reports_auth_not_ready
    Dir.mktmpdir("hq-harness-catalog-test") do |dir|
      executable = File.join(dir, "pi")
      File.write(executable, <<~SH)
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf '0.73.1\n'
        elif [ "$1" = "--list-models" ]; then
          printf 'No models available. Authenticate a provider first.\n'
        fi
      SH
      FileUtils.chmod(0o755, executable)
      resolution = Struct.new(:command) { def available? = true }.new(executable)

      catalog = HQ::HarnessCatalog.pi_catalog(resolution)
      assert(catalog[:model_suggestions].empty?, "expected an empty Pi model catalog")
      assert(!catalog[:auth_ready], "expected an empty Pi model catalog to report authentication not ready")
      assert(catalog[:catalog_source].include?("unauthenticated"),
             "expected unauthenticated Pi catalog source")
    end
  end

  def replace_constant(parent, name, value)
    old = parent.const_get(name)
    parent.send(:remove_const, name)
    parent.const_set(name, value)
    old
  end
end

HarnessCatalogTest.run! if $PROGRAM_NAME == __FILE__
