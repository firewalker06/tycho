# frozen_string_literal: true

require_relative "support/push_safety"
require_relative "../lib/hq/remote_server"

raise "subscription storage escaped" unless HQ::PUSH_SUBSCRIPTIONS_FILE.start_with?("#{TestPushSafety::LOGS_ROOT}/")
raise "VAPID storage escaped" unless HQ::WEB_PUSH_VAPID_FILE.start_with?("#{TestPushSafety::LOGS_ROOT}/")
begin
  WebPush.payload_send
  raise "network transport was not blocked"
rescue TestPushSafety::NetworkDeliveryBlocked
  # This intentional probe is the only allowed denial in this test.
  raise "missing denial capture" unless TestPushSafety::BLOCKED_ATTEMPTS.length == 1
  TestPushSafety::BLOCKED_ATTEMPTS.clear
end

attempts = []
original = HQ::WebPushNotifier.instance_method(:send_payload!)
HQ::WebPushNotifier.define_method(:send_payload!) do |payload, **_options|
  attempts << payload
  { sent: 0, failed: 0, attempted: 0, disabled: 0 }
end
begin
  # Exercise the actual fixture call site, even when its other constants change.
  load File.join(__dir__, "context_replacement_recovery_test.rb")
  raise "fixture used real notifier: #{attempts.length} calls" unless attempts.empty?
ensure
  HQ::WebPushNotifier.define_method(:send_payload!, original)
end
puts "push_safety_test: ok"
