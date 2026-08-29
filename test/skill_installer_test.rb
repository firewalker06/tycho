# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

require_relative "../lib/hq/domain/skill_installer"

module SkillInstallerTest
  module_function

  def run!
    assert_bundled_source_manifest_is_valid
    assert_bundled_skill_documents_delegation_capabilities
    assert_supported_harness_paths_and_idempotent_install
    assert_outdated_skill_updates_without_removing_extra_files
    assert_unowned_and_locally_modified_skills_are_preserved
    assert_symlinked_managed_paths_are_rejected
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

  def assert_bundled_skill_documents_delegation_capabilities
    skill = File.read(File.join(HQ::SkillInstaller::DEFAULT_SOURCE_ROOT, "tycho", "SKILL.md"))
    required = [
      "Tycho does not issue or require a delegation token",
      '"${TYCHO_EXECUTABLE:-tycho}"',
      '--parent-agent "${TYCHO_AGENT_KEY:?Missing TYCHO_AGENT_KEY}"',
      "Treat a direct user prompt to a delegated child as Takeover",
      "every terminal delegated run to create one deduplicated report"
    ]
    missing = required.reject { |text| skill.include?(text) }
    assert(missing.empty?, "expected bundled skill delegation guidance: #{missing.join(", ")}")
  end

  def assert_supported_harness_paths_and_idempotent_install
    with_installer do |installer, home, _source, _manifest|
      expected = {
        "codex" => File.join(home, ".agents", "skills"),
        "claude" => File.join(home, ".claude", "skills"),
        "opencode" => File.join(home, ".config", "opencode", "skills"),
        "pi" => File.join(home, ".pi", "agent", "skills")
      }
      statuses = installer.statuses
      assert(statuses.map { |item| item[:harness] } == %w[codex claude opencode pi], "expected supported harness order")
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

  def assert_symlinked_managed_paths_are_rejected
    with_installer do |installer, home, _source, _manifest|
      external = File.join(home, "external-target-root")
      FileUtils.mkdir_p(external)
      File.symlink(external, File.join(home, ".agents"))
      status = installer.status("codex")
      assert(status[:status] == "conflict", "expected symlinked target root to be a conflict")
      begin
        installer.apply(harness: "codex", action: "install")
        raise "expected symlinked target root to block install"
      rescue HQ::SkillInstaller::InstallError => e
        assert(e.category == "compatibility", "expected symlinked target root to be a compatibility error")
      end
      assert(Dir.children(external).empty?, "expected symlinked target root to remain unchanged")
    end

    assert_symlink_conflict("target skill directory") do |home, target, external|
      FileUtils.mv(target, external)
      File.symlink(external, target)
    end

    assert_symlink_conflict("ownership marker") do |_home, target, external|
      marker = File.join(target, HQ::SkillInstaller::MARKER_FILE)
      FileUtils.mv(marker, external)
      File.symlink(external, marker)
    end

    assert_symlink_conflict("managed file") do |_home, target, external|
      managed_file = File.join(target, "SKILL.md")
      FileUtils.mv(managed_file, external)
      File.symlink(external, managed_file)
    end

    with_installer do |installer, _home, source, manifest|
      nested_source = File.join(source, "tycho", "docs", "reference.md")
      FileUtils.mkdir_p(File.dirname(nested_source))
      File.write(nested_source, "managed reference")
      write_manifest(manifest, source, version: "1")
      installer.apply(harness: "codex", action: "install")
      target = installer.status("codex").dig(:skills, 0, :path)
      nested_directory = File.join(target, "docs")
      external = File.join(File.dirname(target), "external-managed-component")
      FileUtils.mv(nested_directory, external)
      File.symlink(external, nested_directory)

      assert_blocked_symlink_update(installer, "managed path component", external, "reference.md")
    end
  end

  def assert_symlink_conflict(label)
    with_installer do |installer, home, _source, _manifest|
      installer.apply(harness: "codex", action: "install")
      target = installer.status("codex").dig(:skills, 0, :path)
      external = File.join(home, "external-#{label.tr(" ", "-")}")
      yield home, target, external

      assert_blocked_symlink_update(installer, label, external)
    end
  end

  def assert_blocked_symlink_update(installer, label, external, nested_file = nil)
    before = nested_file ? File.binread(File.join(external, nested_file)) : external_snapshot(external)
    status = installer.status("codex")
    assert(status[:status] == "conflict", "expected symlinked #{label} to be a conflict")
    assert(status.dig(:skills, 0, :error).include?("will not follow"),
           "expected symlinked #{label} to explain the safe refusal")
    begin
      installer.apply(harness: "codex", action: "update")
      raise "expected symlinked #{label} to block update"
    rescue HQ::SkillInstaller::InstallError => e
      assert(e.category == "compatibility", "expected symlinked #{label} to be a compatibility error")
    end
    after = nested_file ? File.binread(File.join(external, nested_file)) : external_snapshot(external)
    assert(after == before, "expected symlinked #{label} target to remain unchanged")
  end

  def external_snapshot(path)
    return File.binread(path) if File.file?(path)

    Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |entry|
      next unless File.file?(entry)

      [entry.delete_prefix("#{path}/"), File.binread(entry)]
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
      skill_root = File.join(source, name)
      files = Dir.glob(File.join(skill_root, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |skill_path|
        next unless File.file?(skill_path)

        [skill_path.delete_prefix("#{skill_root}/"), Digest::SHA256.file(skill_path).hexdigest]
      end.to_h
      {
        "name" => name,
        "files" => files
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
