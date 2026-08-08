# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "tmpdir"

module HQ
  class SkillInstaller
    OWNER = "tycho"
    MARKER_FILE = ".tycho-owned.json"
    SUPPORTED_HARNESSES = {
      "codex" => ".agents/skills",
      "claude" => ".claude/skills",
      "opencode" => ".config/opencode/skills"
    }.freeze
    DEFAULT_SOURCE_ROOT = File.expand_path("../skill_assets", __dir__)
    DEFAULT_MANIFEST_PATH = File.expand_path("../skill_assets.json", __dir__)

    class InstallError < StandardError
      attr_reader :category, :changed_skills

      def initialize(message, category:, changed_skills: [])
        super(message)
        @category = category
        @changed_skills = changed_skills
      end

      def to_h
        { category: category, message: message, changed_skills: changed_skills }
      end
    end

    def initialize(home: Dir.home, source_root: DEFAULT_SOURCE_ROOT, manifest_path: DEFAULT_MANIFEST_PATH)
      @home = File.expand_path(home)
      @source_root = File.expand_path(source_root)
      @manifest_path = File.expand_path(manifest_path)
    end

    def statuses
      SUPPORTED_HARNESSES.keys.map { |harness| status(harness) }
    end

    def status(harness)
      harness = normalize_harness(harness)
      source = source_manifest
      skills = source.fetch("skills").map { |skill| skill_status(harness, skill) }
      state = aggregate_state(skills)
      {
        harness: harness,
        status: state,
        target_path: target_root(harness),
        source: source.fetch("source"),
        version: source.fetch("version"),
        verification: source.fetch("verification"),
        skills: skills,
        actions: actions_for(state)
      }
    rescue InstallError => e
      error_status(harness, e)
    end

    def apply(harness:, action:)
      harness = normalize_harness(harness)
      action = action.to_s
      unless %w[install update].include?(action)
        raise InstallError.new("Action must be install or update", category: "compatibility")
      end

      before = status(harness)
      raise_status_error!(before)
      return result(harness, action, []) if before[:status] == "installed"
      if action == "install" && before[:status] == "outdated"
        raise InstallError.new("Tycho skills are outdated for #{harness}; choose Update", category: "compatibility")
      end
      if action == "update" && before[:status] == "missing"
        raise InstallError.new("Tycho skills are missing for #{harness}; choose Install", category: "compatibility")
      end
      unless before[:status] == action_state(action)
        detail = before[:skills].filter_map { |skill| skill[:error] }.join(" ")
        raise InstallError.new(detail.empty? ? "Tycho skills cannot be changed safely" : detail,
                               category: "compatibility")
      end

      changed = []
      before_by_name = before.fetch(:skills).to_h { |skill| [skill.fetch(:name), skill.fetch(:status)] }
      source_manifest.fetch("skills").each do |skill|
        skill_state = before_by_name.fetch(skill.fetch("name"))
        next if skill_state == "installed"

        if skill_state == "missing"
          install_skill(harness, skill)
        else
          update_skill(harness, skill)
        end
        changed << skill.fetch("name")
      rescue StandardError => e
        raise classified_error(e, changed)
      end
      result(harness, action, changed)
    rescue InstallError
      raise
    rescue StandardError => e
      raise classified_error(e, [])
    end

    private

    def source_manifest
      @source_manifest ||= begin
        parsed = JSON.parse(File.read(@manifest_path))
        validate_manifest!(parsed)
        parsed
      rescue InstallError
        raise
      rescue JSON::ParserError, Errno::ENOENT => e
        raise InstallError.new("Tycho skill source manifest is unavailable: #{e.message}", category: "compatibility")
      end
    end

    def validate_manifest!(manifest)
      %w[source version verification skills].each do |key|
        next unless manifest[key].to_s.empty? || (key == "skills" && !manifest[key].is_a?(Array))

        raise InstallError.new("Tycho skill source manifest is missing #{key}", category: "compatibility")
      end
      manifest.fetch("skills").each do |skill|
        name = skill.fetch("name").to_s
        unless name.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
          raise InstallError.new("Tycho skill name #{name.inspect} is incompatible", category: "compatibility")
        end
        skill.fetch("files").each do |relative_path, expected_checksum|
          validate_relative_path!(relative_path)
          actual = checksum(source_file(name, relative_path))
          next if secure_equal?(actual, expected_checksum)

          raise InstallError.new("Bundled Tycho skill #{name}/#{relative_path} failed its checksum; reinstall Tycho",
                                 category: "compatibility")
        end
      end
    rescue KeyError => e
      raise InstallError.new("Tycho skill source manifest is incomplete: #{e.message}", category: "compatibility")
    end

    def skill_status(harness, skill)
      name = skill.fetch("name")
      directory = skill_directory(harness, name)
      return { name: name, status: "missing", path: directory } unless File.exist?(directory)
      unless File.directory?(directory)
        return collision_status(name, directory, "The target exists but is not a directory; move it before installing")
      end

      marker = read_marker(directory)
      return collision_status(name, directory, "An unowned skill already uses this name; Tycho will not overwrite it") unless marker
      unless owned_marker?(marker, name)
        return collision_status(name, directory, "The ownership marker is not valid for this Tycho skill")
      end
      unless installed_files_unchanged?(directory, marker)
        return collision_status(name, directory, "This Tycho-owned skill has local changes; move or reconcile them manually")
      end

      expected = skill.fetch("files")
      current = expected.all? do |relative_path, expected_checksum|
        secure_equal?(checksum(File.join(directory, relative_path)), expected_checksum)
      end
      {
        name: name,
        status: current && marker["version"] == source_manifest.fetch("version") ? "installed" : "outdated",
        path: directory,
        installed_version: marker["version"]
      }
    rescue JSON::ParserError
      collision_status(name, directory, "The Tycho ownership marker is invalid JSON; repair or remove this skill manually")
    rescue Errno::EACCES, Errno::EPERM => e
      { name: name, status: "error", path: directory, error: permission_message(directory, e) }
    end

    def read_marker(directory)
      path = File.join(directory, MARKER_FILE)
      return nil unless File.file?(path)

      JSON.parse(File.read(path))
    end

    def owned_marker?(marker, name)
      marker["schema_version"] == 1 && marker["owner"] == OWNER && marker["skill"] == name &&
        marker["source"] == source_manifest.fetch("source") && marker["files"].is_a?(Hash)
    end

    def installed_files_unchanged?(directory, marker)
      marker.fetch("files").all? do |relative_path, installed_checksum|
        validate_relative_path!(relative_path)
        secure_equal?(checksum(File.join(directory, relative_path)), installed_checksum)
      end
    end

    def install_skill(harness, skill)
      destination = skill_directory(harness, skill.fetch("name"))
      raise InstallError.new("A skill already exists at #{destination}", category: "compatibility") if File.exist?(destination)

      parent = File.dirname(destination)
      FileUtils.mkdir_p(parent)
      staging = Dir.mktmpdir(".tycho-skill-", parent)
      populate_skill(staging, skill)
      File.rename(staging, destination)
      staging = nil
    ensure
      FileUtils.remove_entry(staging) if staging && File.exist?(staging)
    end

    def update_skill(harness, skill)
      destination = skill_directory(harness, skill.fetch("name"))
      parent = File.dirname(destination)
      staging = Dir.mktmpdir(".tycho-skill-", parent)
      FileUtils.copy_entry(destination, staging, false, false, true)
      populate_skill(staging, skill)
      backup = File.join(parent, ".#{skill.fetch("name")}.tycho-backup-#{SecureRandom.hex(6)}")
      File.rename(destination, backup)
      begin
        File.rename(staging, destination)
        staging = nil
      rescue StandardError
        File.rename(backup, destination) unless File.exist?(destination)
        raise
      end
      FileUtils.remove_entry(backup)
      backup = nil
    ensure
      FileUtils.remove_entry(staging) if staging && File.exist?(staging)
      if backup && File.exist?(backup) && !File.exist?(destination)
        File.rename(backup, destination)
      end
    end

    def populate_skill(directory, skill)
      installed_files = {}
      skill.fetch("files").each do |relative_path, expected_checksum|
        destination = File.join(directory, relative_path)
        FileUtils.mkdir_p(File.dirname(destination))
        atomic_write(destination, File.binread(source_file(skill.fetch("name"), relative_path)))
        installed_files[relative_path] = expected_checksum
      end
      marker = {
        "schema_version" => 1,
        "owner" => OWNER,
        "skill" => skill.fetch("name"),
        "source" => source_manifest.fetch("source"),
        "version" => source_manifest.fetch("version"),
        "files" => installed_files
      }
      atomic_write(File.join(directory, MARKER_FILE), "#{JSON.pretty_generate(marker)}\n")
    end

    def atomic_write(path, content)
      temp = File.join(File.dirname(path), ".#{File.basename(path)}.tmp-#{SecureRandom.hex(6)}")
      File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.binmode
        file.write(content)
        file.flush
        file.fsync
      end
      File.rename(temp, path)
    ensure
      File.delete(temp) if temp && File.exist?(temp)
    end

    def result(harness, action, changed)
      { action: action, changed_skills: changed, harness: status(harness) }
    end

    def aggregate_state(skills)
      states = skills.map { |skill| skill[:status] }
      return "error" if states.include?("error")
      return "conflict" if states.include?("conflict")
      return "missing" if states.all?("missing")
      return "installed" if states.all?("installed")

      "outdated"
    end

    def actions_for(state)
      {
        install: state == "missing",
        update: state == "outdated",
        blocked: %w[conflict error].include?(state)
      }
    end

    def action_state(action)
      action == "install" ? "missing" : "outdated"
    end

    def error_status(harness, error)
      {
        harness: harness.to_s,
        status: "error",
        target_path: supported_harness?(harness) ? target_root(harness) : nil,
        source: nil,
        version: nil,
        verification: nil,
        skills: [],
        actions: { install: false, update: false, blocked: true },
        error: error.to_h
      }
    end

    def collision_status(name, path, message)
      { name: name, status: "conflict", path: path, error: message }
    end

    def raise_status_error!(payload)
      return unless payload[:status] == "error"

      error = payload.fetch(:error)
      raise InstallError.new(error.fetch(:message), category: error.fetch(:category))
    end

    def classified_error(error, changed)
      return error if error.is_a?(InstallError)

      category = case error
                 when Errno::EACCES, Errno::EPERM, Errno::EROFS
                   "permission"
                 when SocketError
                   "network"
                 else
                   "compatibility"
                 end
      message = if category == "permission"
                  permission_message(@home, error)
                elsif category == "network"
                  "Could not retrieve the Tycho skill source: #{error.message}. Check network access and retry."
                else
                  "Could not change Tycho skills: #{error.message}"
                end
      InstallError.new(message, category: category, changed_skills: changed)
    end

    def permission_message(path, error)
      "Tycho cannot write #{path}: #{error.message}. Fix ownership or permissions for this directory and retry."
    end

    def target_root(harness)
      File.join(@home, SUPPORTED_HARNESSES.fetch(normalize_harness(harness)))
    end

    def skill_directory(harness, name)
      File.join(target_root(harness), name)
    end

    def source_file(name, relative_path)
      File.join(@source_root, name, relative_path)
    end

    def validate_relative_path!(path)
      clean = path.to_s
      if clean.empty? || clean.start_with?("/") || clean.split(File::SEPARATOR).include?("..")
        raise InstallError.new("Unsafe Tycho skill file path: #{path.inspect}", category: "compatibility")
      end
    end

    def normalize_harness(harness)
      value = harness.to_s.downcase
      return value if SUPPORTED_HARNESSES.key?(value)

      raise InstallError.new("Unsupported skill harness #{harness.inspect}; choose codex, claude, or opencode",
                             category: "compatibility")
    end

    def supported_harness?(harness)
      SUPPORTED_HARNESSES.key?(harness.to_s.downcase)
    end

    def checksum(path)
      Digest::SHA256.file(path).hexdigest
    rescue Errno::ENOENT
      ""
    end

    def secure_equal?(left, right)
      left.to_s == right.to_s
    end
  end
end
