# frozen_string_literal: true

require "time"
require "uri"

require_relative "constants"
require_relative "file_store"

module HQ
  class RemoteCredentialStore
    SCHEMA_VERSION = 1
    FILENAME = "remote_credentials.json"
    MUTEX = Mutex.new

    attr_reader :path

    def self.default_path(registry: nil)
      configured = HQ.env("REMOTE_CREDENTIALS_PATH").to_s.strip
      return File.expand_path(configured) unless configured.empty?

      config_path = registry&.path || HQ.default_config_path
      File.join(File.dirname(File.expand_path(config_path)), FILENAME)
    end

    def initialize(path: nil, registry: nil, clock: -> { Time.now })
      @path = File.expand_path(path || self.class.default_path(registry:))
      @clock = clock
    end

    def stored(key)
      server(key).fetch("stored", {}).dup
    end

    def external(key, token_env)
      metadata = server(key).fetch("external", {})
      return {} unless metadata["token_env"].to_s == token_env.to_s

      metadata.dup
    end

    def save_token(key, token:, origin:, state: "unverified")
      update do |data|
        entry = server_entry(data, key)
        previous = entry.fetch("stored", {})
        now = timestamp
        entry["stored"] = compact_hash(
          "token" => token.to_s,
          "origin" => origin.to_s,
          "state" => state,
          "created_at" => previous["created_at"] || now,
          "updated_at" => now,
          "verified_at" => state == "verified" ? now : nil,
          "rejected_at" => nil
        )
      end
    end

    def delete_token(key)
      removed = false
      update do |data|
        entry = server_entry(data, key, create: false)
        next unless entry&.key?("stored")

        entry.delete("stored")
        removed = true
        prune_server(data, key)
      end
      removed
    end

    def mark_verified(key, source:, origin:, token_env: nil)
      current = source.to_s == "external" ? external(key, token_env) : stored(key)
      if current["state"] == "verified" && current["origin"] == origin.to_s
        return false
      end

      update_metadata(key, source:, token_env:) do |metadata|
        now = timestamp
        metadata["created_at"] ||= now
        metadata["origin"] = origin.to_s
        metadata["state"] = "verified"
        metadata["updated_at"] = now
        metadata["verified_at"] = now
        metadata.delete("rejected_at")
      end
      true
    end

    def mark_rejected(key, source:, origin:, token_env: nil)
      current = source.to_s == "external" ? external(key, token_env) : stored(key)
      return false if current["state"] == "rejected" && current["origin"] == origin.to_s

      update_metadata(key, source:, token_env:) do |metadata|
        now = timestamp
        metadata["created_at"] ||= now
        metadata["origin"] ||= origin.to_s
        metadata["state"] = "rejected"
        metadata["updated_at"] = now
        metadata["rejected_at"] = now
      end
      true
    end

    def remove_server(key)
      removed = false
      update do |data|
        removed = !data.fetch("servers", {}).delete(key.to_s).nil?
      end
      removed
    end

    def metadata(key)
      entry = server(key)
      {
        "stored" => redact(entry.fetch("stored", {})),
        "external" => redact(entry.fetch("external", {}))
      }
    end

    private

    def server(key)
      read.fetch("servers", {}).fetch(key.to_s, {})
    end

    def read
      return empty_data unless File.exist?(@path)

      File.chmod(0o600, @path)
      data = FileStore.read_json(@path, fallback: empty_data)
      data.is_a?(Hash) && data["servers"].is_a?(Hash) ? data : empty_data
    end

    def update
      MUTEX.synchronize do
        data = read
        yield data
        data["schema_version"] = SCHEMA_VERSION
        data["servers"] ||= {}
        FileStore.write_json(@path, data, backup: false)
        FileUtils.rm_f(FileStore.backup_path(@path))
        File.chmod(0o600, @path)
      end
    end

    def update_metadata(key, source:, token_env:)
      update do |data|
        entry = server_entry(data, key)
        field = source.to_s == "external" ? "external" : source.to_s
        metadata = entry[field] ||= {}
        metadata["token_env"] = token_env.to_s if field == "external"
        yield metadata
      end
    end

    def server_entry(data, key, create: true)
      servers = data["servers"] ||= {}
      return servers[key.to_s] unless create

      servers[key.to_s] ||= {}
    end

    def prune_server(data, key)
      entry = data.fetch("servers", {})[key.to_s]
      data["servers"].delete(key.to_s) if entry&.empty?
    end

    def redact(metadata)
      metadata.reject { |field, _value| field == "token" }
    end

    def compact_hash(hash)
      hash.reject { |_key, value| value.nil? }
    end

    def empty_data
      { "schema_version" => SCHEMA_VERSION, "servers" => {} }
    end

    def timestamp
      @clock.call.iso8601
    end
  end

  class RemoteCredentialResolver
    Credential = Struct.new(:server_key, :token, :source, :state, :origin, :token_env, keyword_init: true)

    class Error < StandardError
      attr_reader :kind

      def initialize(message, kind:)
        super(message)
        @kind = kind
      end
    end

    attr_reader :store

    def initialize(store:, env: ENV, warning: nil)
      @store = store
      @env = env
      @warning = warning || ->(message) { warn(message) }
    end

    def resolve(config, allow_rejected: false, allow_origin_change: false)
      token_env = config.respond_to?(:token_env) ? config.token_env.to_s.strip : ""
      return external_credential(config, token_env, allow_rejected:, allow_origin_change:) unless token_env.empty?

      stored = store.stored(config.key)
      unless stored["token"].to_s.empty?
        return credential_from(config, stored, source: "stored", allow_rejected:, allow_origin_change:)
      end

      inline = config.respond_to?(:token) ? config.token.to_s : ""
      unless inline.empty?
        @warning.call("Warning: remote server #{config.key} uses inline token from hq.yml; " \
                      "run `tycho server migrate #{config.key}`. Inline token support will be removed in v0.11.0.")
        return Credential.new(
          server_key: config.key,
          token: inline,
          source: "inline",
          state: "legacy",
          origin: canonical_origin(config.url)
        )
      end

      Credential.new(server_key: config.key, token: "", source: "none", state: "missing",
                     origin: canonical_origin(config.url))
    end

    def save(config, token:, verified: false)
      store.save_token(
        config.key,
        token: token,
        origin: canonical_origin(config.url),
        state: verified ? "verified" : "unverified"
      )
    end

    def configured?(config)
      token_env = config.respond_to?(:token_env) ? config.token_env.to_s.strip : ""
      return !@env[token_env].to_s.empty? unless token_env.empty?

      inline = config.respond_to?(:token) ? config.token.to_s : ""
      !store.stored(config.key)["token"].to_s.empty? || !inline.empty?
    end

    def verified!(credential, config)
      return if credential.token.to_s.empty? || %w[none inline transient].include?(credential.source)

      store.mark_verified(
        config.key,
        source: credential.source,
        origin: canonical_origin(config.url),
        token_env: credential.token_env
      )
    end

    def rejected!(credential, config)
      return if credential.token.to_s.empty? || %w[none inline transient].include?(credential.source)

      store.mark_rejected(
        config.key,
        source: credential.source,
        origin: canonical_origin(config.url),
        token_env: credential.token_env
      )
    end

    def transient(config, token)
      Credential.new(
        server_key: config.key,
        token: token.to_s,
        source: "transient",
        state: "unverified",
        origin: canonical_origin(config.url)
      )
    end

    def canonical_origin(url)
      uri = URI.parse(url.to_s)
      host = uri.hostname.to_s.downcase
      host = "[#{host}]" if host.include?(":")
      "#{uri.scheme.to_s.downcase}://#{host}:#{uri.port}"
    rescue URI::InvalidURIError
      raise Error.new("Invalid remote server origin", kind: :origin)
    end

    private

    def external_credential(config, token_env, allow_rejected:, allow_origin_change:)
      token = @env[token_env].to_s
      if token.empty?
        raise Error.new(
          "Remote server #{config.key} requires environment variable #{token_env}",
          kind: :missing_external
        )
      end

      metadata = store.external(config.key, token_env)
      credential_from(
        config,
        metadata.merge("token" => token),
        source: "external",
        token_env: token_env,
        allow_rejected:,
        allow_origin_change:
      )
    end

    def credential_from(config, metadata, source:, token_env: nil, allow_rejected:, allow_origin_change:)
      expected = canonical_origin(config.url)
      bound = metadata["origin"].to_s
      if !allow_origin_change && !bound.empty? && bound != expected
        raise Error.new(
          "Remote server #{config.key} origin changed from #{bound} to #{expected}; run `tycho server verify #{config.key}`",
          kind: :origin_mismatch
        )
      end
      state = metadata["state"].to_s
      state = "unverified" if state.empty?
      if state == "rejected" && !allow_rejected
        raise Error.new(
          "Remote server #{config.key} credential was rejected; run `tycho server login #{config.key}` or `tycho server verify #{config.key}`",
          kind: :rejected
        )
      end

      Credential.new(
        server_key: config.key,
        token: metadata["token"].to_s,
        source: source,
        state: state,
        origin: bound.empty? ? nil : bound,
        token_env: token_env
      )
    end
  end
end
