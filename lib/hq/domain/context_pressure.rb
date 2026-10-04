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
      File.foreach(@agent.raw_log_path).each_with_index.filter_map do |line, event_index|
        run_index += 1 if line.start_with?("=== [") && line.include?(" start")
        text = line.to_s.strip
        next unless text.start_with?("{")

        event = JSON.parse(text)
        { "event" => event, "run_index" => run_index, "event_index" => event_index }
      rescue JSON::ParserError
        nil
      end
    end

    def best_signal(evidence)
      signals = evidence.filter_map do |entry|
        event = entry.fetch("event")
        signal = measured_context_signal(event) || compaction_signal(event) || overflow_signal(event)
        signal&.merge(
          "run_index" => entry.fetch("run_index"),
          "event_index" => entry.fetch("event_index")
        )
      end
      signal = signals.max_by { |candidate| candidate.fetch("event_index", -1) }
      return unless signal

      signal = classify_measurement(signal) if signal["source"] == "harness_context_window"

      latest_run_index = evidence.map { |entry| entry.fetch("run_index", -1) }.max || -1
      if signal["source"] == "harness_context_window" && signal.fetch("run_index", -1) < latest_run_index
        return signal.merge(
          "state" => "stale",
          "level" => "none",
          "summary" => "Context telemetry is stale",
          "detail" => "A later run did not report active-context telemetry. Tycho will not reuse the older percentage as a warning.",
          "stale" => true,
          "warning" => false
        ).except("run_index", "event_index")
      end

      signal.merge("stale" => false).except("run_index", "event_index")
    end

    def measured_context_signal(event)
      info = if event["type"] == "event_msg" && event.dig("payload", "type") == "token_count"
               event.dig("payload", "info")
             elsif event["type"] == "token_count"
               event["info"] || event
             end
      return unless info.is_a?(Hash)

      used = number(info.dig("last_token_usage", "total_tokens") || info["context_tokens"])
      limit = number(info["model_context_window"] || info["context_window"])
      return unless used && limit&.positive?

      utilization = used / limit

      {
        "basis" => "measured",
        "detail" => "The harness reported #{format_percentage(utilization)} active-context usage.",
        "used_tokens" => used.to_i,
        "limit_tokens" => limit.to_i,
        "utilization" => utilization,
        "source" => "harness_context_window"
      }
    end

    def classify_measurement(signal)
      ratio = signal.fetch("utilization")
      level = if ratio >= CRITICAL_RATIO
                "critical"
              elsif ratio >= WARNING_RATIO
                "warning"
              else
                "none"
              end
      summary = if level == "critical"
                  "Context is almost full"
                elsif level == "warning"
                  "Context pressure is high"
                else
                  "Context pressure is low"
                end
      signal.merge(
        "state" => level == "none" ? "normal" : level,
        "level" => level,
        "summary" => summary,
        "warning" => level != "none"
      )
    end

    def compaction_signal(event)
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
        "source" => "harness_compaction"
      }
    end

    def overflow_signal(event)
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
        "source" => "harness_overflow"
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

    def format_percentage(ratio)
      rounded = (ratio * 100).round(1)
      value = rounded == rounded.to_i ? rounded.to_i : rounded
      "#{value}%"
    end
  end
end
