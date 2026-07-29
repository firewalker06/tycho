# frozen_string_literal: true

require "digest"
require "fileutils"
require "time"

require_relative "constants"
require_relative "file_store"
require_relative "github_api_client"
require_relative "pull_request_diff"

module HQ
  class PullRequestReview
    STORE_VERSION = 1
    MAX_CANONICAL_REVIEWS = 500
    MAX_OCCURRENCES_PER_REVIEW = 50
    MAX_AUDIT_EVENTS = 100
    MAX_COMMITS = 250
    MAX_COMMENTS = 500

    class Store
      def initialize(path = File.join(HQ::AGENT_LOGS_DIR, "pull_request_reviews.json"))
        @path = path
      end

      def all
        parsed = FileStore.read_json(@path, fallback: {})
        return default_data unless parsed.is_a?(Hash)
        return parsed if parsed["version"] == STORE_VERSION

        default_data
      rescue StandardError => e
        HQ.logger.warn("PRReview") { "Failed to load PR review state from #{@path}: #{e.class} - #{e.message}" }
        default_data
      end

      def state(id)
        all.fetch("reviews", {}).fetch(id.to_s, {})
      end

      def occurrences(id)
        all.fetch("occurrences", {}).fetch(id.to_s, [])
      end

      def sync_occurrence(reference, source)
        mutate do |data|
          entries = data["occurrences"][reference.id] ||= []
          normalized = {
            "agent_key" => reference.agent_key,
            "title" => reference.title,
            "description" => reference.description,
            "seen_at" => Time.now.iso8601
          }.compact.merge(stringify(source))
          identity = occurrence_identity(normalized)
          entries.reject! { |entry| occurrence_identity(entry) == identity }
          entries << normalized
          entries.sort_by! { |entry| entry["seen_at"].to_s }.reverse!
          entries.slice!(MAX_OCCURRENCES_PER_REVIEW..)
          data
        end
        occurrences(reference.id)
      end

      def update_state(id, attrs)
        mutate do |data|
          current = data["reviews"][id.to_s] ||= {}
          current.merge!(stringify(attrs))
          current["updated_at"] = Time.now.iso8601
          data
        end
        state(id)
      end

      def save_draft(id, draft)
        update_state(id, "draft" => stringify(draft))
      end

      def record_handoff(id, payload)
        mutate do |data|
          current = data["reviews"][id.to_s] ||= {}
          current["handoffs"] ||= []
          current["handoffs"] << stringify(payload).merge("created_at" => Time.now.iso8601)
          current["handoffs"] = current["handoffs"].last(MAX_AUDIT_EVENTS)
          current["updated_at"] = Time.now.iso8601
          data
        end
        state(id)
      end

      def record_outcome(id, payload)
        mutate do |data|
          current = data["reviews"][id.to_s] ||= {}
          current["outcomes"] ||= []
          current["outcomes"] << stringify(payload).merge("recorded_at" => Time.now.iso8601)
          current["outcomes"] = current["outcomes"].last(MAX_AUDIT_EVENTS)
          current["updated_at"] = Time.now.iso8601
          data
        end
        state(id)
      end

      def reconcile_snapshot(id, snapshot)
        current = state(id)
        bound = current["selection_snapshot_id"].to_s
        current_id = snapshot["snapshot_id"].to_s
        return current if bound.empty? || bound == current_id

        update_state(
          id,
          "viewed_files" => [],
          "selections" => {},
          "draft" => nil,
          "selection_snapshot_id" => current_id,
          "invalidated_at" => Time.now.iso8601,
          "invalidation_reason" => "pull_request_revision_changed"
        )
      end

      private

      def default_data
        { "version" => STORE_VERSION, "occurrences" => {}, "reviews" => {} }
      end

      def mutate
        FileUtils.mkdir_p(File.dirname(@path))
        File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          data = all
          yield data
          prune!(data)
          FileStore.write_json(@path, data)
        ensure
          lock.flock(File::LOCK_UN) rescue nil
        end
      end

      def occurrence_identity(entry)
        [entry["agent_key"], entry["project_key"], entry["schedule_key"], entry["source"]].join("\0")
      end

      def prune!(data)
        ids = data["reviews"].sort_by { |_id, review| review["updated_at"].to_s }.last(MAX_CANONICAL_REVIEWS).map(&:first)
        occurrence_ids = data["occurrences"].keys.last(MAX_CANONICAL_REVIEWS)
        keep = (ids + occurrence_ids).uniq.last(MAX_CANONICAL_REVIEWS)
        data["reviews"].select! { |id, _review| keep.include?(id) }
        data["occurrences"].select! { |id, _entries| keep.include?(id) }
      end

      def stringify(value)
        case value
        when Hash then value.to_h { |key, item| [key.to_s, stringify(item)] }
        when Array then value.map { |item| stringify(item) }
        else value
        end
      end
    end

    class GitHubContext
      def initialize(client: GitHubAPIClient.new)
        @client = client
      end

      def fetch(reference)
        pull = @client.get_json(pr_path(reference)).body
        commits, = @client.paginate("#{pr_path(reference)}/commits", max_pages: 3)
        reviews, = @client.paginate("#{pr_path(reference)}/reviews", max_pages: 5)
        comments, = @client.paginate("#{pr_path(reference)}/comments", max_pages: 5)
        issue_comments, = @client.paginate(
          "/repos/#{reference.repository}/issues/#{reference.number}/comments",
          max_pages: 5
        )
        statuses = fetch_statuses(reference, pull.dig("head", "sha"))
        threads = fetch_threads(reference)
        {
          "title" => pull["title"],
          "url" => pull["html_url"],
          "description" => pull["body"],
          "author" => pull.dig("user", "login"),
          "state" => pull["state"],
          "draft" => pull["draft"] == true,
          "mergeable" => pull["mergeable"],
          "mergeable_state" => pull["mergeable_state"],
          "base_ref" => pull.dig("base", "ref"),
          "base_sha" => pull.dig("base", "sha"),
          "head_ref" => pull.dig("head", "ref"),
          "head_sha" => pull.dig("head", "sha"),
          "updated_at" => pull["updated_at"],
          "commits" => commits.first(MAX_COMMITS).map { |item| commit_payload(item) },
          "reviews" => reviews.map { |item| review_payload(item) },
          "review_decision" => review_decision(reviews),
          "inline_comments" => comments.first(MAX_COMMENTS).map { |item| comment_payload(item) },
          "issue_comments" => issue_comments.first(MAX_COMMENTS).map { |item| issue_comment_payload(item) },
          "checks" => statuses,
          "review_threads" => threads,
          "unresolved_thread_count" => threads.count { |thread| !thread["resolved"] }
        }.compact
      rescue GitHubAPIClient::Error => e
        raise PullRequestDiff::Error.new(e.message, status: e.status)
      end

      def summary(reference)
        owner, repo = reference.repository.split("/", 2)
        query = <<~GRAPHQL
          query($owner:String!, $repo:String!, $number:Int!) {
            repository(owner:$owner, name:$repo) {
              pullRequest(number:$number) {
                reviewDecision
                reviewThreads(first:100) { nodes { isResolved } }
                commits(last:1) {
                  nodes {
                    commit {
                      statusCheckRollup {
                        state
                        contexts(first:100) {
                          nodes {
                            ... on CheckRun { name status conclusion detailsUrl }
                            ... on StatusContext { context state targetUrl }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        GRAPHQL
        response = @client.post_json(
          "/graphql",
          { query:, variables: { owner:, repo:, number: reference.number } }
        )
        pull = response.body.dig("data", "repository", "pullRequest") || {}
        rollup = pull.dig("commits", "nodes", 0, "commit", "statusCheckRollup") || {}
        threads = Array(pull.dig("reviewThreads", "nodes"))
        {
          "review_decision" => pull["reviewDecision"].to_s.downcase,
          "unresolved_thread_count" => threads.count { |thread| thread["isResolved"] != true },
          "checks_state" => rollup["state"].to_s.downcase,
          "checks" => Array(rollup.dig("contexts", "nodes")).map do |check|
            {
              "name" => check["name"] || check["context"],
              "status" => check["status"] || check["state"],
              "conclusion" => check["conclusion"],
              "url" => check["detailsUrl"] || check["targetUrl"]
            }.compact
          end
        }
      rescue GitHubAPIClient::Error => e
        return { "context_error" => e.message } if [403, 404].include?(e.status)

        raise PullRequestDiff::Error.new(e.message, status: e.status)
      end

      def post_review(reference, payload, idempotency_key:)
        @client.post_json(
          "#{pr_path(reference)}/reviews",
          {
            body: payload.fetch("body", "").to_s,
            event: normalize_event(payload["event"]),
            comments: normalize_comments(payload["comments"])
          }.compact,
          idempotency_key:
        ).body
      rescue GitHubAPIClient::Error => e
        raise PullRequestDiff::Error.new(e.message, status: e.status)
      end

      private

      def pr_path(reference)
        "/repos/#{reference.repository}/pulls/#{reference.number}"
      end

      def fetch_statuses(reference, sha)
        return [] if sha.to_s.empty?

        response = @client.get_json("/repos/#{reference.repository}/commits/#{sha}/check-runs")
        Array(response.body["check_runs"]).map do |check|
          {
            "name" => check["name"],
            "status" => check["status"],
            "conclusion" => check["conclusion"],
            "url" => check["html_url"],
            "started_at" => check["started_at"],
            "completed_at" => check["completed_at"]
          }.compact
        end
      rescue GitHubAPIClient::Error => e
        return [] if [403, 404].include?(e.status)

        raise
      end

      def fetch_threads(reference)
        owner, repo = reference.repository.split("/", 2)
        query = <<~GRAPHQL
          query($owner:String!, $repo:String!, $number:Int!, $cursor:String) {
            repository(owner:$owner, name:$repo) {
              pullRequest(number:$number) {
                reviewThreads(first:100, after:$cursor) {
                  nodes {
                    id isResolved isOutdated path line originalLine
                    comments(first:100) {
                      nodes { id body createdAt url author { login } }
                    }
                  }
                }
              }
            }
          }
        GRAPHQL
        response = @client.post_json(
          "/graphql",
          { query:, variables: { owner:, repo:, number: reference.number, cursor: nil } }
        )
        nodes = response.body.dig("data", "repository", "pullRequest", "reviewThreads", "nodes")
        Array(nodes).map do |thread|
          {
            "id" => thread["id"],
            "resolved" => thread["isResolved"] == true,
            "outdated" => thread["isOutdated"] == true,
            "path" => thread["path"],
            "line" => thread["line"] || thread["originalLine"],
            "comments" => Array(thread.dig("comments", "nodes")).map { |comment| issue_comment_payload(comment) }
          }.compact
        end
      rescue GitHubAPIClient::Error => e
        return [] if [403, 404].include?(e.status)

        raise
      end

      def commit_payload(item)
        {
          "sha" => item["sha"],
          "message" => item.dig("commit", "message"),
          "author" => item.dig("author", "login") || item.dig("commit", "author", "name"),
          "authored_at" => item.dig("commit", "author", "date"),
          "url" => item["html_url"]
        }.compact
      end

      def review_payload(item)
        {
          "id" => item["id"],
          "author" => item.dig("user", "login"),
          "state" => item["state"],
          "body" => item["body"],
          "submitted_at" => item["submitted_at"],
          "commit_id" => item["commit_id"],
          "url" => item["html_url"]
        }.compact
      end

      def comment_payload(item)
        issue_comment_payload(item).merge(
          "path" => item["path"],
          "line" => item["line"] || item["original_line"],
          "side" => item["side"],
          "commit_id" => item["commit_id"]
        ).compact
      end

      def issue_comment_payload(item)
        {
          "id" => item["id"],
          "author" => item.dig("user", "login") || item.dig("author", "login"),
          "body" => item["body"],
          "created_at" => item["created_at"] || item["createdAt"],
          "url" => item["html_url"] || item["url"]
        }.compact
      end

      def review_decision(reviews)
        latest = {}
        reviews.each { |review| latest[review.dig("user", "login")] = review["state"] }
        return "changes_requested" if latest.value?("CHANGES_REQUESTED")
        return "approved" if latest.value?("APPROVED")
        return "reviewed" unless latest.empty?

        "none"
      end

      def normalize_event(value)
        event = value.to_s.upcase
        return event if %w[COMMENT APPROVE REQUEST_CHANGES].include?(event)

        "COMMENT"
      end

      def normalize_comments(value)
        comments = Array(value).filter_map do |comment|
          item = comment.transform_keys(&:to_s)
          path = item["path"].to_s
          body = item["body"].to_s
          line = Integer(item["line"], exception: false)
          next if path.empty? || body.empty? || !line

          { path:, body:, line:, side: item["side"].to_s.upcase == "LEFT" ? "LEFT" : "RIGHT" }
        end
        comments.empty? ? nil : comments
      end
    end

    class << self
      def changed_since_review?(snapshot, state)
        reviewed_head = state["reviewed_head_sha"].to_s
        reviewed_base = state["reviewed_base_sha"].to_s
        return false if reviewed_head.empty?

        reviewed_head != snapshot["head_sha"].to_s || reviewed_base != snapshot["base_sha"].to_s
      end

      def handoff_prompt(reference, snapshot, selection, note)
        selected_files = Array(selection["files"]).map(&:to_s)
        selected_hunks = Array(selection["hunks"]).map(&:to_s)
        selected_comments = Array(selection["comments"]).map(&:to_s)
        <<~PROMPT
          Review handoff for #{reference.url}
          Snapshot: #{snapshot["snapshot_id"]} (#{snapshot["base_sha"]}..#{snapshot["head_sha"]})

          Request:
          #{note.to_s.strip}

          Selected files: #{selected_files.empty? ? "(none)" : selected_files.join(", ")}
          Selected hunks: #{selected_hunks.empty? ? "(none)" : selected_hunks.join(", ")}
          Selected comments: #{selected_comments.empty? ? "(none)" : selected_comments.join(", ")}

          Inspect the selected context and report findings. Do not post to GitHub or mutate the pull request.
        PROMPT
      end
    end
  end
end
