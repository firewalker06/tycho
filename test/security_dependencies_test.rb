# frozen_string_literal: true

require "base64"
require "json"
require "openssl"
require "web_push"

module SecurityDependenciesTest
  module_function

  def run!
    assert(Gem.loaded_specs.fetch("jwt").version >= Gem::Version.new("3.2.0"),
           "expected a JWT release with the empty-key HMAC fix")
    assert_empty_hmac_key_is_rejected
    assert_web_push_vapid_signature
    puts "security_dependencies_test: ok"
  end

  def assert_empty_hmac_key_is_rejected
    header = Base64.urlsafe_encode64(JSON.generate(alg: "HS256"), padding: false)
    payload = Base64.urlsafe_encode64(JSON.generate(sub: "test-user"), padding: false)
    input = "#{header}.#{payload}"
    # Build the forged token without JWT.encode, which must also reject empty keys.
    signature = Base64.urlsafe_encode64(OpenSSL::HMAC.digest("SHA256", "", input), padding: false)
    token = "#{input}.#{signature}"
    ["", nil].each do |key|
      begin
        JWT.decode(token, nil, true, algorithms: ["HS256"]) { key }
      rescue JWT::DecodeError
        next
      end
      raise "expected JWT verification to reject an empty or nil HMAC lookup key"
    end
  end

  def assert_web_push_vapid_signature
    key = WebPush.generate_key
    request = WebPush::Request.new(
      subscription: { endpoint: "https://push.example.test/subscription" },
      vapid: key.to_h.merge(subject: "mailto:test@example.test")
    )
    authorization = request.headers.fetch("Authorization")
    token = authorization.match(/\Avapid t=([^,]+),k=/)[1]
    payload, header = JWT.decode(token, key.curve, true, algorithms: ["ES256"])
    assert(header.fetch("alg") == "ES256", "expected Web Push to sign with ES256")
    assert(payload.fetch("aud") == "https://push.example.test", "expected the push service audience")
    assert(payload.fetch("sub") == "mailto:test@example.test", "expected the VAPID subject")
    assert(payload.fetch("exp") > Time.now.to_i, "expected an unexpired VAPID token")
  end

  def assert(condition, message)
    raise message unless condition
  end
end

SecurityDependenciesTest.run!
