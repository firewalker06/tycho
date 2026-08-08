# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "rubygems/package"
require "tmpdir"

module GemPackageTest
  ROOT = File.expand_path("..", __dir__)

  module_function

  def run!
    Dir.mktmpdir("tycho-gem-package-test") do |dir|
      gem_path = File.join(dir, "hq.gem")
      build_gem!(gem_path)
      unpacked = File.join(dir, "unpacked")
      FileUtils.mkdir_p(unpacked)
      Gem::Package.new(gem_path).extract_files(unpacked)
      verify_packaged_installer!(unpacked, File.join(dir, "home"))
    end
    puts "gem_package_test: ok"
  end

  def build_gem!(gem_path)
    stdout, stderr, status = Open3.capture3(
      "gem", "build", "hq.gemspec", "--output", gem_path,
      chdir: ROOT
    )
    return if status.success?

    raise "gem build failed:\n#{stdout}#{stderr}"
  end

  def verify_packaged_installer!(unpacked, home)
    script = <<~'RUBY'
      require "digest"
      require "json"
      require "hq/domain/skill_installer"

      manifest_path = HQ::SkillInstaller::DEFAULT_MANIFEST_PATH
      manifest = JSON.parse(File.binread(manifest_path))
      source_root = HQ::SkillInstaller::DEFAULT_SOURCE_ROOT
      manifest.fetch("skills").each do |skill|
        skill.fetch("files").each do |relative_path, expected|
          packaged_file = File.join(source_root, skill.fetch("name"), relative_path)
          actual = Digest::SHA256.file(packaged_file).hexdigest
          raise "packaged checksum mismatch for #{relative_path}" unless actual == expected
        end
      end

      installer = HQ::SkillInstaller.new(home: ENV.fetch("TYCHO_PACKAGE_TEST_HOME"))
      result = installer.apply(harness: "codex", action: "install")
      raise "packaged install changed the wrong skills" unless result.fetch(:changed_skills) == ["tycho"]
      raise "packaged install is not current" unless result.dig(:harness, :status) == "installed"
      expected_target = File.join(ENV.fetch("TYCHO_PACKAGE_TEST_HOME"), ".agents", "skills", "tycho")
      raise "packaged install used the wrong target" unless result.dig(:harness, :skills, 0, :path) == expected_target
    RUBY
    env = { "TYCHO_PACKAGE_TEST_HOME" => home }
    stdout, stderr, status = Open3.capture3(
      env,
      RbConfig.ruby, "-I", File.join(unpacked, "lib"), "-e", script,
      chdir: unpacked
    )
    return if status.success?

    raise "unpacked gem installer failed:\n#{stdout}#{stderr}"
  end
end

GemPackageTest.run!
