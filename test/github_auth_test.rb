# frozen_string_literal: true

require "json"
require "tmpdir"

require_relative "../lib/hq/domain/github_auth"

module GitHubAuthTest
  module_function

  FakeResponse = Struct.new(:code, :body)
  FakeStatus = Struct.new(:success?)

  def run!
    assert_device_flow_persists_and_refreshes_session
    assert_cli_fallback_and_app_precedence
    puts "github_auth_test: ok"
  end

  def assert_device_flow_persists_and_refreshes_session
    Dir.mktmpdir do |dir|
      now = Time.utc(2026, 7, 29, 9, 0, 0)
      token_polls = 0
      transport = lambda do |method, uri, _headers, body|
        params = URI.decode_www_form(body.to_s).to_h
        case [method, uri.path]
        when [:post, "/login/device/code"]
          FakeResponse.new("200", JSON.generate(
                                    device_code: "device-secret",
                                    user_code: "ABCD-EFGH",
                                    verification_uri: "https://github.com/login/device",
                                    expires_in: 900,
                                    interval: 5
                                  ))
        when [:post, "/login/oauth/access_token"]
          if params["grant_type"] == HQ::GitHubAuth::REFRESH_GRANT_TYPE
            FakeResponse.new("200", JSON.generate(
                                      access_token: "ghu_refreshed",
                                      expires_in: 28_800,
                                      refresh_token: "ghr_refreshed",
                                      refresh_token_expires_in: 15_897_600,
                                      token_type: "bearer"
                                    ))
          else
            token_polls += 1
            body = if token_polls == 1
                     { error: "authorization_pending" }
                   else
                     {
                       access_token: "ghu_initial",
                       expires_in: 60,
                       refresh_token: "ghr_initial",
                       refresh_token_expires_in: 15_897_600,
                       token_type: "bearer"
                     }
                   end
            FakeResponse.new("200", JSON.generate(body))
          end
        when [:get, "/user"]
          FakeResponse.new("200", '{"login":"octocat"}')
        else
          raise "unexpected GitHub auth request #{method} #{uri}"
        end
      end
      store = HQ::GitHubAuth::Store.new(File.join(dir, "github_auth.json"))
      app = HQ::GitHubAuth::App.new(
        client_id: "client-id",
        app_slug: "tycho",
        store:,
        transport:,
        now: -> { now }
      )

      device = app.start_device_flow
      assert(device[:user_code] == "ABCD-EFGH", "expected a public device code")
      assert(!device.to_s.include?("device-secret"), "expected the private device code to stay server-side")

      pending = app.poll_device_flow(device[:id])
      assert(pending[:status] == "pending", "expected pending device authorization")
      now += 5
      authorized = app.poll_device_flow(device[:id])
      assert(authorized[:status] == "authenticated" && authorized[:account] == "octocat",
             "expected device authorization to persist the GitHub account")
      assert(File.stat(File.join(dir, "github_auth.json")).mode & 0o777 == 0o600,
             "expected GitHub credentials to use owner-only permissions")

      now += 61
      assert(app.access_token == "ghu_refreshed", "expected expired App tokens to refresh without a client secret")
      app.logout
      assert(!app.authenticated?, "expected logout to remove the local App session")
    end
  end

  def assert_cli_fallback_and_app_precedence
    cli = HQ::GitHubAuth::CLI.new(
      resolution: HQ::ExecutableResolver::Resolution.new(
        name: "gh", command: "/fake/gh", path: "/fake/gh", source: "test"
      ),
      runner: Class.new do
        def self.capture3(*)
          ["gho_cli", "", GitHubAuthTest::FakeStatus.new(true)]
        end
      end
    )
    app = Class.new do
      attr_writer :authenticated

      def initialize
        @authenticated = false
      end

      def authenticated?
        @authenticated
      end

      def configured?
        true
      end

      def access_token
        "ghu_app"
      end

      def capability
        { configured: configured?, authenticated: authenticated? }
      end
    end.new
    auth = HQ::GitHubAuth.new(app:, cli:)
    assert(auth.enabled? && auth.source == "gh" && auth.access_token == "gho_cli",
           "expected authenticated gh to remain a compatibility provider")

    app.authenticated = true
    assert(auth.source == "github_app" && auth.access_token == "ghu_app",
           "expected the Tycho GitHub App session to take precedence")
  end

  def assert(condition, message)
    raise message unless condition
  end
end

GitHubAuthTest.run!
