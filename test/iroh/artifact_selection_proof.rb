# frozen_string_literal: true

# Offline Cargo reproduction with an intentionally stale default-path binary.
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "rbconfig"

output = ARGV.fetch(0)
runner = File.expand_path("../../bin/test-iroh-gateway", __dir__)
host = Open3.capture2("rustc", "-vV").first.lines.find { |line| line.start_with?("host: ") }.split.last
result = { host: host, cases: [] }
Dir.mktmpdir("iroh-current-artifact-") do |root|
  root = File.realpath(root)
  FileUtils.mkdir_p([File.join(root, "bin"), File.join(root, "test/iroh"), File.join(root, "ext/iroh_gateway/src"), File.join(root, ".cargo")])
  FileUtils.cp(runner, File.join(root, "bin/test-iroh-gateway"))
  manifest = File.join(root, "ext/iroh_gateway/Cargo.toml")
  source = File.join(root, "ext/iroh_gateway/src/main.rs")
  target = File.join(root, "persistent cache")
  File.write(manifest, "[package]\nname = \"tycho-iroh-gateway\"\nversion = \"0.0.0\"\nedition = \"2021\"\n")
  File.write(source, "fn main() { println!(\"prior-source\"); }\n")
  env = { "CARGO_TARGET_DIR" => target, "CARGO_BUILD_TARGET" => nil, "CARGO_NET_OFFLINE" => "true", "TYCHO_REMOTE_UI_CAPTURE_DIR" => nil }
  abort "fixture lock failed" unless system(env, "cargo", "generate-lockfile", "--offline", "--manifest-path", manifest, chdir: root)
  abort "fixture initial build failed" unless system(env, "cargo", "build", "--locked", "--manifest-path", manifest, chdir: root)
  old = File.join(target, "debug/tycho-iroh-gateway")
  abort "fixture prior binary wrong" unless Open3.capture2([old, old]).first.strip == "prior-source"
  File.write(source, "fn main() { println!(\"current-source\"); }\n")
  File.write(File.join(root, "test/iroh/gateway_proof.py"), <<~'PYTHON')
    import argparse, subprocess, pathlib, json
    p = argparse.ArgumentParser(); p.add_argument('--binary'); p.add_argument('--output'); args = p.parse_args()
    value = subprocess.check_output([args.binary], text=True).strip()
    assert value == 'current-source', 'stale default binary executed'
    out = pathlib.Path(args.output); out.mkdir(parents=True, exist_ok=True)
    (out/'selected.json').write_text(json.dumps({'binary':args.binary,'value':value}))
  PYTHON
  %w[environment config].each do |kind|
    capture = File.join(root, "evidence-#{kind}")
    selected_env = env.merge("TYCHO_REMOTE_UI_CAPTURE_DIR" => capture)
    if kind == "environment"
      selected_env["CARGO_BUILD_TARGET"] = host
    else
      File.write(File.join(root, ".cargo/config.toml"), "[build]\ntarget = #{host.inspect}\n")
    end
    stdout, stderr, status = Open3.capture3(selected_env, RbConfig.ruby, File.join(root, "bin/test-iroh-gateway"), chdir: root)
    abort "#{kind} proof failed:\n#{stdout}#{stderr}" unless status.success?
    selected = JSON.parse(File.read(File.join(capture, "selected.json")))
    expected = File.join(target, host, "debug/tycho-iroh-gateway")
    abort "wrong current artifact" unless selected["binary"] == expected && selected["value"] == "current-source"
    abort "old default binary was overwritten" unless Open3.capture2([old, old]).first.strip == "prior-source"
    result[:cases] << { selection: kind, current_source_executed: true, selected_target_subdirectory: true, stale_default_still_present: true }
  end
end
File.write(output, JSON.pretty_generate(result) + "\n")
puts "Actual Cargo env/config artifact selection: ok"
