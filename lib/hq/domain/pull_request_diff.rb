# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"
require "uri"

require_relative "constants"
require_relative "file_store"
require_relative "git_diff"
require_relative "github_api_client"

module HQ
  class PullRequestDiff
    GITHUB_PR_URL = %r{\Ahttps?://github\.com/([^/\s]+)/([^/\s]+)/pull/(\d+)(?:[/?#].*)?\z}i
    DIFF_FORMAT = "github_diff_v3"
    MAX_PATCH_BYTES = 768 * 1024

    class Error < StandardError
      attr_reader :status

      def initialize(message, status: 400)
        super(message)
        @status = status
      end
    end

    Reference = Struct.new(:id, :provider, :repository, :number, :url, :title, :description, :agent_key,
                           keyword_init: true) do
      def to_h
        {
          "id" => id,
          "provider" => provider,
          "repository" => repository,
          "number" => number,
          "url" => url,
          "title" => title,
          "description" => description,
          "agent_key" => agent_key
        }.compact
      end
    end

    class Store
      STORE_VERSION = 1
      MAX_SNAPSHOTS = 500

      def initialize(path = File.join(HQ::AGENT_LOGS_DIR, "pull_request_diffs.json"))
        @path = path
        @document_mutex = Mutex.new
        @document_signature = nil
        @document_cache = nil
      end

      def all
        parsed = document
        return {} unless parsed.is_a?(Hash)
        return parsed.fetch("snapshots", {}) if parsed["version"] == STORE_VERSION

        parsed
      rescue StandardError => e
        HQ.logger.warn("PRDiff") { "Failed to load PR diffs from #{@path}: #{e.class} - #{e.message}" }
        {}
      end

      def fetch_snapshot(snapshot_id)
        parsed = document
        return nil unless parsed.is_a?(Hash) && parsed["version"] == STORE_VERSION

        parsed.fetch("history", {})[snapshot_id.to_s]
      rescue StandardError
        nil
      end

      def fetch(id)
        all[id.to_s]
      end

      def save(snapshot)
        with_lock do
          id = snapshot.fetch("id")
          snapshots = all.dup
          snapshots[id] = snapshot
          snapshots = snapshots.sort_by { |_key, value| value["fetched_at"].to_s }.last(MAX_SNAPSHOTS).to_h
          parsed = document
          history = parsed.is_a?(Hash) && parsed["version"] == STORE_VERSION ? parsed.fetch("history", {}).dup : {}
          history[snapshot["snapshot_id"]] = snapshot if snapshot["snapshot_id"]
          history = history.sort_by { |_key, value| value["fetched_at"].to_s }.last(MAX_SNAPSHOTS).to_h
          FileStore.write_json(
            @path,
            { "version" => STORE_VERSION, "snapshots" => snapshots, "history" => history }
          )
          invalidate_document_cache
        end
        snapshot
      end

      private

      def document
        signature = document_signature
        @document_mutex.synchronize do
          return @document_cache if @document_cache && @document_signature == signature

          @document_cache = deep_freeze(FileStore.read_json(@path, fallback: {}))
          @document_signature = signature
          @document_cache
        end
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, item| deep_freeze(key); deep_freeze(item) }
        when Array
          value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end

      def document_signature
        stat = File.stat(@path)
        [stat.ino, stat.size, stat.mtime.to_i, stat.mtime.nsec]
      rescue Errno::ENOENT
        nil
      end

      def invalidate_document_cache
        @document_mutex.synchronize do
          @document_signature = nil
          @document_cache = nil
        end
      end

      def with_lock
        FileUtils.mkdir_p(File.dirname(@path))
        File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock.flock(File::LOCK_UN) rescue nil
        end
      end
    end

    class Catalog
      STORE_VERSION = 1
      METADATA_KEYS = %w[
        title url state draft mergeable mergeable_state merged author base_sha head_sha base_ref head_ref
        file_count additions deletions remote_updated_at
      ].freeze

      def initialize(path:)
        @path = path
      end

      def all
        parsed = FileStore.read_json(@path, fallback: {})
        return {} unless parsed.is_a?(Hash) && parsed["version"] == STORE_VERSION

        parsed.fetch("entries", {})
      rescue StandardError => e
        HQ.logger.warn("PRCatalog") { "Failed to load PR catalog from #{@path}: #{e.class} - #{e.message}" }
        {}
      end

      def discover(references, metadata_by_id: {})
        update do |entries|
          changed = false
          Array(references).each do |reference|
            unless entries.key?(reference.id)
              entries[reference.id] = reference_entry(reference, Time.now.iso8601)
              changed = true
            end
            metadata = metadata_by_id[reference.id]
            next unless metadata.is_a?(Hash) && !entries[reference.id]["metadata"].is_a?(Hash)

            cache_metadata(
              entries[reference.id],
              metadata,
              metadata["fetched_at"] || Time.now.iso8601,
              source: "snapshot"
            )
            changed = true
          end
          changed
        end
      end

      def save_metadata(reference, metadata)
        save_all_metadata([[reference, metadata]])
      end

      def save_all_metadata(items)
        items = Array(items)
        refreshed_at = Time.now.iso8601
        update do |entries|
          items.each do |reference, metadata|
            entries[reference.id] ||= reference_entry(reference, refreshed_at)
            cache_metadata(entries[reference.id], metadata, refreshed_at, source: "github")
          end
          items.any?
        end
      end

      private

      def reference_entry(reference, discovered_at)
        {
          "id" => reference.id,
          "provider" => reference.provider,
          "repository" => reference.repository,
          "number" => reference.number,
          "url" => reference.url,
          "discovered_at" => discovered_at
        }.compact
      end

      def cache_metadata(entry, metadata, refreshed_at, source:)
        entry["metadata"] = metadata.to_h
          .select { |key, _value| METADATA_KEYS.include?(key.to_s) }
          .transform_keys(&:to_s)
        entry["metadata_refreshed_at"] = refreshed_at
        entry["metadata_source"] = source
      end

      def update
        FileUtils.mkdir_p(File.dirname(@path))
        File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          entries = all
          changed = yield entries
          if changed
            FileStore.write_json(@path, { "version" => STORE_VERSION, "entries" => entries })
          end
          entries
        ensure
          lock.flock(File::LOCK_UN) rescue nil
        end
      end
    end

    class GitHubProvider
      def initialize(client: GitHubAPIClient.new)
        @client = client
      end

      def metadata(reference)
        metadata_with_pull(reference).first
      end

      def metadata_with_pull(reference)
        response = @client.get_json("/repos/#{reference.repository}/pulls/#{reference.number}")
        data = response.body
        [metadata_from(reference, data, response), data]
      rescue GitHubAPIClient::Error => e
        raise Error.new(e.message, status: e.status)
      end

      def patch(reference)
        response = @client.get_text(
          "/repos/#{reference.repository}/pulls/#{reference.number}",
          accept: "application/vnd.github.diff"
        )
        output, truncated = structurally_truncate(response.body)
        [output, truncated]
      rescue GitHubAPIClient::Error => e
        raise Error.new(e.message, status: e.status)
      end

      private

      def metadata_from(reference, data, response)
        {
          "title" => data["title"],
          "body" => data["body"],
          "url" => data["html_url"] || reference.url,
          "state" => data["state"],
          "draft" => data["draft"] == true,
          "mergeable" => data["mergeable"],
          "mergeable_state" => data["mergeable_state"],
          "merged" => data["merged"] == true,
          "author" => data.dig("user", "login"),
          "base_sha" => data.dig("base", "sha"),
          "head_sha" => data.dig("head", "sha"),
          "base_ref" => data.dig("base", "ref"),
          "head_ref" => data.dig("head", "ref"),
          "file_count" => data["changed_files"],
          "additions" => data["additions"],
          "deletions" => data["deletions"],
          "remote_updated_at" => data["updated_at"],
          "etag" => response.etag,
          "rate_limit" => response.rate_limit
        }.compact
      end

      def structurally_truncate(output)
        return [output, false] if output.bytesize <= MAX_PATCH_BYTES

        prefix = output.byteslice(0, MAX_PATCH_BYTES).to_s.force_encoding(Encoding::UTF_8).scrub
        boundary = prefix.rindex("\ndiff --git ")
        boundary ? [prefix.byteslice(0, boundary + 1), true] : ["", true]
      end
    end

    class << self
      def references_for_agent(agent)
        seen = {}
        Array(agent.attachments).filter_map do |attachment|
          reference_from_attachment(agent, attachment)
        end.each_with_object([]) do |reference, refs|
          next if seen[reference.id]

          seen[reference.id] = true
          refs << reference
        end
      end

      def reference_from_attachment(agent, attachment)
        url = attachment_url(attachment)
        reference_from_url(
          url,
          title: attachment["title"],
          description: attachment["description"],
          agent_key: agent.key
        )
      end

      def reference_from_url(url, title: nil, description: nil, agent_key: nil)
        parsed = parse_github_url(url)
        return nil unless parsed

        repository = "#{parsed.fetch(:owner)}/#{parsed.fetch(:repo)}"
        number = parsed.fetch(:number)
        Reference.new(
          id: reference_id("github", repository, number),
          provider: "github",
          repository: repository,
          number: number,
          url: canonical_url(repository, number),
          title: title.to_s.strip.empty? ? "#{repository}##{number}" : title.to_s.strip,
          description: description.to_s.strip.empty? ? nil : description.to_s.strip,
          agent_key:
        )
      end

      def parse_github_url(url)
        match = GITHUB_PR_URL.match(url.to_s.strip)
        return nil unless match

        { owner: match[1], repo: match[2], number: match[3].to_i }
      end

      def reference_id(provider, repository, number)
        Digest::SHA256.hexdigest([provider.to_s.downcase, repository.to_s.downcase, number].join("\0"))[0, 20]
      end

      def canonical_url(repository, number)
        "https://github.com/#{repository}/pull/#{number}"
      end

      def snapshot_for(reference, provider: GitHubProvider.new, metadata: nil)
        metadata ||= provider.metadata(reference)
        patch, truncated = provider.patch(reference)
        files = GitDiff.parse_patch_text(patch).map { |file| annotate_file(file) }
        snapshot_id = Digest::SHA256.hexdigest(
          [reference.provider, reference.repository.downcase, reference.number,
           metadata["base_sha"], metadata["head_sha"]].join("\0")
        )[0, 24]
        {
          "id" => reference.id,
          "snapshot_id" => snapshot_id,
          "provider" => reference.provider,
          "repository" => reference.repository,
          "number" => reference.number,
          "url" => metadata["url"] || reference.url,
          "title" => metadata["title"] || reference.title,
          "description" => metadata["body"] || reference.description,
          "state" => metadata["state"],
          "draft" => metadata["draft"],
          "merged" => metadata["merged"],
          "author" => metadata["author"],
          "base_sha" => metadata["base_sha"],
          "head_sha" => metadata["head_sha"],
          "base_ref" => metadata["base_ref"],
          "head_ref" => metadata["head_ref"],
          "remote_updated_at" => metadata["remote_updated_at"],
          "fetched_at" => Time.now.iso8601,
          "diff_format" => DIFF_FORMAT,
          "files" => files,
          "file_count" => files.length,
          "remote_file_count" => metadata["file_count"],
          "omitted_file_count" => [metadata["file_count"].to_i - files.length, 0].max,
          "omitted_reason" => truncated ? "snapshot_byte_limit" : nil,
          "additions" => files.sum { |file| file[:additions].to_i },
          "deletions" => files.sum { |file| file[:deletions].to_i },
          "truncated" => truncated
        }.compact
      end

      def reference_payload(reference, snapshot: nil, metadata: nil, freshness_metadata: metadata, error: nil)
        payload = reference.to_h
        if metadata.is_a?(Hash)
          Catalog::METADATA_KEYS.each do |key|
            payload[key] = metadata[key] if metadata.key?(key)
          end
        end
        payload["snapshot"] = snapshot_summary(snapshot, metadata: freshness_metadata)
        payload["error"] = error if error
        payload
      end

      def snapshot_summary(snapshot, metadata: nil)
        return nil unless snapshot.is_a?(Hash)

        code_fresh = if metadata
                       snapshot["head_sha"].to_s == metadata["head_sha"].to_s &&
                         snapshot["base_sha"].to_s == metadata["base_sha"].to_s &&
                         current_snapshot?(snapshot)
                     end
        activity_fresh = if metadata
                           snapshot["remote_updated_at"].to_s == metadata["remote_updated_at"].to_s
                         end
        {
          "snapshot_id" => snapshot["snapshot_id"],
          "fetched_at" => snapshot["fetched_at"],
          "remote_updated_at" => snapshot["remote_updated_at"],
          "head_sha" => snapshot["head_sha"],
          "base_sha" => snapshot["base_sha"],
          "file_count" => snapshot["file_count"],
          "additions" => snapshot["additions"],
          "deletions" => snapshot["deletions"],
          "truncated" => snapshot["truncated"],
          "fresh" => code_fresh.nil? ? nil : code_fresh,
          "code_fresh" => code_fresh.nil? ? nil : code_fresh,
          "activity_fresh" => activity_fresh.nil? ? nil : activity_fresh
        }.compact
      end

      def current_snapshot?(snapshot)
        snapshot.is_a?(Hash) && snapshot["diff_format"] == DIFF_FORMAT
      end

      private

      def annotate_file(file)
        path = file[:path].to_s
        file.merge(generated: generated_path?(path))
      end

      def generated_path?(path)
        path.match?(%r{(?:\A|/)(?:dist|build|vendor|coverage|node_modules)/}i) ||
          path.match?(/\.(?:min\.(?:js|css)|lock|map)\z/i)
      end

      def attachment_url(attachment)
        attachment["url"].to_s.strip
      end
    end
  end
end
