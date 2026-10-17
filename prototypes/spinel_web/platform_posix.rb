# frozen_string_literal: true

module PrototypePlatform
  def self.codex_options
    []
  end

  def self.prepare(root)
    Dir.mkdir(root, 0o700) unless File.exist?(root)
    raise "State must be a private directory owned by this user" if File.symlink?(root) || !File.directory?(root) || File.stat(root).uid != Process.uid || (File.stat(root).mode & 0o077) != 0
  end

  def self.spawn(environment, command, workspace, log)
    Process.spawn(environment, *command, chdir: workspace,
                  in: File::NULL, out: log, err: [:child, :out], pgroup: true)
  end

  def self.signal(pid, signal)
    Process.kill(signal, -pid)
  end
end
