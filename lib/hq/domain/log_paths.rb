# frozen_string_literal: true

require "securerandom"

require_relative "constants"

module HQ
  module LogPaths
    AGENT_RAW_SUFFIX = ".raw.log"

    module_function

    def project_log_dir(project_key)
      File.join(PROJECT_LOGS_DIR, project_key.to_s)
    end

    def project_action_log_path(project_key)
      File.join(project_log_dir(project_key), "action.log")
    end

    def project_healthcheck_log_path
      File.join(PROJECT_LOGS_DIR, "healthcheck.log")
    end

    def project_archive_destination(root, archive_name, now: Time.now)
      unique_path(File.join(root, "#{now.strftime("%Y-%m-%d")}_#{safe_segment(archive_name)}"))
    end

    def agent_raw_log_path(project_key, created_at: Time.now)
      stem = [
        safe_segment(project_key),
        timestamp_for_filename(created_at),
        SecureRandom.hex(4)
      ].reject(&:empty?).join("-")
      File.join(AGENT_LOGS_DIR, "#{stem}#{AGENT_RAW_SUFFIX}")
    end

    def legacy_agent_raw_log_path(agent_key)
      File.join(AGENT_LOGS_DIR, "#{agent_key}.raw.log")
    end

    def agent_archive_destination(root, agent_key, now: Time.now)
      unique_path(File.join(root, "#{timestamp_for_filename(now)}-#{safe_segment(agent_key)}"))
    end

    def derived_agent_log_path(raw_log_path, suffix)
      base = raw_log_path.to_s
      normalized_suffix = suffix.to_s.sub(/\A\.+/, "")
      if base.end_with?(AGENT_RAW_SUFFIX)
        base.sub(/\.raw\.log\z/, ".#{normalized_suffix}")
      elsif base.end_with?(".log")
        base.sub(/\.log\z/, ".#{normalized_suffix}")
      else
        "#{base}.#{normalized_suffix}"
      end
    end

    def timestamp_for_filename(time)
      value = time.is_a?(Time) ? time : Time.parse(time.to_s)
      value.strftime("%Y%m%d-%H%M%S")
    rescue StandardError
      Time.now.strftime("%Y%m%d-%H%M%S")
    end

    def safe_segment(value)
      segment = value.to_s.strip.gsub(/[^A-Za-z0-9._-]+/, "-").gsub(/\A[-.]+|[-.]+\z/, "")
      segment.empty? ? "log" : segment
    end

    def unique_path(base)
      destination = base
      suffix = 2
      while File.exist?(destination)
        destination = "#{base}_#{suffix}"
        suffix += 1
      end
      destination
    end
  end
end
