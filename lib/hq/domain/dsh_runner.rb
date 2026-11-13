# frozen_string_literal: true

require "json"
require "tempfile"

module HQ
  # dsh model selection is a profile overlay, not a headless command flag.
  # Keep this file invocation-local; never edit the operator's profile.
  module DshRunner
    PATCH_PLACEHOLDER = "__TYCHO_DSH_PATCH__"

    module_function

    def run(arguments)
      model, effort, *command = arguments
      selection = { "provider" => "deepseek-official", "model" => model }
      selection["reasoningEffort"] = effort unless effort.to_s.empty?
      Tempfile.create(["tycho-dsh-", ".json"]) do |patch|
        patch.chmod(0o600)
        patch.write(JSON.generate([{ "id" => "agent-default-model", "config" => selection }]))
        patch.flush
        argv = command.map { |argument| argument == PATCH_PLACEHOLDER ? patch.path : argument }
        reader, writer = IO.pipe
        pid = Process.spawn(*argv, in: $stdin, out: writer, err: $stderr)
        writer.close
        session_id = nil
        final = nil
        stream_error = false
        reader.each_line do |line|
          $stdout.write(line)
          $stdout.flush
          event = begin
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
          next unless event.is_a?(Hash)

          case event["type"]
          when "session"
            session_id = event["sessionId"]
            final = nil
          when "final"
            final = event
          when "error"
            stream_error = true
          end
        end
        _pid, status = Process.wait2(pid)
        return status.exitstatus || 1 unless status.success?

        completed = !stream_error && session_id.is_a?(String) && !session_id.empty? &&
                    final.is_a?(Hash) && final["sessionId"] == session_id && final.dig("reason", "kind") == "completed"
        warn "DeepSeek Harness ended without a completed final event for this session" unless completed
        completed ? 0 : 1
      ensure
        writer&.close unless writer&.closed?
        reader&.close unless reader&.closed?
        Process.wait(pid) if pid && !status
      end
    end
  end
end

exit HQ::DshRunner.run(ARGV) if $PROGRAM_NAME == __FILE__
