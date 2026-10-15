# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "web_push"
require "json"

# Load before HQ constants. Never inherit an operator's logs root in tests.
module TestPushSafety
  LOGS_ROOT = Dir.mktmpdir("tycho-test-push-")
  ENV["TYCHO_LOGS_ROOT"] = LOGS_ROOT
  ENV["TYCHO_HOME"] = File.join(LOGS_ROOT, "home")
  BLOCKED_ATTEMPTS = []
  %w[WEB_PUSH_VAPID_PUBLIC_KEY WEB_PUSH_VAPID_PRIVATE_KEY WEB_PUSH_VAPID_SUBJECT].each { |key| ENV.delete(key) }
  at_exit do
    if (audit = ENV["TYCHO_TEST_PUSH_AUDIT_FILE"]) && !audit.empty?
      File.open(audit, "a") do |file|
        file.flock(File::LOCK_EX)
        file.puts(JSON.generate(pid: Process.pid, blocked_attempts: BLOCKED_ATTEMPTS.length))
      end
    end
    FileUtils.remove_entry(LOGS_ROOT) if File.directory?(LOGS_ROOT)
    unless BLOCKED_ATTEMPTS.empty?
      warn "Forbidden real Web Push transport attempts: #{BLOCKED_ATTEMPTS.length}"
      exit 1
    end
  end

  class NetworkDeliveryBlocked < StandardError; end

  class Notifier
    attr_reader :payloads

    def initialize
      @payloads = []
    end

    def send_payload!(payload, **_options)
      @payloads << payload
      { sent: 0, failed: 0, attempted: 0, disabled: 0 }
    end
  end
end

# Delivery contract tests can replace this method with their explicit fake.
WebPush.define_singleton_method(:payload_send) do |**_options|
  TestPushSafety::BLOCKED_ATTEMPTS << true
  raise TestPushSafety::NetworkDeliveryBlocked, "Real Web Push delivery is forbidden in tests"
end
