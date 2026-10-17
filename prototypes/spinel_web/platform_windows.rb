# frozen_string_literal: true

# The build supplies the static library path. No helper DLL is distributed.
module PrototypeWindows
  ffi_lib "tycho_windows"
  ffi_lib "advapi32"
  ffi_lib "shell32"
  ffi_func :tycho_private_directory, [:str], :int
  ffi_func :tycho_private_file, [:str], :int
  ffi_func :tycho_worker_job, [], :int
  ffi_func :tycho_executable, [], :str
  ffi_func :tycho_argument, [:int], :str
end

module PrototypePlatform
  def self.codex_options
    ["-c", "windows.sandbox=\"elevated\""]
  end

  def self.prepare(root)
    raise "Cannot create or verify private Windows state" unless PrototypeWindows.tycho_private_directory(root) == 0
    ["lock", "access-token", "run.json", "run.json.tmp", "events.jsonl", "result.txt"].each do |name|
      raise "Unsafe Windows state file" unless PrototypeWindows.tycho_private_file(File.join(root, name)) == 0
    end
  end

  def self.spawn(environment, command, workspace, log)
    Process.spawn(environment, PrototypeWindows.tycho_executable, "--agent-worker", *command,
                  chdir: workspace, in: File::NULL, out: log, err: [:child, :out])
  end

  def self.signal(pid, signal)
    # Windows has no POSIX TERM grace. Closing the worker's job kills its tree.
    Process.kill("KILL", pid) if signal == "TERM"
  end
end

if ARGV[0] == "--agent-worker"
  raise "Cannot contain Windows agent process" unless PrototypeWindows.tycho_worker_job == 0
  command = []
  index = 2
  while index <= ARGV.length
    command << PrototypeWindows.tycho_argument(index)
    index += 1
  end
  child = Process.spawn(*command)
  exit Process.waitpid2(child)[1].exitstatus.to_i
end
