# frozen_string_literal: true

require "digest"
require_relative "project_archiver"
require_relative "agent_archive_store"

module HQ
  # Each worker holds an OS lock for its entire lifetime. A persisted running
  # receipt without that lock is interrupted, never permission to replay work.
  class ProjectDeletion
    def initialize(registry:, root: File.join(File.dirname(AGENTS_FILE), "project_deletions"))
      @registry = registry
      @root = root
    end

    def status(key)
      with_lock(key, nonblock: true) do
        job = read(key)
        if job && %w[queued running].include?(job["status"]) && !worker_active?(key)
          job["status"] = "failed"
          job["error"] = "Deletion was interrupted. Check the project state, then retry."
          write(key, job)
        end
      end
      read(key)
    end

    def start(key, remove_data: false, confirmation:, request_id: "default")
      raise ArgumentError, "Type the project key to confirm deletion" unless confirmation == key
      raise ArgumentError, "remove_data must be true or false" unless [true, false].include?(remove_data)

      raise ArgumentError, "Deletion request ID is required" unless request_id.is_a?(String) && request_id.match?(/\A[A-Za-z0-9_-]{1,100}\z/)
      with_lock(key, nonblock: true) do
        previous = read(key)
        registry = fresh_registry
        config = registry.projects.find { |project| project.key == key }
        if previous && previous["request_id"] != request_id
          unless previous["status"] == "completed" && config
            raise ArgumentError, "Another deletion request already exists. Check its progress."
          end
          previous = nil
        end
        if previous && previous["remove_data"] != remove_data
          raise ArgumentError, "Retry with the original deletion options"
        end
        return previous if previous && previous["status"] == "completed"
        unless config || previous&.fetch("phase", nil) == "archived"
          raise ArgumentError, "Unknown project: #{key}"
        end
        if previous && config && config.path != previous["workspace"]
          raise ArgumentError, "Project workspace changed. Deletion is blocked."
        end
        job = previous || {
          "project_key" => key, "workspace" => config.path, "remove_data" => remove_data,
          "request_id" => request_id, "config_path" => @registry.path,
          "phase" => "archive", "created_at" => Time.now.iso8601
        }
        job = job.merge("status" => "queued", "error" => nil)
        with_agent_admission_lock do
          current = fresh_registry.projects.find { |project| project.key == key }
          if config && (!current || current.path != config.path)
            raise ArgumentError, "Project changed. Check its state before retrying."
          end
          if config
            fingerprint = project_fingerprint(key)
            if job["project_fingerprint"] && job["project_fingerprint"] != fingerprint
              raise ArgumentError, "Project configuration changed. Deletion is blocked."
            end
            job["project_fingerprint"] = fingerprint
            references = ScheduleRegistry.new(projects: fresh_registry.projects.map { |project| Project.new(project) }).schedules.select { |schedule| schedule.project_key == key }
            unless references.empty?
              raise ArgumentError, "Remove schedules for this project before deletion: #{references.map(&:key).join(", ")}"
            end
          end
          write(key, job)
        end
        # Acquire the worker lock before releasing the admission lock. The thread
        # owns this descriptor; a server exit releases it in the kernel.
        worker_lock = File.open(lock_path(key, "worker"), File::RDWR | File::CREAT, 0o600)
        unless worker_lock.flock(File::LOCK_EX | File::LOCK_NB)
          worker_lock.close
          return read(key)
        end
        begin
          Thread.new { perform(key, worker_lock) }
        rescue StandardError
          worker_lock.close
          raise
        end
        job
      end || replay_inflight(key, request_id, remove_data)
    end

    private

    def replay_inflight(key, request_id, remove_data)
      job = read(key)
      unless job && job["request_id"] == request_id && job["remove_data"] == remove_data
        raise ArgumentError, "Another deletion request is being processed. Check progress before retrying."
      end
      job
    end

    def perform(key, worker_lock)
      File.open(File.join(@root, "worker.lock"), File::RDWR | File::CREAT, 0o600) do |queue_lock|
        queue_lock.flock(File::LOCK_EX)
        perform_job(key)
      end
    ensure
      worker_lock.close
    end

    def perform_job(key)
      with_lock(key) do
        job = read(key).merge("status" => "running")
        write(key, job)
        begin
          if job["phase"] == "archive"
            registry = fresh_registry
            if job["project_fingerprint"] && job["project_fingerprint"] != project_fingerprint(key)
              raise ArgumentError, "Project configuration changed"
            end
            result = ProjectArchiver.new(registry:).archive(key, deletion_request_id: job["request_id"], remove_configuration: false)
            job["project_log_archive"] = result.project_log_archive
            job["phase"] = "archived"
            write(key, job)
          end
          purge(key, job) if job["remove_data"]
          registry = fresh_registry
          if registry.projects.any? { |project| project.key == key }
            if job["project_fingerprint"] && job["project_fingerprint"] != project_fingerprint(key)
              raise ArgumentError, "Project configuration changed"
            end
            registry.archive_project!(key, deletion_request_id: job["request_id"])
          end
          job["status"] = "completed"
          job["finished_at"] = Time.now.iso8601
        rescue StandardError => e
          job["status"] = "failed"
          # Do not expose process commands, prompt content, or filesystem errors.
          job["error"] = "Deletion failed (#{e.class.name}). Some work may be complete. Retry with the same options."
          HQ.logger.warn("ProjectDeletion") { "Deletion failed for #{key}: #{e.class.name}" }
        ensure
          write(key, job)
        end
      end
    end

    def purge(key, job)
      Dir.glob(File.join(AGENT_ARCHIVE_DIR, "*", "agent_manifest.json")).each do |manifest|
        raise ArgumentError, "Unsafe archive manifest" if File.symlink?(manifest)
        data = JSON.parse(File.read(manifest))
        raise ArgumentError, "Missing project identity" unless data["project_key"].is_a?(String)

        remove_directory(File.dirname(manifest), AGENT_ARCHIVE_DIR) if data["project_key"] == key
      end
      project_archives = Dir.glob(File.join(PROJECT_ARCHIVE_DIR, "*", "project_manifest.json")).filter_map do |manifest|
        next if File.symlink?(manifest)
        data = JSON.parse(File.read(manifest))
        File.dirname(manifest) if data["project_key"] == key
      end
      project_archives << job["project_log_archive"] if job["project_log_archive"]
      project_archives.uniq.each { |directory| remove_directory(directory, PROJECT_ARCHIVE_DIR) }
      AgentArchiveStore.cache_mutex.synchronize { AgentArchiveStore.snapshot_cache.delete(AGENT_ARCHIVE_DIR) }
    end

    def remove_directory(path, root)
      expanded = File.expand_path(path)
      unless File.dirname(expanded) == File.expand_path(root) && !File.symlink?(root) && !File.symlink?(path)
        raise ArgumentError, "Unsafe log directory"
      end
      FileUtils.remove_entry_secure(expanded) if File.exist?(expanded)
    end

    def project_fingerprint(key)
      data = YAML.safe_load_file(@registry.path, permitted_classes: [], aliases: true)
      entry = Array(data["projects"]).find { |project| project["key"] == key }
      Digest::SHA256.hexdigest(JSON.generate(entry&.sort.to_h))
    end

    def fresh_registry
      Registry.new(path: @registry.path, system_prompts_path: @registry.system_prompts_path)
    end

    def with_agent_admission_lock
      File.open("#{@registry.path}.lock", File::RDWR | File::CREAT, 0o600) do |config_lock|
        unless config_lock.flock(File::LOCK_EX | File::LOCK_NB)
          raise ArgumentError, "Project configuration is changing. Try again."
        end
        with_agent_store_lock do
          FileUtils.mkdir_p(File.dirname(SCHEDULES_STATE_FILE))
          File.open("#{File.expand_path(SCHEDULES_STATE_FILE)}.lock", File::RDWR | File::CREAT, 0o600) do |schedule_lock|
            unless schedule_lock.flock(File::LOCK_EX | File::LOCK_NB)
              raise ArgumentError, "Schedules are changing. Try again."
            end
            yield
          end
        end
      end
    end

    def with_agent_store_lock
      FileUtils.mkdir_p(File.dirname(AGENTS_FILE))
      File.open("#{AGENTS_FILE}.lock", File::RDWR | File::CREAT, 0o600) do |file|
        unless file.flock(File::LOCK_EX | File::LOCK_NB)
          raise ArgumentError, "Project state is changing. Check progress, then retry."
        end
        yield
      end
    end

    def worker_active?(key)
      File.open(lock_path(key, "worker"), File::RDWR | File::CREAT, 0o600) do |file|
        !file.flock(File::LOCK_EX | File::LOCK_NB)
      end
    end

    def filename(key)
      Digest::SHA256.hexdigest(key.to_s)
    end

    def lock_path(key, kind = "job")
      File.join(@root, "#{filename(key)}.#{kind}.lock")
    end

    def with_lock(key, nonblock: false)
      FileUtils.mkdir_p(@root)
      File.open(lock_path(key), File::RDWR | File::CREAT, 0o600) do |file|
        return nil unless file.flock(File::LOCK_EX | (nonblock ? File::LOCK_NB : 0))

        yield
      end
    end

    def read(key)
      path = File.join(@root, "#{filename(key)}.json")
      return nil unless File.exist?(path)

      JSON.parse(File.read(path))
    end

    def write(key, job)
      FileStore.write_json(File.join(@root, "#{filename(key)}.json"), job, backup: false)
    end
  end
end
