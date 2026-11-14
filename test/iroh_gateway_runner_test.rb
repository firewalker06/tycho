# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "json"

source = File.expand_path("../bin/test-iroh-gateway", __dir__)
Dir.mktmpdir("iroh-runner-regression-") do |dir|
  root = File.join(dir, "checkout")
  fake_bin = File.join(dir, "tools")
  FileUtils.mkdir_p([File.join(root, "bin"), fake_bin])
  root = File.realpath(root)
  FileUtils.cp(source, File.join(root, "bin/test-iroh-gateway"))
  log = File.join(dir, "calls.jsonl")
  cargo = <<~'RUBY'
    require "json"
    require "fileutils"
    target = ENV.fetch("CARGO_TARGET_DIR")
    File.open(ENV.fetch("RUNNER_CALLS"), "a") { |f| f.puts JSON.generate(tool: "cargo", args: ARGV, target: target) }
    exit 1 if ENV["FAIL_BUILD"] == "1" && ARGV.first == "build"
    binary = File.join(target, "debug/tycho-iroh-gateway")
    FileUtils.mkdir_p(File.dirname(binary))
    File.write(binary, "validated-source") unless File.exist?(binary)
  RUBY
  python = <<~'RUBY'
    require "json"
    require "fileutils"
    binary = ARGV.fetch(ARGV.index("--binary") + 1)
    output = ARGV.fetch(ARGV.index("--output") + 1)
    abort "wrong binary" unless File.read(binary) == "validated-source"
    FileUtils.mkdir_p(output)
    File.write(File.join(output, "result.json"), "fixture-evidence")
    File.open(ENV.fetch("RUNNER_CALLS"), "a") { |f| f.puts JSON.generate(tool: "proof", binary: binary, output: output) }
    exit 1 if ENV["FAIL_PROOF"] == "1"
  RUBY
  { "cargo" => cargo, "python3" => python }.each do |name, body|
    path = File.join(fake_bin, name)
    File.write(path, "#!#{RbConfig.ruby}\n#{body}")
    File.chmod(0o755, path)
  end
  env = { "PATH" => "#{fake_bin}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}",
          "RUNNER_CALLS" => log, "CARGO_TARGET_DIR" => nil, "TYCHO_REMOTE_UI_CAPTURE_DIR" => nil }
  run = lambda do |overrides = {}|
    Open3.capture3(env.merge(overrides), RbConfig.ruby, File.join(root, "bin/test-iroh-gateway"), chdir: root)
  end
  2.times do
    out, err, status = run.call
    abort "runner failed: #{out}#{err}" unless status.success?
  end
  calls = File.readlines(log).map { |line| JSON.parse(line) }
  expected = File.join(root, "ext/iroh_gateway/target")
  cargo_calls = calls.select { |call| call["tool"] == "cargo" }
  abort "default cache did not persist across runs" unless cargo_calls.map { |call| call["target"] }.uniq == [expected] && File.file?(File.join(expected, "debug/tycho-iroh-gateway"))
  abort "source validation skipped" unless cargo_calls.map { |call| call["args"].first } == %w[test build test build] && cargo_calls.all? { |call| call["args"].include?("--locked") && call["args"].include?("--manifest-path") }
  abort "temporary evidence survived" unless calls.select { |call| call["tool"] == "proof" }.all? { |call| !File.exist?(call["output"]) }

  retained = File.join(dir, "retained")
  _, _, status = run.call("CARGO_TARGET_DIR" => "custom cache", "TYCHO_REMOTE_UI_CAPTURE_DIR" => retained)
  abort "explicit target failed" unless status.success?
  calls = File.readlines(log).map { |line| JSON.parse(line) }
  custom = File.join(root, "custom cache/debug/tycho-iroh-gateway")
  abort "explicit relative target not respected" unless calls.last["binary"] == custom && File.file?(custom)
  abort "requested evidence was removed" unless File.file?(File.join(retained, "result.json"))

  absolute = File.join(dir, "absolute cache")
  _, _, status = run.call("CARGO_TARGET_DIR" => absolute, "FAIL_PROOF" => "1")
  abort "proof failure lost" if status.success?
  calls = File.readlines(log).map { |line| JSON.parse(line) }
  abort "absolute target not used" unless calls.last["binary"] == File.join(absolute, "debug/tycho-iroh-gateway")
  abort "failed proof evidence leaked" if File.exist?(calls.last["output"])
  abort "failed proof deleted build cache" unless File.file?(calls.last["binary"])

  _, _, status = Open3.capture3(env.merge("CARGO_TARGET_DIR" => "from-other-cwd", "TYCHO_REMOTE_UI_CAPTURE_DIR" => "saved-evidence"),
                               RbConfig.ruby, File.join(root, "bin/test-iroh-gateway"), chdir: dir)
  abort "other working directory failed" unless status.success?
  calls = File.readlines(log).map { |line| JSON.parse(line) }
  abort "relative paths depend on invocation directory" unless calls.last["binary"] == File.join(root, "from-other-cwd/debug/tycho-iroh-gateway") && calls.last["output"] == File.join(root, "saved-evidence")

  proof_count = calls.count { |call| call["tool"] == "proof" }
  _, _, status = run.call("FAIL_BUILD" => "1")
  abort "build failure ignored" if status.success?
  calls = File.readlines(log).map { |line| JSON.parse(line) }
  abort "stale binary used after build failure" unless calls.count { |call| call["tool"] == "proof" } == proof_count
end
puts "iroh_gateway_runner_test: ok"
