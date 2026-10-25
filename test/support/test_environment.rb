# frozen_string_literal: true

# Shared by bin/test and test/support/push_safety.rb. Keep this file free of
# gems so bin/test can load it before Bundler.
module TestEnvironment
  # Per-run variables that Tycho sets when it spawns a managed agent. A test
  # process that inherits them waits for the parent agent's release file or
  # acts as that agent. Tests that need one of these set it explicitly.
  INHERITED_RUN_VARIABLES = %w[
    TYCHO_AGENT_KEY
    TYCHO_AGENT_RUNNER_CONFIG
    TYCHO_AGENT_TYPE
    TYCHO_EXECUTABLE
    TYCHO_LAUNCH_OWNER_PID
    TYCHO_MEMORY_PATH
    TYCHO_NATIVE_ACK_DELEGATED
    TYCHO_NATIVE_OWNED_PATH
    TYCHO_NATIVE_RELEASE_PATH
    TYCHO_NATIVE_STARTED_PATH
    TYCHO_PID_PATH
    TYCHO_PROCESS_NAME_BOOTSTRAPPED
    TYCHO_RAW_LOG_PATH
    TYCHO_RUN_ID
    TYCHO_SLEEP_INCIDENT_PATH
    TYCHO_STATUS_PATH
    TYCHO_STREAM_RECORDER_PATH
  ].freeze

  # Config-path overrides an operator may have set. bin/test never inherits them.
  CONFIG_OVERRIDES = %w[
    TYCHO_CONFIG_DIR
    TYCHO_CONFIG_PATH
    TYCHO_SYSTEM_PROMPTS_PATH
    TYCHO_RESPONSE_STYLE_PATH
    TYCHO_SCHEDULES_PATH
    TYCHO_SCHEDULES_ROOT
  ].freeze

  BROAD_PROCESS_KILLERS = [["pk", "ill"].join, ["kill", "all"].join].freeze

  # Environment overrides for one bin/test command. A nil value removes the
  # variable from the child process.
  def self.command_env(home)
    cleared = (INHERITED_RUN_VARIABLES + CONFIG_OVERRIDES).to_h { |name| [name, nil] }
    cleared.merge("TYCHO_LOGS_ROOT" => File.join(home, "logs"), "TYCHO_HOME" => home)
  end

  def self.clear_inherited_run_variables!
    INHERITED_RUN_VARIABLES.each { |name| ENV.delete(name) }
  end

  def self.broad_process_killer_files(root)
    files = Dir.glob(File.join(root, "bin", "*")) + Dir.glob(File.join(root, "test", "**", "*"))
    expression = /\b(?:#{BROAD_PROCESS_KILLERS.join("|")})\b/
    files.select { |path| File.file?(path) && File.read(path).match?(expression) }
  end
end
