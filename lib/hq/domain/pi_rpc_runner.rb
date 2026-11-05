# frozen_string_literal: true

require "json"
require "timeout"

module HQ
  # Adapt one managed turn to Pi's persistent JSONL RPC process. The shared
  # prompt transport supplies stdin; no prompt enters argv, env, or a temp file.
  class PiRpcRunner
    SHUTDOWN_TIMEOUT = 5
    STOP_TIMEOUT = 2

    def self.run(command, input: $stdin, output: $stdout)
      new(command, input:, output:).run
    end

    def initialize(command, input:, output:)
      @command = command
      @input = input
      @output = output
    end

    def run
      %w[TERM INT].each { |signal| Signal.trap(signal) { raise Interrupt } }
      @input.binmode
      @output.binmode
      prompt = @input.read.force_encoding(Encoding::UTF_8)
      @stream, child_output = IO.pipe
      child_input, @writer = IO.pipe
      @stream.binmode
      @writer.binmode
      @writer.sync = true
      pid = Process.spawn(*@command, in: child_input, out: child_output)
      child_input.close
      child_output.close
      send_request("id" => "tycho-state", "type" => "get_state")
      completed = false
      agent_started = false
      @stream.each_line do |line|
        forward(line)
        event = JSON.parse(line.dup.force_encoding(Encoding::UTF_8))
        if event["type"] == "response" && event["id"] == "tycho-state"
          raise "Pi RPC session state unavailable" unless event["success"] && !event.dig("data", "sessionId").to_s.empty?

          # Keep the session event contract used by the recorder and correction runner.
          forward(json_line("type" => "session", "id" => event.dig("data", "sessionId")))
          send_request("id" => "tycho-prompt", "type" => "prompt", "message" => prompt)
        elsif event["type"] == "response" && event["id"] == "tycho-prompt"
          raise "Pi RPC rejected the prompt" unless event["success"]

          # Input extensions can handle a prompt without starting an agent or
          # emitting agent_settled. Query after acceptance, not during preflight.
          send_request("id" => "tycho-completion", "type" => "get_state")
        elsif event["type"] == "agent_start"
          agent_started = true
        elsif event["type"] == "response" && event["id"] == "tycho-completion"
          raise "Pi RPC completion state unavailable" unless event["success"]

          state = event.fetch("data")
          completed = !agent_started && state["isStreaming"] == false &&
                      state["isCompacting"] == false && state["pendingMessageCount"] == 0
        elsif event["type"] == "agent_settled"
          completed = true
        end
        break if completed
      rescue JSON::ParserError
        # Preserve diagnostics in the raw stream.
        next
      end

      # EOF is Pi's shutdown request. Bound both stdout draining and waitpid:
      # a child can keep either its output or its process open after the turn.
      @writer.close
      status = Timeout.timeout(SHUTDOWN_TIMEOUT) do
        @stream.each_line { |line| forward(line) }
        Process.wait2(pid).last
      end
      pid = nil
      completed ? (status.exitstatus || 1) : 1
    rescue Interrupt
      130
    rescue StandardError => e
      warn "Tycho Pi RPC runner failed: #{e.class}: #{e.message}"
      1
    ensure
      [child_input, child_output, @writer, @stream].each { |io| io&.close unless io&.closed? }
      stop_child(pid) if pid
    end

    private

    def json_line(event)
      JSON.generate(event).encode(Encoding::UTF_8).b + "\n".b
    end

    def send_request(event)
      @writer.write(json_line(event))
    end

    def forward(line)
      @output.write(line.b)
      @output.flush
    end

    def stop_child(pid)
      %w[TERM KILL].each do |signal|
        begin
          return if Process.waitpid(pid, Process::WNOHANG)

          Process.kill(signal, pid)
          Timeout.timeout(STOP_TIMEOUT) { Process.wait(pid) }
          return
        rescue Timeout::Error
          next
        rescue Errno::ESRCH, Errno::ECHILD
          return
        end
      end
      warn "Tycho Pi RPC child did not exit within the stop timeout"
    end
  end
end

exit(HQ::PiRpcRunner.run(ARGV)) if $PROGRAM_NAME == __FILE__
