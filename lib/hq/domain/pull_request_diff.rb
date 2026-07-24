# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"
require "uri"

require_relative "command_runner"
require_relative "constants"
require_relative "file_store"
require_relative "git_diff"

module HQ
  class PullRequestDiff
    GITHUB_PR_URL = %r{\Ahttps?://github\.com/([^/\s]+)/([^/\s]+)/pull/(\d+)(?:[/?#].*)?\z}i
    DIFF_FORMAT = "github_diff_v2"
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
      def initialize(path = File.join(HQ::AGENT_LOGS_DIR, "pull_request_diffs.json"))
        @path = path
      end

      def all
        parsed = FileStore.read_json(@path, fallback: {})
        parsed.is_a?(Hash) ? parsed : {}
      rescue StandardError => e
        HQ.logger.warn("PRDiff") { "Failed to load PR diffs from #{@path}: #{e.class} - #{e.message}" }
        {}
      end

      def fetch(id)
        all[id.to_s]
      end

      def save(snapshot)
        id = snapshot.fetch("id")
        snapshots = all
        snapshots[id] = snapshot
        FileStore.write_json(@path, snapshots)
        snapshot
      end
    end

    class GitHubProvider
      COMMAND_TIMEOUT = 12

      def metadata(reference)
        data = gh_json("repos/#{reference.repository}/pulls/#{reference.number}")
        {
          "title" => data["title"],
          "url" => data["html_url"] || reference.url,
          "state" => data["state"],
          "draft" => data["draft"] == true,
          "author" => data.dig("user", "login"),
          "base_sha" => data.dig("base", "sha"),
          "head_sha" => data.dig("head", "sha"),
          "base_ref" => data.dig("base", "ref"),
          "head_ref" => data.dig("head", "ref"),
          "file_count" => data["changed_files"],
          "additions" => data["additions"],
          "deletions" => data["deletions"],
          "remote_updated_at" => data["updated_at"]
        }.compact
      end

      def patch(reference)
        output = utf8_output(gh_output(
          "pr", "diff", reference.number.to_s,
          "--repo", reference.repository,
          "--color", "never"
        ))
        truncated = output.bytesize > MAX_PATCH_BYTES
        output = output.byteslice(0, MAX_PATCH_BYTES).to_s if truncated
        [output, truncated]
      end

      private

      def gh_json(path)
        JSON.parse(utf8_output(gh_output("api", path)))
      rescue JSON::ParserError
        raise Error.new("GitHub returned invalid JSON", status: 502)
      end

      def utf8_output(output)
        output.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      end

      def gh_output(*args)
        command = ["gh", *args]
        result = CommandRunner.capture(command, timeout: COMMAND_TIMEOUT)
        if result.timed_out?
          raise Error.new("GitHub CLI timed out while fetching PR diff metadata.", status: 504)
        end
        raise Error.new(gh_error(result.stderr), status: 502) unless result.success?

        result.stdout.to_s
      rescue Errno::ENOENT
        raise Error.new("GitHub CLI is not available; install or authenticate `gh` to refresh PR diffs.", status: 424)
      end

      def gh_error(stderr)
        text = stderr.to_s.strip
        text.empty? ? "GitHub CLI failed while fetching PR diff data." : text
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
          title: attachment["title"].to_s.strip.empty? ? "#{repository}##{number}" : attachment["title"].to_s.strip,
          description: attachment["description"].to_s.strip.empty? ? nil : attachment["description"].to_s.strip,
          agent_key: agent.key
        )
      end

      def parse_github_url(url)
        match = GITHUB_PR_URL.match(url.to_s.strip)
        return nil unless match

        { owner: match[1], repo: match[2], number: match[3].to_i }
      end

      def reference_id(provider, repository, number)
        Digest::SHA256.hexdigest([provider, repository, number].join("\0"))[0, 20]
      end

      def canonical_url(repository, number)
        "https://github.com/#{repository}/pull/#{number}"
      end

      def snapshot_for(reference, provider: GitHubProvider.new)
        metadata = provider.metadata(reference)
        patch, truncated = provider.patch(reference)
        files = GitDiff.parse_patch_text(patch)
        {
          "id" => reference.id,
          "agent_key" => reference.agent_key,
          "provider" => reference.provider,
          "repository" => reference.repository,
          "number" => reference.number,
          "url" => metadata["url"] || reference.url,
          "title" => metadata["title"] || reference.title,
          "description" => reference.description,
          "state" => metadata["state"],
          "draft" => metadata["draft"],
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
          "additions" => files.sum { |file| file[:additions].to_i },
          "deletions" => files.sum { |file| file[:deletions].to_i },
          "truncated" => truncated
        }.compact
      end

      def reference_payload(reference, snapshot: nil, metadata: nil, error: nil)
        payload = reference.to_h
        payload["snapshot"] = snapshot_summary(snapshot, metadata:)
        payload["error"] = error if error
        payload
      end

      def snapshot_summary(snapshot, metadata: nil)
        return nil unless snapshot.is_a?(Hash)

        fresh = if metadata
                  snapshot["head_sha"].to_s == metadata["head_sha"].to_s &&
                    snapshot["remote_updated_at"].to_s == metadata["remote_updated_at"].to_s &&
                    current_snapshot?(snapshot)
                end
        {
          "fetched_at" => snapshot["fetched_at"],
          "remote_updated_at" => snapshot["remote_updated_at"],
          "head_sha" => snapshot["head_sha"],
          "base_sha" => snapshot["base_sha"],
          "file_count" => snapshot["file_count"],
          "additions" => snapshot["additions"],
          "deletions" => snapshot["deletions"],
          "truncated" => snapshot["truncated"],
          "fresh" => fresh.nil? ? nil : fresh
        }.compact
      end

      def current_snapshot?(snapshot)
        snapshot.is_a?(Hash) && snapshot["diff_format"] == DIFF_FORMAT
      end

      private

      def attachment_url(attachment)
        attachment["url"].to_s.strip
      end
    end
  end
end
