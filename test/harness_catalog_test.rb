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

  def replace_constant(parent, name, value)
    old = parent.const_get(name)
    parent.send(:remove_const, name)
    parent.const_set(name, value)
    old
  end
end

HarnessCatalogTest.run! if $PROGRAM_NAME == __FILE__
