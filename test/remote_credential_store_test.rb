# frozen_string_literal: true

require "json"
require "tmpdir"

require_relative "../lib/hq/registry"
require_relative "../lib/hq/domain/remote_credential_store"

module RemoteCredentialStoreTest
  module_function

  def run!
    assert_store_is_private_and_metadata_is_redacted
    assert_external_precedence_and_origin_binding
    assert_rejection_requires_explicit_recovery
    assert_inline_fallback_warns_about_v011_removal
    puts "remote_credential_store_test: ok"
  end

  def assert_store_is_private_and_metadata_is_redacted
    Dir.mktmpdir("tycho-remote-credentials") do |dir|
      path = File.join(dir, "remote_credentials.json")
      registry = Struct.new(:path).new(File.join(dir, "hq.yml"))
      assert(HQ::RemoteCredentialStore.default_path(registry: registry) == path,
             "expected remote_credentials.json beside the active hq.yml")
      store = HQ::RemoteCredentialStore.new(path: path)
      store.save_token("vps", token: "stored-secret", origin: "https://vps.example:443")

      assert(File.exist?(path), "expected the credential file to be created")
      assert(File.stat(path).mode & 0o777 == 0o600, "expected private credential-file permissions")
      assert(JSON.parse(File.read(path)).dig("servers", "vps", "stored", "token") == "stored-secret",
             "expected the token to persist under its stable server key")
      assert(!store.metadata("vps").fetch("stored").key?("token"),
             "expected status metadata to omit the token")
    end
  end

  def assert_external_precedence_and_origin_binding
    Dir.mktmpdir("tycho-remote-credentials") do |dir|
      store = HQ::RemoteCredentialStore.new(path: File.join(dir, "remote_credentials.json"))
      store.save_token("vps", token: "stored-secret", origin: "https://vps.example:443", state: "verified")
      config = config_for(url: "HTTPS://VPS.Example/path", token_env: "TYCHO_TEST_MULTI_SERVER_TOKEN")
      env = {}
      resolver = HQ::RemoteCredentialResolver.new(store: store, env: env)

      error = capture_error { resolver.resolve(config) }
      assert(error.kind == :missing_external && error.message.include?(config.token_env),
             "expected a missing configured external source to fail without stored-token fallback")

      env[config.token_env] = "external-secret"
      credential = resolver.resolve(config)
      assert(credential.source == "external" && credential.token == "external-secret",
             "expected token_env to select the external token for this server entry")
      resolver.verified!(credential, config)
      metadata = store.metadata("vps").fetch("external")
      assert(metadata["origin"] == "https://vps.example:443" && metadata["state"] == "verified",
             "expected the first successful external request to bind the normalized origin")

      moved = config_for(url: "https://vps.example:8443/elsewhere", token_env: config.token_env)
      error = capture_error { resolver.resolve(moved) }
      assert(error.kind == :origin_mismatch && !error.message.include?(credential.token),
             "expected scheme, host, or port changes to require re-authentication")
      rebound = resolver.resolve(moved, allow_origin_change: true)
      resolver.verified!(rebound, moved)
      assert(resolver.resolve(moved).state == "verified",
             "expected explicit verification to rebind an external credential to the new origin")

      office = HQ::RemoteServerConfig.new(
        key: "office",
        name: "Office",
        icon: "computer",
        url: "https://office.example",
        token: "",
        token_env: "TYCHO_TEST_OFFICE_TOKEN"
      )
      env[office.token_env] = "office-secret"
      assert(resolver.resolve(office).token == "office-secret" && resolver.resolve(moved).token == "external-secret",
             "expected each server entry's explicit token_env to select its own token")
    end
  end

  def assert_rejection_requires_explicit_recovery
    Dir.mktmpdir("tycho-remote-credentials") do |dir|
      store = HQ::RemoteCredentialStore.new(path: File.join(dir, "remote_credentials.json"))
      resolver = HQ::RemoteCredentialResolver.new(store: store)
      config = config_for
      resolver.save(config, token: "stored-secret", verified: true)
      credential = resolver.resolve(config)
      resolver.rejected!(credential, config)

      error = capture_error { resolver.resolve(config) }
      assert(error.kind == :rejected, "expected rejected credentials to stop automatic use")
      rejected = resolver.resolve(config, allow_rejected: true)
      resolver.verified!(rejected, config)
      assert(resolver.resolve(config).state == "verified", "expected explicit verification to recover the credential")
      assert(store.delete_token(config.key), "expected logout to remove the stored token")
      assert(resolver.resolve(config).source == "none", "expected logout to leave no stored credential")
    end
  end

  def assert_inline_fallback_warns_about_v011_removal
    warnings = []
    config = config_for(token: "inline-secret")
    Dir.mktmpdir("tycho-remote-credentials") do |dir|
      resolver = HQ::RemoteCredentialResolver.new(
        store: HQ::RemoteCredentialStore.new(path: File.join(dir, "remote_credentials.json")),
        warning: ->(message) { warnings << message }
      )
      assert(resolver.resolve(config).source == "inline", "expected the temporary inline-token fallback")
      assert(warnings.one? && warnings.first.include?("removed in v0.11.0") &&
             warnings.first.include?("tycho server migrate vps"),
             "expected a migration warning with the removal release")
    end
  end

  def config_for(url: "https://vps.example/api", token: "", token_env: "")
    HQ::RemoteServerConfig.new(
      key: "vps",
      name: "VPS",
      icon: "server",
      url: url,
      token: token,
      token_env: token_env
    )
  end

  def capture_error
    yield
    raise "expected an error"
  rescue HQ::RemoteCredentialResolver::Error => e
    e
  end

  def assert(condition, message)
    raise message unless condition
  end
end

RemoteCredentialStoreTest.run! if $PROGRAM_NAME == __FILE__
