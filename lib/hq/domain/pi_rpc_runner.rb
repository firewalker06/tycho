# frozen_string_literal: true

require "json"
require "timeout"

module HQ
  # Adapt one managed turn to Pi's persistent JSONL RPC process. The shared
  # prompt transport supplies stdin; no prompt enters argv, env, or a temp file.
  class PiRpcRunner
    def self.run(command, input: $stdin, output: $stdout)
      new(command, input:, output:).run
    end

    def initialize(command, input:, output:)
      @command = command
      @input = input
      @output = output
    end

    def run
      prompt = @input.read
      stream, child_output = IO.pipe
      child_input, writer = IO.pipe
      pid = Process.spawn(*@command, in: child_input, out: child_output)
      child_input.close
      child_output.close
      %w[TERM INT].each { |signal| Signal.trap(signal) { raise Interrupt } }
      writer.sync = true
      writer.puts(JSON.generate("id" => "tycho-state", "type" => "get_state"))
      settled = false
      stream.each_line do |line|
        @output.write(line)
        @output.flush
        event = JSON.parse(line)
        if event["type"] == "response" && event["id"] == "tycho-state"
          raise "Pi RPC session state unavailable" unless event["success"] && !event.dig("data", "sessionId").to_s.empty?

          # Keep the session event contract used by the recorder and correction runner.
          @output.puts(JSON.generate("type" => "session", "id" => event.dig("data", "sessionId")))
          @output.flush
          writer.puts(JSON.generate("id" => "tycho-prompt", "type" => "prompt", "message" => prompt))
        elsif event["type"] == "response" && event["id"] == "tycho-prompt" && !event["success"]
          raise "Pi RPC rejected the prompt"
        elsif event["type"] == "agent_settled"
          settled = true
          writer.close # EOF requests Pi's normal shutdown after session persistence.
        end
      rescue JSON::ParserError
        # Preserve diagnostics in the raw stream.
        next
      end
      _, status = Process.wait2(pid)
      pid = nil
      settled ? (status.exitstatus || 1) : 1
    rescue Interrupt
      130
    rescue StandardError => e
      warn "Tycho Pi RPC runner failed: #{e.class}: #{e.message}"
      1
    ensure
      [child_input, child_output, writer, stream].each { |io| io&.close unless io&.closed? }
      if pid
        begin
          Process.kill("TERM", pid)
          Timeout.timeout(5) { Process.wait(pid) }
        rescue Timeout::Error
          Process.kill("KILL", pid)
          Process.wait(pid)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end
      end
    end
  end
end

exit(HQ::PiRpcRunner.run(ARGV)) if $PROGRAM_NAME == __FILE__
