agent_key = ENV.fetch("TYCHO_AGENT_KEY")
Process.setproctitle("tycho agent-runner #{agent_key}") if Process.respond_to?(:setproctitle)

begin
  File.write(ENV.fetch("TYCHO_PID_PATH"), Process.pid.to_s)
rescue StandardError
  nil
end
release_path = ENV["TYCHO_NATIVE_RELEASE_PATH"].to_s
owned_path = ENV["TYCHO_NATIVE_OWNED_PATH"].to_s
launch_owner_pid = ENV["TYCHO_LAUNCH_OWNER_PID"].to_i
launch_abandoned = false
until release_path.empty? || File.exist?(release_path)
  unless owned_path.empty? || File.exist?(owned_path)
    begin
      Process.kill(0, launch_owner_pid)
    rescue Errno::ESRCH, Errno::EPERM
      launch_abandoned = true
      break
    end
  end
  sleep 0.01
end
status = if launch_abandoned
           125
         else
           begin
             recorder_path = ENV["TYCHO_STREAM_RECORDER_PATH"].to_s
             if !recorder_path.empty? && !ENV["TYCHO_MEMORY_PATH"].to_s.empty?
               require recorder_path
               HQ::AgentStreamRecorder.run(
                 command: ARGV,
                 input: STDIN,
                 raw_log_path: ENV.fetch("TYCHO_RAW_LOG_PATH"),
                 memory_path: ENV.fetch("TYCHO_MEMORY_PATH"),
                 agent_type: ENV.fetch("TYCHO_AGENT_TYPE"),
                 run_id: ENV.fetch("TYCHO_RUN_ID"),
                 incident_path: ENV["TYCHO_SLEEP_INCIDENT_PATH"],
                 native_started_path: ENV["TYCHO_NATIVE_ACK_DELEGATED"] == "1" ? nil :
                   ENV["TYCHO_NATIVE_STARTED_PATH"]
               )
             else
               result = system(*ARGV)
               child = $?
               if result.nil?
                 warn "failed to execute #{ARGV.first.inspect} (exit 127)"
                 127
               elsif child&.signaled?
                 128 + child.termsig.to_i
               else
                 child ? child.exitstatus.to_i : (result ? 0 : 1)
               end
             end
           rescue SystemCallError => e
             warn e.message
             127
           rescue StandardError => e
             warn e.message
             1
           end
         end
# A separate receipt proves this time was observed by the still-live
# native wrapper. Monitor fallback status writes do not produce it.
begin
  exit_path = "#{ENV.fetch("TYCHO_STATUS_PATH")}.native-exit"
  exit_temporary = "#{exit_path}.tmp-#{Process.pid}"
  File.write(exit_temporary, [ENV.fetch("TYCHO_RUN_ID"), Time.now.to_r.to_s].join("\n"))
  File.rename(exit_temporary, exit_path)
rescue StandardError
  nil
ensure
  File.delete(exit_temporary) if exit_temporary && File.exist?(exit_temporary)
end
begin
  path = ENV.fetch("TYCHO_STATUS_PATH")
  temporary_path = "#{path}.tmp-#{Process.pid}"
  File.write(temporary_path, status.to_s)
  File.rename(temporary_path, path)
rescue StandardError
  nil
ensure
  File.delete(temporary_path) if temporary_path && File.exist?(temporary_path)
end
begin
  executable = ENV.fetch("TYCHO_EXECUTABLE")
  agent_key = ENV.fetch("TYCHO_AGENT_KEY")
  ruby = File.executable?(RbConfig.ruby) ? RbConfig.ruby : "ruby"
  system(ruby, executable, "agent", "finalize", agent_key, out: File::NULL, err: File::NULL)
rescue StandardError
  nil
end
exit(status)
