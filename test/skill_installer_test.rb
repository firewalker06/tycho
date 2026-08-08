# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

require_relative "../lib/hq/domain/skill_installer"

module SkillInstallerTest
  module_function

  def run!
    assert_bundled_source_manifest_is_valid
    assert_supported_harness_paths_and_idempotent_install
    assert_outdated_skill_updates_without_removing_extra_files
    assert_unowned_and_locally_modified_skills_are_preserved
    assert_permission_and_partial_failures_are_actionable
    puts "skill_installer_test: ok"
  end

  def assert_bundled_source_manifest_is_valid
    Dir.mktmpdir("tycho-bundled-skill-test") do |home|
      statuses = HQ::SkillInstaller.new(home: home).statuses
      assert(statuses.all? { |item| item[:status] == "missing" }, "expected valid bundled skill source")
      assert(statuses.all? { |item| item[:source].include?("lib/hq/skill_assets") },
             "expected packaged non-dotfile skill source")
    end
  end

  def assert_supported_harness_paths_and_idempotent_install
    with_installer do |installer, home, _source, _manifest|
      expected = {
        "codex" => File.join(home, ".agents", "skills"),
        "claude" => File.join(home, ".claude", "skills"),
        "opencode" => File.join(home, ".config", "opencode", "skills")
      }
      statuses = installer.statuses
      assert(statuses.map { |item| item[:harness] } == %w[codex claude opencode], "expected supported harness order")
      statuses.each do |item|
        assert(item[:status] == "missing", "expected #{item[:harness]} to start missing")
        assert(item[:target_path] == expected.fetch(item[:harness]), "expected official #{item[:harness]} skill path")
        assert(item[:actions][:install], "expected missing skills to offer install")

        installed = installer.apply(harness: item[:harness], action: "install")
        assert(installed[:changed_skills] == ["tycho"], "expected exact changed skill")
        assert(installed.dig(:harness, :status) == "installed", "expected installed status")

        repeated = installer.apply(harness: item[:harness], action: "install")
        assert(repeated[:changed_skills].empty?, "expected repeated install to be idempotent")
      end
    end
  end

  def assert_outdated_skill_updates_without_removing_extra_files
    with_installer(version: "1") do |installer, home, source, manifest|
      installer.apply(harness: "codex", action: "install")
      target = File.join(home, ".agents", "skills", "tycho")
      unrelated_skill = File.join(home, ".agents", "skills", "mine", "SKILL.md")
      extra_file = File.join(target, "notes.txt")
      FileUtils.mkdir_p(File.dirname(unrelated_skill))
      File.write(unrelated_skill, "user owned")
      File.write(extra_file, "keep me")

      File.write(File.join(source, "tycho", "SKILL.md"), skill_body("updated"))
      write_manifest(manifest, source, version: "2")
      updated_installer = HQ::SkillInstaller.new(home: home, source_root: source, manifest_path: manifest)

      assert(updated_installer.status("codex")[:status] == "outdated", "expected old managed version to be outdated")
      result = updated_installer.apply(harness: "codex", action: "update")
      assert(result[:changed_skills] == ["tycho"], "expected update result to name changed skill")
      assert(File.read(extra_file) == "keep me", "expected extra file in managed skill to survive")
      assert(File.read(unrelated_skill) == "user owned", "expected unrelated skill to survive")
      assert(updated_installer.apply(harness: "codex", action: "update")[:changed_skills].empty?,
             "expected repeated update to be idempotent")
    end
  end

  def assert_unowned_and_locally_modified_skills_are_preserved
    with_installer do |installer, home, _source, _manifest|
      collision = File.join(home, ".claude", "skills", "tycho")
      FileUtils.mkdir_p(collision)
      File.write(File.join(collision, "SKILL.md"), "user owned")

      status = installer.status("claude")
      assert(status[:status] == "conflict", "expected unowned collision status")
      assert(status.dig(:skills, 0, :error).include?("will not overwrite"), "expected collision guidance")
      begin
        installer.apply(harness: "claude", action: "install")
        raise "expected collision to block install"
      rescue HQ::SkillInstaller::InstallError => e
        assert(e.category == "compatibility", "expected collision category")
      end
      assert(File.read(File.join(collision, "SKILL.md")) == "user owned", "expected collision content to survive")

      installer.apply(harness: "opencode", action: "install")
      managed = File.join(home, ".config", "opencode", "skills", "tycho", "SKILL.md")
      File.write(managed, "local edit")
      modified = installer.status("opencode")
      assert(modified[:status] == "conflict", "expected local managed edit to block update")
      assert(modified.dig(:skills, 0, :error).include?("local changes"), "expected local-change guidance")
    end
  end

  def assert_permission_and_partial_failures_are_actionable
    with_installer do |installer, home, _source, _manifest|
      locked = File.join(home, ".agents")
      FileUtils.mkdir_p(locked)
      File.chmod(0o500, locked)
      begin
        installer.apply(harness: "codex", action: "install")
        raise "expected permission failure"
      rescue HQ::SkillInstaller::InstallError => e
        assert(e.category == "permission", "expected permission error category, got #{e.category}")
        assert(e.message.include?("ownership or permissions"), "expected actionable permission guidance")
      ensure
        File.chmod(0o700, locked)
      end
    end

    with_installer(skill_names: %w[one two]) do |installer, _home, _source, _manifest|
      failing = Class.new(HQ::SkillInstaller) do
        private

        def install_skill(harness, skill)
          raise Errno::EACCES, "simulated second skill failure" if skill.fetch("name") == "two"

          super
        end
      end.new(home: installer.instance_variable_get(:@home),
              source_root: installer.instance_variable_get(:@source_root),
              manifest_path: installer.instance_variable_get(:@manifest_path))
      begin
        failing.apply(harness: "claude", action: "install")
        raise "expected partial failure"
      rescue HQ::SkillInstaller::InstallError => e
        assert(e.changed_skills == ["one"], "expected partial result to report completed skill")
        assert(e.category == "permission", "expected partial permission category")
      end
    end
  end

  def with_installer(version: "1", skill_names: ["tycho"])
    Dir.mktmpdir("tycho-skill-installer-test") do |dir|
      home = File.join(dir, "home")
      source = File.join(dir, "source")
      manifest = File.join(dir, "manifest.json")
      FileUtils.mkdir_p(home)
      skill_names.each do |name|
        FileUtils.mkdir_p(File.join(source, name))
        File.write(File.join(source, name, "SKILL.md"), skill_body(name))
      end
      write_manifest(manifest, source, version: version)
      installer = HQ::SkillInstaller.new(home: home, source_root: source, manifest_path: manifest)
      yield installer, home, source, manifest
    end
  end

  def write_manifest(path, source, version:)
    skills = Dir.children(source).sort.map do |name|
      skill_path = File.join(source, name, "SKILL.md")
      {
        "name" => name,
        "files" => { "SKILL.md" => Digest::SHA256.file(skill_path).hexdigest }
      }
    end
    File.write(path, JSON.pretty_generate({
      "source" => "https://example.test/tycho-skills",
      "version" => version,
      "verification" => "Invoke the installed skill",
      "skills" => skills
    }))
  end

  def skill_body(name)
    "---\nname: #{name}\ndescription: Test skill\n---\n\n# #{name}\n"
  end

  def assert(value, message)
    raise message unless value
  end
end

SkillInstallerTest.run!
