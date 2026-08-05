# frozen_string_literal: true

require "json"
require "net/http"
require "tmpdir"

require_relative "../lib/hq/domain/push_subscription_store"
require_relative "../lib/hq/domain/web_push_notifier"

module WebPushNotifierTest
  module_function

  ENDPOINT = "https://wns2-pn1p.notify.windows.com/subscription/expired"

  def run!
    assert_success_records_provider_response
    assert_expired_subscription_is_disabled
    assert_transient_failure_remains_enabled
    puts "web_push_notifier_test: ok"
  end

  def assert_success_records_provider_response
    with_notifier do |notifier, store|
      with_web_push_response(Net::HTTPCreated, "201", "Created") do
        result = notifier.send_test!(endpoint: ENDPOINT)
        subscription = store.enabled.fetch(0)

        assert(result == { sent: 1, failed: 0, attempted: 1, disabled: 0 },
               "expected the provider-accepted send to succeed")
        assert(subscription["last_response_code"] == 201,
               "expected the accepted provider response code to be persisted")
        assert(!subscription["last_accepted_at"].to_s.empty?,
               "expected provider acceptance time to be persisted")
        assert(subscription["failure_count"].zero?, "expected provider acceptance to clear failures")
      end
    end
  end

  def assert_expired_subscription_is_disabled
    with_notifier do |notifier, store|
      with_web_push_error(WebPush::ExpiredSubscription, Net::HTTPGone, "410", "Gone") do
        result = notifier.send_test!(endpoint: ENDPOINT)

        assert(result == { sent: 0, failed: 1, attempted: 1, disabled: 1 },
               "expected the expired send to fail once and retire the endpoint, got #{result.inspect}")
        assert(store.enabled.empty?, "expected an expired Windows push endpoint to be disabled")
        subscription = store.all.fetch(0)
        assert(subscription["last_response_code"] == 410,
               "expected the permanent provider response code to be persisted")
        assert(subscription["last_error_class"] == "WebPush::ExpiredSubscription",
               "expected the permanent provider error class to be persisted")
      end
    end
  end

  def assert_transient_failure_remains_enabled
    with_notifier do |notifier, store|
      with_web_push_error(WebPush::PushServiceError, Net::HTTPServiceUnavailable, "503", "Service Unavailable") do
        result = notifier.send_test!(endpoint: ENDPOINT)
        subscription = store.enabled.fetch(0)

        assert(result == { sent: 0, failed: 1, attempted: 1, disabled: 0 },
               "expected the transient send to fail once")
        assert(subscription["failure_count"] == 1, "expected a transient failure to remain retryable")
        assert(subscription["last_response_code"] == 503,
               "expected the transient provider response code to be persisted")
      end
    end
  end

  def with_notifier
    Dir.mktmpdir("hq-web-push-notifier-test") do |dir|
      subscriptions_path = File.join(dir, "push_subscriptions.json")
      vapid_path = File.join(dir, "web_push_vapid.json")
      store = HQ::PushSubscriptionStore.new(path: subscriptions_path)
      store.save_subscription(
        {
          "endpoint" => ENDPOINT,
          "keys" => { "p256dh" => "p256dh-key", "auth" => "auth-key" }
        },
        user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Edg/148.0.0.0"
      )
      notifier = HQ::WebPushNotifier.new(subscription_store: store, vapid_path: vapid_path)
      yield notifier, store
    end
  end

  def with_web_push_error(error_class, response_class, code, message)
    original = WebPush.method(:payload_send)
    response = response_class.new("1.1", code, message)
    response.instance_variable_set(:@body, "")
    response.instance_variable_set(:@read, true)
    WebPush.define_singleton_method(:payload_send) do |**_options|
      raise error_class.new(response, "wns2-pn1p.notify.windows.com")
    end
    yield
  ensure
    WebPush.define_singleton_method(:payload_send, original)
  end

  def with_web_push_response(response_class, code, message)
    original = WebPush.method(:payload_send)
    response = response_class.new("1.1", code, message)
    response.instance_variable_set(:@body, "")
    response.instance_variable_set(:@read, true)
    WebPush.define_singleton_method(:payload_send) { |**_options| response }
    yield
  ensure
    WebPush.define_singleton_method(:payload_send, original)
  end

  def assert(condition, message)
    raise message unless condition
  end
end

WebPushNotifierTest.run! if $PROGRAM_NAME == __FILE__
