# frozen_string_literal: true

require "tmpdir"

require_relative "../lib/hq/domain/pull_request_diff"

module PullRequestDiffTest
  module_function

  class FakeClient
    attr_reader :requests

    def initialize(metadata: {}, diff: "")
      @metadata = metadata
      @diff = diff
      @requests = []
    end

    def get_json(path, **)
      @requests << [:json, path]
      HQ::GitHubAPIClient::Response.new(
        status: 200,
        body: @metadata,
        headers: {},
        etag: "metadata-etag",
        rate_limit: { remaining: 42 },
        not_modified: false
      )
    end

    def get_text(path, accept:, **)
      @requests << [:text, path, accept]
      HQ::GitHubAPIClient::Response.new(
        status: 200,
        body: @diff,
        headers: {},
        not_modified: false
      )
    end
  end

  def run!
    assert_github_provider_uses_direct_pr_endpoints
    assert_structural_truncation_drops_partial_file
    assert_freshness_separates_code_and_activity
    assert_snapshot_identity_omits_agent_key
    assert_store_preserves_concurrent_snapshots
    assert_store_reuses_and_invalidates_document_cache
    puts "pull_request_diff_test: ok"
  end

  def assert_github_provider_uses_direct_pr_endpoints
    client = FakeClient.new(
      metadata: {
        "title" => "Fix metadata",
        "html_url" => "https://github.com/example/web/pull/123",
        "head" => { "sha" => "head", "ref" => "feature" },
        "base" => { "sha" => "base", "ref" => "main" }
      },
      diff: complete_diff("app/example.rb")
    )
    provider = HQ::PullRequestDiff::GitHubProvider.new(client:)
    reference = reference_for

    metadata = provider.metadata(reference)
    diff, truncated = provider.patch(reference)

    assert(metadata["title"] == "Fix metadata", "expected JSON metadata from the REST pull endpoint")
    assert(!truncated && diff.include?("diff --git"), "expected the current PR diff media type")
    assert(client.requests == [
      [:json, "/repos/example/web/pulls/123"],
      [:text, "/repos/example/web/pulls/123", "application/vnd.github.diff"]
    ], "expected the provider to use direct metadata and diff endpoints")
  end

  def assert_structural_truncation_drops_partial_file
    first = complete_diff("small.rb")
    second = "diff --git a/large.txt b/large.txt\n--- a/large.txt\n+++ b/large.txt\n@@ -1 +1 @@\n" +
             ("+#{'x' * 200}\n" * 5_000)
    provider = HQ::PullRequestDiff::GitHubProvider.new(client: FakeClient.new(diff: first + second))

    diff, truncated = provider.patch(reference_for)

    assert(truncated, "expected an oversized patch to be marked truncated")
    assert(diff.include?("small.rb"), "expected complete files before the byte limit to remain")
    assert(!diff.include?("large.txt"), "expected the partial file at the limit to be omitted")
    assert(diff.valid_encoding?, "expected truncation to preserve valid UTF-8")
  end

  def assert_freshness_separates_code_and_activity
    snapshot = {
      "diff_format" => HQ::PullRequestDiff::DIFF_FORMAT,
      "head_sha" => "head",
      "base_sha" => "base",
      "remote_updated_at" => "old"
    }
    summary = HQ::PullRequestDiff.snapshot_summary(
      snapshot,
      metadata: { "head_sha" => "head", "base_sha" => "base", "remote_updated_at" => "new" }
    )

    assert(summary["code_fresh"], "expected activity-only updates not to invalidate code")
    assert(!summary["activity_fresh"], "expected activity freshness to be reported separately")
  end

  def assert_snapshot_identity_omits_agent_key
    client = FakeClient.new(
      metadata: {
        "title" => "PR",
        "head" => { "sha" => "head", "ref" => "feature" },
        "base" => { "sha" => "base", "ref" => "main" }
      },
      diff: complete_diff("app.rb")
    )
    first = reference_for(agent_key: "agent-a")
    second = reference_for(agent_key: "agent-b")

    first_snapshot = HQ::PullRequestDiff.snapshot_for(first, provider: HQ::PullRequestDiff::GitHubProvider.new(client:))
    second_snapshot = HQ::PullRequestDiff.snapshot_for(second, provider: HQ::PullRequestDiff::GitHubProvider.new(client:))

    assert(first_snapshot["snapshot_id"] == second_snapshot["snapshot_id"], "expected immutable snapshot identity to ignore agent ownership")
    assert(!first_snapshot.key?("agent_key"), "expected agent ownership to live in occurrence state")
  end

  def assert_store_preserves_concurrent_snapshots
    Dir.mktmpdir("tycho-pr-diffs") do |dir|
      store = HQ::PullRequestDiff::Store.new(File.join(dir, "snapshots.json"))
      threads = 10.times.map do |index|
        Thread.new { store.save("id" => index.to_s, "diff_format" => HQ::PullRequestDiff::DIFF_FORMAT) }
      end
      threads.each(&:join)
      assert(store.all.length == 10, "expected locked read-modify-write to preserve concurrent saves")
      snapshot = { "id" => "current", "snapshot_id" => "immutable-1", "fetched_at" => Time.now.iso8601 }
      store.save(snapshot)
      assert(store.fetch_snapshot("immutable-1") == snapshot, "expected immutable history to support changed-since-review")
    end
  end

  def assert_store_reuses_and_invalidates_document_cache
    Dir.mktmpdir("tycho-pr-diff-cache") do |dir|
      path = File.join(dir, "snapshots.json")
      store = HQ::PullRequestDiff::Store.new(path)
      store.save("id" => "first", "snapshot_id" => "first-snapshot")
      first_read = store.all
      assert(store.all.equal?(first_read), "expected unchanged snapshot files to reuse the parsed document")
      assert(first_read.frozen? && first_read.fetch("first").frozen?, "expected cached snapshots to be immutable")
      begin
        first_read.fetch("first")["snapshot_id"] = "mutated"
      rescue FrozenError
        nil
      end
      assert(store.fetch("first")["snapshot_id"] == "first-snapshot", "expected callers not to mutate cached snapshots")

      HQ::PullRequestDiff::Store.new(path).save("id" => "second", "snapshot_id" => "second-snapshot")
      assert(store.all.keys.sort == %w[first second], "expected external snapshot writes to invalidate the parsed document")
    end
  end

  def reference_for(agent_key: nil)
    HQ::PullRequestDiff::Reference.new(
      id: HQ::PullRequestDiff.reference_id("github", "example/web", 123),
      provider: "github",
      repository: "example/web",
      number: 123,
      url: "https://github.com/example/web/pull/123",
      agent_key:
    )
  end

  def complete_diff(path)
    <<~DIFF
      diff --git a/#{path} b/#{path}
      index 1111111..2222222 100644
      --- a/#{path}
      +++ b/#{path}
      @@ -1 +1 @@
      -old
      +new
    DIFF
  end

  def assert(condition, message)
    raise message unless condition
  end
end

PullRequestDiffTest.run!
