# frozen_string_literal: true

module HQ
  module AgentPromptTransport
    module_function

    # Write concurrently so a large prompt cannot block launch or stdout reads.
    # The reader belongs to the caller; closing it also releases a blocked writer.
    def input(data)
      return nil if data.nil?

      reader, writer = IO.pipe
      Thread.new do
        begin
          writer.binmode
          writer.write(data.b)
        rescue Errno::EPIPE, IOError
          # The harness can exit or be cancelled before it reads the prompt.
          nil
        ensure
          writer.close unless writer.closed?
        end
      end
      reader
    end
  end
end
