# frozen_string_literal: true

require "base64"
require "json"
require "openssl"
require "securerandom"
require "fileutils"

require_relative "constants"
require_relative "file_store"

module HQ
  class AgentCapability
    DEFAULT_TTL = 6 * 60 * 60
    VERSION = 1

    Actor = Struct.new(:type, :agent_key, :run_id, keyword_init: true) do
      def user? = type == "user"
      def agent? = type == "agent"
    end

    class Error < ArgumentError; end

    def self.user_actor
      Actor.new(type: "user")
    end

    def initialize(path: AGENT_CAPABILITY_FILE, ttl: DEFAULT_TTL)
      @path = path
      @ttl = ttl
    end

    def issue(agent_key:, run_id:, now: Time.now)
      payload = {
        "v" => VERSION,
        "agent_key" => required_value(agent_key, "agent key"),
        "run_id" => required_value(run_id, "run id"),
        "issued_at" => now.to_i,
        "expires_at" => now.to_i + @ttl,
        "nonce" => SecureRandom.hex(16)
      }
      encoded = encode(JSON.generate(payload))
      "#{encoded}.#{signature(encoded)}"
    end

    def verify(token, now: Time.now)
      encoded, supplied_signature = token.to_s.split(".", 2)
      raise Error, "Missing agent capability" if encoded.to_s.empty? || supplied_signature.to_s.empty?

      expected_signature = signature(encoded)
      valid = supplied_signature.bytesize == expected_signature.bytesize &&
              OpenSSL.fixed_length_secure_compare(supplied_signature, expected_signature)
      raise Error, "Invalid agent capability" unless valid

      payload = JSON.parse(Base64.urlsafe_decode64(encoded))
      raise Error, "Unsupported agent capability" unless payload["v"] == VERSION
      raise Error, "Agent capability expired" if payload["expires_at"].to_i <= now.to_i

      Actor.new(
        type: "agent",
        agent_key: required_value(payload["agent_key"], "agent key"),
        run_id: required_value(payload["run_id"], "run id")
      )
    rescue JSON::ParserError, ArgumentError => e
      raise e if e.is_a?(Error)

      raise Error, "Invalid agent capability"
    end

    private

    def signature(encoded)
      OpenSSL::HMAC.hexdigest("SHA256", secret, encoded)
    end

    def secret
      FileUtils.mkdir_p(File.dirname(@path))
      File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        payload = FileStore.read_json(@path, fallback: {})
        value = payload["secret"].to_s
        return value unless value.empty?

        value = SecureRandom.hex(32)
        FileStore.write_json(@path, { "secret" => value, "created_at" => Time.now.utc.iso8601 })
        File.chmod(0o600, @path)
        value
      ensure
        lock.flock(File::LOCK_UN)
      end
    end

    def encode(value)
      Base64.urlsafe_encode64(value, padding: false)
    end

    def required_value(value, label)
      text = value.to_s.strip
      raise Error, "Missing #{label}" if text.empty?

      text
    end
  end
end
