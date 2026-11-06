# frozen_string_literal: true

require "tmpdir"

# The wrapper receives a path, never prompt text, in its argument list.
# The private directory and file live only for this owned child.
directory = nil
pid = nil
status = nil
begin
  %w[TERM INT HUP].each { |signal| Signal.trap(signal) { exit(128 + Signal.list.fetch(signal)) } }
  directory = Dir.mktmpdir("tycho-custom-prompt-")
  path = File.join(directory, "prompt")
  File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.binmode
    IO.copy_stream(STDIN.binmode, file)
  end
  pid = Process.spawn(*ARGV, "--tycho-prompt-file", path, in: File::NULL)
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
  if directory
    File.unlink(File.join(directory, "prompt")) if File.exist?(File.join(directory, "prompt"))
    Dir.rmdir(directory)
  end
end
