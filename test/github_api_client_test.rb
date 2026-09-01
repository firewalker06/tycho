# frozen_string_literal: true

require_relative "../lib/hq/domain/github_api_client"

module GitHubAPIClientTest
  module_function

  FakeResponse = Struct.new(:code, :body, :headers) do
    def each_header(&block)
      headers.each(&block)
    end
  end

  def run!
    assert_disabled_without_token
    assert_legacy_tycho_pat_is_ignored
    assert_direct_headers_and_rate_metadata
    assert_pagination_is_bounded
    assert_timeouts_are_sanitized
    assert_error_redaction_and_size_bound
    puts "github_api_client_test: ok"
  end

  def assert_disabled_without_token
    client = HQ::GitHubAPIClient.new(token: "")
    assert(!client.enabled?, "expected blank token to disable GitHub")
    begin
      client.get_json("/user")
      raise "expected disabled client to reject requests"
    rescue HQ::GitHubAPIClient::DisabledError => e
      assert(e.status == 424, "expected disabled capability status")
    end
  end

  def assert_legacy_tycho_pat_is_ignored
    credential = Class.new do
      def enabled?
        false
      end

      def capability(api_url:)
        { enabled: false, available: false, source: "none", api_url: }
      end
    end.new
    previous = ENV["TYCHO_GITHUB_TOKEN"]
    ENV["TYCHO_GITHUB_TOKEN"] = "legacy-token-must-not-be-used"
    client = HQ::GitHubAPIClient.new(credential:)
    assert(!client.enabled?, "expected TYCHO_GITHUB_TOKEN to have no effect")
  ensure
    previous.nil? ? ENV.delete("TYCHO_GITHUB_TOKEN") : ENV["TYCHO_GITHUB_TOKEN"] = previous
  end

  def assert_direct_headers_and_rate_metadata
    captured = nil
    transport = lambda do |uri, headers|
      captured = [uri, headers]
      FakeResponse.new("200", '{"login":"octocat"}', {
                         "etag" => "etag-1",
                         "x-ratelimit-limit" => "5000",
                         "x-ratelimit-remaining" => "4999"
                       })
    end
    response = HQ::GitHubAPIClient.new(token: "secret", transport:).get_json("/user", etag: "old")

    assert(captured[0].path == "/user", "expected a direct REST request")
    assert(captured[1]["Authorization"] == "Bearer secret", "expected bearer authentication")
    assert(captured[1]["If-None-Match"] == "old", "expected conditional request support")
    assert(response.rate_limit[:remaining] == 4_999 && response.etag == "etag-1", "expected rate and ETag metadata")
  end

  def assert_error_redaction_and_size_bound
    error_transport = lambda do |*|
      FakeResponse.new("401", '{"message":"Bearer github_pat_not-a-real-token rejected"}', {})
    end
    begin
      HQ::GitHubAPIClient.new(token: "secret", transport: error_transport).get_json("/user")
      raise "expected authentication error"
    rescue HQ::GitHubAPIClient::Error => e
      assert(!e.message.include?("github_pat_"), "expected token-shaped text to be redacted")
    end

    large_transport = ->(*) { FakeResponse.new("200", "x" * 11, {}) }
    begin
      HQ::GitHubAPIClient.new(token: "secret", max_bytes: 10, transport: large_transport)
                         .get_text("/large", accept: "text/plain")
      raise "expected response size error"
    rescue HQ::GitHubAPIClient::Error => e
      assert(e.status == 413, "expected bounded response size")
    end
  end

  def assert_pagination_is_bounded
    pages = []
    transport = lambda do |uri, _headers|
      page = URI.decode_www_form(uri.query.to_s).to_h.fetch("page").to_i
      pages << page
      body = page < 3 ? Array.new(2) { |index| { "id" => page * 10 + index } } : [{ "id" => 30 }]
      FakeResponse.new("200", JSON.generate(body), {})
    end
    items, = HQ::GitHubAPIClient.new(token: "secret", transport:).paginate(
      "/items",
      per_page: 2,
      max_pages: 3
    )
    assert(pages == [1, 2, 3] && items.length == 5, "expected bounded pagination to stop on a short page")
  end

  def assert_timeouts_are_sanitized
    transport = ->(*) { raise Net::ReadTimeout, "github_pat_hidden" }
    begin
      HQ::GitHubAPIClient.new(token: "secret", transport:).get_json("/slow")
      raise "expected timeout"
    rescue HQ::GitHubAPIClient::Error => e
      assert(e.status == 504 && !e.message.include?("github_pat_"), "expected a stable sanitized timeout")
    end
  end

  def assert(condition, message)
    raise message unless condition
  end
end

GitHubAPIClientTest.run!
