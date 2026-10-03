# frozen_string_literal: true

require "digest"
require "json"

module HQ
  class ContextPressure
    WARNING_RATIO = 0.80
    CRITICAL_RATIO = 0.95
    OVERFLOW_PATTERN = /(?:context (?:window )?(?:is )?(?:full|exceeded|overflow)|maximum context length|too many tokens)/i

    def initialize(agent)
      @agent = agent
    end

    def snapshot
      evidence = scan_events
      signal = best_signal(evidence)
      return unknown_snapshot(evidence) unless signal

      signal_id = Digest::SHA256.hexdigest(JSON.generate(signal))
      acknowledged = @agent.context_pressure_acknowledged_signal.to_s == signal_id
      signal.merge(
        "signal_id" => signal_id,
        "acknowledged" => acknowledged,
        "warning" => signal.fetch("warning", true) && !acknowledged,
        "actions" => available_actions
      )
    rescue StandardError => error
      unknown_snapshot([], "Context telemetry could not be read: #{error.class}")
    end

    private

    def scan_events
      return [] unless File.file?(@agent.raw_log_path)

      run_index = -1
      File.foreach(@agent.raw_log_path).filter_map do |line|
        run_index += 1 if line.start_with?("=== [") && line.include?(" start")
        text = line.to_s.strip
        next unless text.start_with?("{")

        event = JSON.parse(text)
        { "event" => event, "run_index" => run_index }
      rescue JSON::ParserError
        nil
      end
    end

    def best_signal(evidence)
      signals = evidence.filter_map do |entry|
        event = entry.fetch("event")
        measured_context_signal(event, entry.fetch("run_index")) ||
          compaction_signal(event, entry.fetch("run_index")) ||
          overflow_signal(event, entry.fetch("run_index"))
      end
      signal = signals.max_by { |candidate| [candidate.fetch("run_index", -1), candidate.fetch("priority", 0)] }
      return unless signal

      latest_run_index = evidence.map { |entry| entry.fetch("run_index", -1) }.max || -1
      if signal["source"] == "harness_context_window" && signal.fetch("run_index", -1) < latest_run_index
        return signal.merge(
          "state" => "stale",
          "level" => "none",
          "summary" => "Context telemetry is stale",
          "detail" => "A later run did not report active-context telemetry. Tycho will not reuse the older percentage as a warning.",
          "stale" => true,
          "warning" => false
        ).except("run_index", "priority")
      end

      signal.merge("stale" => false).except("run_index", "priority")
    end

    def measured_context_signal(event, run_index)
      info = if event["type"] == "event_msg" && event.dig("payload", "type") == "token_count"
               event.dig("payload", "info")
             elsif event["type"] == "token_count"
               event["info"] || event
             end
      return unless info.is_a?(Hash)

      used = number(info.dig("last_token_usage", "total_tokens") || info["context_tokens"])
      limit = number(info["model_context_window"] || info["context_window"])
      return unless used && limit&.positive?

      ratio = used / limit
      return if ratio < WARNING_RATIO

      level = ratio >= CRITICAL_RATIO ? "critical" : "warning"
      {
        "state" => level,
        "level" => level,
        "basis" => "measured",
        "summary" => level == "critical" ? "Context is almost full" : "Context pressure is high",
        "detail" => "The harness reported #{used.to_i} active tokens in a #{limit.to_i}-token window.",
        "used_tokens" => used.to_i,
        "limit_tokens" => limit.to_i,
        "utilization" => ratio,
        "source" => "harness_context_window",
        "run_index" => run_index,
        "priority" => level == "critical" ? 4 : 3
      }
    end

    def compaction_signal(event, run_index)
      type = event["type"].to_s
      subtype = event["subtype"].to_s
      return unless subtype == "compact_boundary" || type == "compaction_end" || type == "session_compact"

      metadata = event["compact_metadata"] || event["compactMetadata"] || event["compaction"] || {}
      reason = metadata["trigger"] || event["reason"] || "automatic"
      pre_tokens = number(metadata["pre_tokens"] || metadata["preTokens"])
      post_tokens = number(metadata["post_tokens"] || metadata["postTokens"] || metadata["estimatedTokensAfter"])
      measured = pre_tokens && post_tokens
      detail = "The harness compacted the session because of #{reason} context pressure. Compaction is lossy."
      detail += " It reduced the active context from #{pre_tokens.to_i} to #{post_tokens.to_i} tokens." if measured
      {
        "state" => "warning",
        "level" => "warning",
        "basis" => measured ? "measured" : "reported",
        "summary" => "The harness compacted this session",
        "detail" => detail,
        "used_tokens" => pre_tokens&.to_i,
        "post_compaction_tokens" => post_tokens&.to_i,
        "limit_tokens" => nil,
        "utilization" => nil,
        "source" => "harness_compaction",
        "run_index" => run_index,
        "priority" => 2
      }
    end

    def overflow_signal(event, run_index)
      text = [event["message"], event["error"], event.dig("error", "message"),
              event.dig("message", "errorMessage")].compact.join(" ")
      return unless text.match?(OVERFLOW_PATTERN)

      {
        "state" => "critical",
        "level" => "critical",
        "basis" => "reported",
        "summary" => "The harness reported a context overflow",
        "detail" => "The active context reached the harness limit. Start a fresh agent before more work.",
        "used_tokens" => nil,
        "limit_tokens" => nil,
        "utilization" => nil,
        "source" => "harness_overflow",
        "run_index" => run_index,
        "priority" => 5
      }
    end

    def unknown_snapshot(evidence, detail = nil)
      {
        "state" => "unknown",
        "level" => "none",
        "basis" => "unknown",
        "summary" => "Context pressure is unknown",
        "detail" => detail || unknown_detail(evidence),
        "warning" => false,
        "acknowledged" => false,
        "signal_id" => nil,
        "used_tokens" => nil,
        "limit_tokens" => nil,
        "utilization" => nil,
        "source" => nil,
        "stale" => false,
        "actions" => available_actions
      }
    end

    def unknown_detail(evidence)
      return "No harness context telemetry is available yet." if evidence.empty?

      "This harness did not report a reliable active-context limit. Token totals are not used as context-window evidence."
    end

    def available_actions
      {
        "keep_going" => true,
        "clone_fresh" => true,
        "clone_with_handoff" => true,
        "archive" => !@agent.running? &&
          (!@agent.pending_prompts? || @agent.delegation_callback_prompts_only?) &&
          !@agent.inquiry_blocking_prompt_queue?
      }
    end

    def number(value)
      result = Float(value)
      result if result.finite? && result >= 0
    rescue ArgumentError, TypeError
      nil
    end
  end
end
