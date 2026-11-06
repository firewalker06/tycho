# frozen_string_literal: true

require_relative "custom_prompt_files"

# The wrapper receives a path, never prompt text, in its argument list.
# The private directory and file live only for this owned child.
if ARGV.first == "--tycho-prompt-root"
  ARGV.shift
  HQ::CustomPromptFiles.root = ARGV.shift
end

directory = nil
pid = nil
status = nil
lease = nil
begin
  %w[TERM INT HUP].each { |signal| Signal.trap(signal) { exit(128 + Signal.list.fetch(signal)) } }
  HQ::CustomPromptFiles.recover!
  directory, lease = HQ::CustomPromptFiles.create
  path = File.join(directory, "prompt")
  File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.binmode
    IO.copy_stream(STDIN.binmode, file)
  end
  release_reader, release_writer = IO.pipe
  pid = Process.fork do
    %w[TERM INT HUP].each { |signal| Signal.trap(signal, "DEFAULT") }
    release_writer.close
    # Publish ownership before a wrapper can exec and close inherited locks.
    exit! 1 unless release_reader.read(1) == "1"
    release_reader.close
    begin
      exec(*ARGV, "--tycho-prompt-file", path, in: File::NULL, lease.fileno => lease)
    rescue SystemCallError => error
      warn error.message
      exit! 127
    end
  end
  release_reader.close
  HQ::CustomPromptFiles.record_child(directory, pid)
  release_writer.write("1")
  release_writer.close
  _, status = Process.wait2(pid)
  exit(status.exitstatus || 1)
ensure
  if pid && !status
    begin
      Process.kill("KILL", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
  release_reader&.close unless release_reader&.closed?
  release_writer&.close unless release_writer&.closed?
  HQ::CustomPromptFiles.remove(directory) if directory
  lease&.close
end
