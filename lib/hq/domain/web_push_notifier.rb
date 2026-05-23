# frozen_string_literal: true

require "json"
require "digest"
require "web_push"

require_relative "constants"
require_relative "push_subscription_store"

module HQ
  class WebPushNotifier
    DEFAULT_SUBJECT = "mailto:tycho@example.com"
    VAPID_EXPIRATION_SECONDS = 12 * 60 * 60

    def initialize(subscription_store: PushSubscriptionStore.new, vapid_path: WEB_PUSH_VAPID_FILE)
      @subscription_store = subscription_store
      @vapid_path = vapid_path
    end

    def config
      keys = vapid_keys
      {
        configured: !keys[:public_key].to_s.empty? && !keys[:private_key].to_s.empty?,
        public_key: keys[:public_key],
        subject: subject,
        subscription_count: @subscription_store.count
      }
    end

    def send_test!(endpoint: nil)
      HQ.logger.debug("Push") do
        push_config = config
        "Preparing test push endpoint=#{endpoint_label(endpoint)} " \
          "configured=#{push_config.fetch(:configured)} subscriptions=#{push_config.fetch(:subscription_count)}"
      end
      payload = {
        title: "Tycho",
        body: "Test notification from Tycho.",
        tag: "hq:test",
        url: "/#setup"
      }
      send_payload!(payload, endpoint: endpoint, urgency: "normal", ttl: 120)
    end

    def send_payload!(payload, endpoint: nil, urgency: "normal", ttl: 600)
      subscriptions = @subscription_store.enabled
      enabled_count = subscriptions.length
      unless endpoint.to_s.empty?
        subscriptions = subscriptions.select { |subscription| subscription["endpoint"] == endpoint.to_s }
      end
      HQ.logger.debug("Push") do
        "Push send payload tag=#{payload[:tag] || payload["tag"]} title=#{payload[:title] || payload["title"]} " \
          "endpoint=#{endpoint_label(endpoint)} enabled=#{enabled_count} matched=#{subscriptions.length} " \
          "urgency=#{urgency} ttl=#{ttl}"
      end
      return { sent: 0, failed: 0, attempted: 0 } if subscriptions.empty?

      attempted = 0
      sent = 0
      failed = 0
      subscriptions.each do |subscription|
        attempted += 1
        if deliver(subscription, payload, urgency: urgency, ttl: ttl)
          sent += 1
        else
          failed += 1
        end
      end
      HQ.logger.debug("Push") { "Push send complete attempted=#{attempted} sent=#{sent} failed=#{failed}" }
      { sent: sent, failed: failed, attempted: attempted }
    end

    private

    def deliver(subscription, payload, urgency:, ttl:)
      message = JSON.generate(payload)
      keys = vapid_keys
      HQ.logger.debug("Push") do
        "Delivering push endpoint=#{endpoint_label(subscription["endpoint"])} " \
          "host=#{endpoint_host(subscription["endpoint"])} subscription_id=#{subscription["id"]} " \
          "p256dh=#{presence_label(subscription["p256dh"])}(#{subscription["p256dh"].to_s.length}) " \
          "auth=#{presence_label(subscription["auth"])}(#{subscription["auth"].to_s.length}) " \
          "failure_count=#{subscription["failure_count"].to_i} " \
          "user_agent=#{truncate_debug(subscription["user_agent"], 120)} " \
          "payload_bytes=#{message.bytesize} urgency=#{urgency} ttl=#{ttl} vapid_subject=#{subject} " \
          "vapid_audience=#{endpoint_origin(subscription["endpoint"])} " \
          "vapid_expiration_seconds=#{VAPID_EXPIRATION_SECONDS} " \
          "vapid_public_key=#{presence_label(keys[:public_key])} " \
          "vapid_private_key=#{presence_label(keys[:private_key])}"
      end
      WebPush.payload_send(
        message: message,
        endpoint: subscription.fetch("endpoint"),
        p256dh: subscription.fetch("p256dh"),
        auth: subscription.fetch("auth"),
        vapid: {
          subject: subject,
          public_key: keys.fetch(:public_key),
          private_key: keys.fetch(:private_key),
          expiration: VAPID_EXPIRATION_SECONDS
        },
        ttl: ttl,
        urgency: urgency,
        ssl_timeout: 5,
        open_timeout: 5,
        read_timeout: 5
      )
      HQ.logger.debug("Push") { "Push delivered endpoint=#{endpoint_label(subscription["endpoint"])}" }
      true
    rescue StandardError => e
      @subscription_store.record_failure(subscription["endpoint"])
      HQ.logger.debug("Push") do
        "Push delivery failed endpoint=#{endpoint_label(subscription["endpoint"])} " \
          "host=#{endpoint_host(subscription["endpoint"])} #{push_failure_debug(e)}"
      end
      HQ.logger.warn("Push") { "Web push send failed: #{e.class} - #{e.message}" }
      false
    end

    def endpoint_label(endpoint)
      value = endpoint.to_s
      return "none" if value.empty?

      "sha256:#{Digest::SHA256.hexdigest(value)[0, 12]}"
    end

    def endpoint_host(endpoint)
      URI.parse(endpoint.to_s).host.to_s
    rescue URI::InvalidURIError
      "invalid"
    end

    def endpoint_origin(endpoint)
      uri = URI.parse(endpoint.to_s)
      return "invalid" if uri.scheme.to_s.empty? || uri.host.to_s.empty?

      "#{uri.scheme}://#{uri.host}"
    rescue URI::InvalidURIError
      "invalid"
    end

    def presence_label(value)
      value.to_s.empty? ? "missing" : "present"
    end

    def push_failure_debug(error)
      response = error.respond_to?(:response) ? error.response : nil
      response_detail = if response
                          "response_code=#{response.code} response_message=#{response.message.inspect} " \
                            "response_body=#{truncate_debug(response.body, 500)}"
                        else
                          "response_code=none"
                        end
      host = error.respond_to?(:host) ? error.host.to_s : ""
      backtrace = Array(error.backtrace).first.to_s
      cause = error.cause
      cause_detail = cause ? " cause=#{cause.class}: #{cause.message}" : ""
      "error=#{error.class}: #{error.message} response_host=#{host} #{response_detail} " \
        "backtrace=#{backtrace}#{cause_detail}"
    end

    def truncate_debug(value, length)
      text = value.to_s.gsub(/\s+/, " ").strip
      return "none" if text.empty?
      return text if text.length <= length

      "#{text[0, length - 3]}..."
    end

    def subject
      HQ.env_present("WEB_PUSH_VAPID_SUBJECT", DEFAULT_SUBJECT).to_s
    end

    def vapid_keys
      public_key = HQ.env_present("WEB_PUSH_VAPID_PUBLIC_KEY", "").to_s
      private_key = HQ.env_present("WEB_PUSH_VAPID_PRIVATE_KEY", "").to_s
      return { public_key: public_key, private_key: private_key } unless public_key.empty? || private_key.empty?

      persisted_vapid_keys
    end

    def persisted_vapid_keys
      if File.exist?(@vapid_path)
        parsed = JSON.parse(File.read(@vapid_path))
        return {
          public_key: parsed["public_key"].to_s,
          private_key: parsed["private_key"].to_s
        }
      end

      key = WebPush.generate_key
      payload = {
        "public_key" => key.public_key,
        "private_key" => key.private_key,
        "created_at" => Time.now.utc.iso8601
      }
      FileUtils.mkdir_p(File.dirname(@vapid_path))
      File.write(@vapid_path, JSON.pretty_generate(payload))
      { public_key: payload["public_key"], private_key: payload["private_key"] }
    rescue StandardError => e
      HQ.logger.warn("Push") { "Failed to load VAPID keys: #{e.class} - #{e.message}" }
      { public_key: "", private_key: "" }
    end
  end
end
