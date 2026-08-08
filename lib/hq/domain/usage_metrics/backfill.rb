# frozen_string_literal: true

require "digest"
require "json"
require "time"

require_relative "../file_store"
require_relative "../log_paths"
require_relative "../managed_agent"
require_relative "../../parser"
require_relative "../../registry"
require_relative "query"

module HQ
  module UsageMetrics
    class Backfill
      Segment = Struct.new(:started_at, :start_offset, :lines, :index, keyword_init: true)
      HistoricalAgent = Struct.new(
        :key, :project_key, :project_group, :agent, :model, :session_id, :runs,
        keyword_init: true
      )

      def initialize(metrics_store:)
        @metrics_store = metrics_store
      end

      def call(options = {})
        options = stringify(options || {})
        @registry = options["registry"] || Registry.new
        @projects = @registry.projects
        @timezone = options["timezone"].to_s
        @include_raw = options.fetch("include_raw", true) != false
        @stats = Hash.new(0)
        @warnings = []
        @records = []

        manifests = durable_manifests(options)
        claimed = ingest_manifests(manifests)
        ingest_raw_fallback(claimed, options) if @include_raw
        @metrics_store.upsert_many(@records).each { |outcome, count| @stats[outcome] += count }

        {
          "status" => "success",
          "created" => @stats[:created],
          "updated" => @stats[:updated],
          "unchanged" => @stats[:unchanged],
          "manifest_run_count" => @stats[:manifest_runs],
          "raw_fallback_run_count" => @stats[:raw_runs],
          "skipped_run_count" => @stats[:skipped],
          "warnings" => @warnings.uniq
        }
      end

      private

      def durable_manifests(options)
        explicit = options["manifests"]
        return Array(explicit) if explicit

        manifests = []
        if File.exist?(AGENTS_FILE)
          Array(FileStore.read_json(AGENTS_FILE, fallback: [])).each do |hash|
            manifests << { "agent" => ManagedAgent.from_hash(hash), "archived" => false, "directory" => nil }
          end
        end
        Dir.glob(File.join(AGENT_ARCHIVE_DIR, "*", "agent_manifest.json")).sort.each do |path|
          hash = FileStore.read_json(path, fallback: nil)
          next unless hash.is_a?(Hash)

          manifests << {
            "agent" => ManagedAgent.from_hash(hash),
            "archived" => true,
            "directory" => File.dirname(path)
          }
        end
        manifests
      end

      def ingest_manifests(manifests)
        claimed = {}
        manifests.each do |entry|
          agent = entry.fetch("agent")
          archived = entry["archived"] == true
          reconcile_group!(agent)
          grouped_runs(agent, entry["directory"]).each do |path, runs|
            segments = segments_for(path)
            runs.each do |run|
              segment = matching_segment(segments, run)
              usage = usage_entries(segment&.lines, agent.agent)
              run.session_id ||= session_id_from(segment&.lines, agent.agent)
              inference = {
                "archived" => archived,
                "source_identity" => source_identity(path, segment),
                "unknown_reasons" => manifest_unknowns(run, segment),
                "codex_baseline_known" => manifest_baseline_known?(agent, run)
              }
              ingest(agent, run, usage, source: "durable_agent_manifest", inference:)
              @stats[:manifest_runs] += 1
              claimed[[File.expand_path(path), segment.index]] = true if segment
            end
          end
        rescue StandardError => error
          @warnings << "Skipped one durable manifest after #{error.class}"
          @stats[:skipped] += 1
        end
        claimed
      end

      def ingest_raw_fallback(claimed, options)
        if @timezone.empty?
          @warnings << "Raw-log fallback skipped because an explicit timezone was not supplied"
          return
        end

        raw_paths(options).each do |path|
          segments_for(path).each do |segment|
            next if claimed[[File.expand_path(path), segment.index]]

            ingest_raw_segment(path, segment)
          end
        rescue StandardError => error
          @warnings << "Skipped one raw telemetry file after #{error.class}"
          @stats[:skipped] += 1
        end
      end

      def ingest_raw_segment(path, segment)
        harness = infer_harness(segment.lines)
        harness_unknown = harness.nil?
        harness ||= "unknown"

        agent_key, agent_key_inferred = agent_key_for(path)
        project = project_for_agent_key(agent_key) || project_for_raw_name(path)
        project_key = project&.key.to_s
        group = project&.group.to_s
        session_id = session_id_from(segment.lines, harness)
        usage = usage_entries(segment.lines, harness)
        finish = inferred_finish(segment.started_at, usage)
        run = ManagedAgent::AgentRun.new(
          started_at: segment.started_at,
          finished_at: finish,
          status: inferred_status(segment.lines, harness),
          session_id: session_id,
          agent: harness,
          model: nil,
          log_start_offset: segment.start_offset
        )
        agent = HistoricalAgent.new(
          key: agent_key,
          project_key: project_key,
          project_group: group,
          agent: harness,
          model: nil,
          session_id: session_id,
          runs: [run]
        )
        inferred_fields = %w[started_at]
        inferred_fields.concat(%w[harness status]) unless harness_unknown
        inferred_fields << "agent_key" if agent_key_inferred
        inferred_fields.concat(%w[project_key group]) if project
        unknowns = []
        unknowns << "Harness attribution was unavailable" if harness_unknown
        unknowns << "Run status was unavailable" if harness_unknown
        unknowns << "Agent identity was unavailable; a stable anonymous identity was assigned" if agent_key_inferred
        unknowns << "Project attribution was unavailable" unless project
        unknowns << "Configured model was not preserved in a durable manifest"
        unknowns << "Run finish time was not reported" unless finish
        inference = {
          "archived" => archived_path?(path),
          "source_identity" => source_identity(path, segment),
          "inferred_fields" => inferred_fields,
          "unknown_reasons" => unknowns,
          "codex_baseline_known" => false
        }
        ingest(agent, run, usage, source: "legacy_raw_telemetry_fallback", inference:)
        @stats[:raw_runs] += 1
      end

      def ingest(agent, run, usage, source:, inference:)
        record = Normalizer.new(agent:, run:, usage_entries: usage, source:, inference:).record
        @records << record
      end

      def grouped_runs(agent, archived_directory)
        agent.runs.group_by do |run|
          if archived_directory
            File.join(archived_directory, File.basename(run.log_path.to_s.empty? ? agent.raw_log_path : run.log_path))
          else
            run.log_path.to_s.empty? ? agent.raw_log_path : run.log_path
          end
        end.reject { |path, _runs| path.to_s.empty? || !File.file?(path) }
      end

      def matching_segment(segments, run)
        by_offset = segments.find { |segment| run.log_start_offset && segment.start_offset == run.log_start_offset }
        return by_offset if by_offset
        return nil unless run.started_at

        segments.find { |segment| (segment.started_at - run.started_at).abs < 1 }
      end

      def segments_for(path)
        return [] unless File.file?(path)

        segments = []
        current = nil
        offset = 0
        File.foreach(path) do |line|
          if (match = line.match(/\A=== \[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] start ===\s*\z/))
            segments << current if current
            started_at = parse_legacy_time(match[1])
            current = Segment.new(started_at:, start_offset: offset + line.bytesize, lines: [], index: segments.length)
          elsif current
            current.lines << line.chomp
          end
          offset += line.bytesize
        end
        segments << current if current
        segments.compact
      end

      def parse_legacy_time(text)
        if @timezone.empty?
          Time.parse(text)
        else
          Query.parse_boundary(text, timezone: @timezone)
        end
      end

      def usage_entries(lines, harness)
        return [] if lines.nil?

        adapter = HQ.harness_adapter(harness)
        Array(lines).filter_map do |line|
          next unless line.to_s.lstrip.start_with?("{")

          event = JSON.parse(line)
          metadata = case adapter
                     when "codex"
                       next unless event["type"] == "turn.completed"
                       {
                         "event_type" => "turn.completed",
                         "usage" => event["usage"],
                         "model" => event["model"]
                       }
                     when "claude"
                       next unless event["type"] == "result"
                       {
                         "event_type" => "result",
                         "total_cost_usd" => event["total_cost_usd"],
                         "usage" => event["usage"],
                         "model_usage" => event["modelUsage"] || event["model_usage"],
                         "model" => event["model"],
                         "duration_ms" => event["duration_ms"]
                       }
                     when "opencode"
                       next unless event["type"] == "step_finish"
                       {
                         "event_type" => "step_finish",
                         "total_cost_usd" => event["total_cost_usd"] || event.dig("part", "cost"),
                         "usage" => event["usage"] || event.dig("part", "tokens"),
                         "model" => event["model"] || event.dig("part", "model")
                       }
                     end
          next unless metadata

          Parser::SystemEntry.new(type: :usage, content: "usage", timestamp: nil, tool_name: nil,
                                  metadata: metadata.compact)
        rescue JSON::ParserError
          nil
        end
      end

      def session_id_from(lines, harness)
        Array(lines).each do |line|
          event = JSON.parse(line) if line.to_s.lstrip.start_with?("{")
          next unless event.is_a?(Hash)
          id = case HQ.harness_adapter(harness)
               when "codex" then event["thread_id"] || event["session_id"] || (event["id"] if event["type"] == "thread.started")
               when "opencode" then event["session_id"] || event["sessionID"] || event["sessionId"] || event.dig("session", "id")
               else event["session_id"]
               end
          return id.to_s unless id.to_s.empty?
        rescue JSON::ParserError
          next
        end
        nil
      end

      def infer_harness(lines)
        event_types = Array(lines).filter_map do |line|
          next unless line.to_s.lstrip.start_with?("{")

          JSON.parse(line)["type"]
        rescue JSON::ParserError
          nil
        end
        return "opencode" if event_types.any? { |type| %w[step_start step_finish text].include?(type) }
        return "claude" if event_types.any? { |type| %w[assistant user result].include?(type) }
        return "codex" if event_types.any? { |type| type.to_s.start_with?("thread.", "turn.", "item.") }

        nil
      end

      def inferred_status(lines, harness)
        events = Array(lines).filter_map do |line|
          JSON.parse(line) if line.to_s.lstrip.start_with?("{")
        rescue JSON::ParserError
          nil
        end
        adapter = HQ.harness_adapter(harness)
        if adapter == "codex"
          return "failed" if events.any? { |event| %w[turn.failed error].include?(event["type"]) }
          return "succeeded" if events.any? { |event| event["type"] == "turn.completed" }
        elsif adapter == "claude"
          result = events.reverse.find { |event| event["type"] == "result" }
          return result["is_error"] ? "failed" : "succeeded" if result
        elsif adapter == "opencode"
          return "succeeded" if events.any? { |event| event["type"] == "step_finish" }
        end
        "unknown"
      end

      def inferred_finish(started_at, usage)
        duration = usage.reverse.filter_map { |entry| numeric(entry.metadata&.dig("duration_ms")) }.first
        duration ? started_at + (duration / 1000.0) : nil
      end

      def manifest_baseline_known?(agent, run)
        return nil unless HQ.harness_adapter(run.agent.to_s.empty? ? agent.agent : run.agent) == "codex"

        prior = agent.runs.take_while { |candidate| candidate != run }
                     .count { |candidate| candidate.session_id.to_s == run.session_id.to_s }
        prior.zero?
      end

      def manifest_unknowns(run, segment)
        reasons = []
        reasons << "Raw telemetry for the durable run was unavailable" unless segment
        reasons << "Run finish time was not recorded" unless run.finished_at
        reasons
      end

      def reconcile_group!(agent)
        project = @projects.find { |candidate| candidate.key == agent.project_key }
        agent.reconcile_project_group!(project.group) if project && agent.respond_to?(:reconcile_project_group!)
      end

      def project_for_agent_key(agent_key)
        @projects.select { |project| agent_key.to_s.start_with?("#{project.key}-agent-") }.max_by { |project| project.key.length }
      end

      def project_for_raw_name(path)
        name = File.basename(path)
        @projects.select { |project| name.start_with?("#{project.key}-") }.max_by { |project| project.key.length }
      end

      def agent_key_for(path)
        if archived_path?(path)
          directory = File.basename(File.dirname(path))
          match = directory.match(/\A\d{8}-\d{6}-(.+)\z/)
          return [match[1], false] if match
        end

        digest = Digest::SHA256.hexdigest(File.expand_path(path))[0, 24]
        ["unknown-agent-#{digest}", true]
      end

      def archived_path?(path)
        File.expand_path(path).start_with?(File.expand_path(AGENT_ARCHIVE_DIR) + File::SEPARATOR)
      end

      def raw_paths(options)
        explicit = options["raw_paths"]
        return Array(explicit).map(&:to_s).uniq.sort if explicit

        Dir.glob(File.join(AGENT_LOGS_DIR, "*.raw.log")) +
          Dir.glob(File.join(AGENT_ARCHIVE_DIR, "*", "*.raw.log"))
      end

      def source_identity(path, segment)
        Digest::SHA256.hexdigest([File.expand_path(path), segment&.start_offset].join("\0"))
      end

      def numeric(value)
        number = Float(value)
        number if number.finite? && number >= 0
      rescue ArgumentError, TypeError
        nil
      end

      def stringify(value)
        value.each_with_object({}) { |(key, entry), result| result[key.to_s] = entry }
      end
    end
  end
end
