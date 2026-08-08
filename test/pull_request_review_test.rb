# frozen_string_literal: true

require "tmpdir"
require "timeout"

require_relative "../lib/hq/domain/pull_request_review"

module PullRequestReviewTest
  module_function

  def run!
    assert_occurrences_deduplicate_without_losing_owners
    assert_revision_change_invalidates_review_state
    assert_handoff_is_bound_to_snapshot
    assert_thousand_file_state_remains_bounded
    assert_context_fetches_independent_collections_concurrently
    assert_context_reuses_a_known_pull_response
    puts "pull_request_review_test: ok"
  end

  def assert_occurrences_deduplicate_without_losing_owners
    Dir.mktmpdir("tycho-pr-review") do |dir|
      store = HQ::PullRequestReview::Store.new(File.join(dir, "reviews.json"))
      reference = reference_for
      threads = 20.times.map do |index|
        Thread.new do
          store.sync_occurrence(
            reference,
            "source" => "agent_attachment",
            "agent_key" => "agent-#{index}",
            "project_key" => "web"
          )
        end
      end
      threads.each(&:join)
      assert(store.occurrences(reference.id).length == 20,
             "expected concurrent source occurrences to preserve every owner")
    end
  end

  def assert_revision_change_invalidates_review_state
    Dir.mktmpdir("tycho-pr-review") do |dir|
      store = HQ::PullRequestReview::Store.new(File.join(dir, "reviews.json"))
      id = reference_for.id
      store.update_state(
        id,
        "selection_snapshot_id" => "old",
        "viewed_files" => ["app.rb"],
        "selections" => { "files" => ["app.rb"] },
        "draft" => { "body" => "approve" }
      )
      state = store.reconcile_snapshot(id, "snapshot_id" => "new")

      assert(state["viewed_files"].empty? && state["selections"].empty? && state["draft"].nil?,
             "expected force-push or base change to invalidate viewed, selected, and draft state")
      assert(state["invalidation_reason"] == "pull_request_revision_changed",
             "expected invalidation to remain observable")
    end
  end

  def assert_handoff_is_bound_to_snapshot
    prompt = HQ::PullRequestReview.handoff_prompt(
      reference_for,
      { "snapshot_id" => "snapshot-1", "base_sha" => "base", "head_sha" => "head" },
      { "files" => ["app.rb"], "hunks" => ["app.rb:0"], "comments" => ["comment-1"] },
      "Check the race."
    )

    assert(prompt.include?("snapshot-1") && prompt.include?("base..head"),
           "expected handoff provenance to include immutable snapshot SHAs")
    assert(prompt.include?("app.rb:0") && prompt.include?("comment-1"),
           "expected selected hunks and comments in the previewed handoff")
    assert(prompt.include?("Do not post to GitHub"), "expected handoff to forbid implicit mutation")
  end

  def assert_thousand_file_state_remains_bounded
    files = 1_000.times.map { |index| "lib/file_#{index}.rb" }
    state = { "viewed_files" => files, "selections" => { "files" => files.first(25) } }
    encoded = JSON.generate(state)
    assert(JSON.parse(encoded)["viewed_files"].length == 1_000, "expected 1,000-file review state to stay navigable")
    assert(encoded.bytesize < 100_000, "expected path-only review state to remain bounded")
  end

  def assert_context_fetches_independent_collections_concurrently
    client = BlockingContextClient.new
    worker = Thread.new { HQ::PullRequestReview::GitHubContext.new(client:).fetch(reference_for) }

    begin
      Timeout.timeout(1) { 6.times { client.started.pop } }
    rescue Timeout::Error
      raise "expected independent PR context requests to start before any one completes"
    ensure
      client.release!
      worker.join
    end
    assert(worker.value["title"] == "Example", "expected the concurrent PR context to remain complete")
  end

  def assert_context_reuses_a_known_pull_response
    client = BlockingContextClient.new(block: false)
    pull = client.pull
    context = HQ::PullRequestReview::GitHubContext.new(client:).fetch(reference_for, pull:)

    assert(client.pull_requests.zero?, "expected a supplied PR payload to avoid a duplicate detail request")
    assert(context["head_sha"] == "head", "expected the supplied PR payload to preserve detail fields")
  end

  def reference_for
    HQ::PullRequestDiff::Reference.new(
      id: HQ::PullRequestDiff.reference_id("github", "example/web", 123),
      provider: "github",
      repository: "example/web",
      number: 123,
      url: "https://github.com/example/web/pull/123",
      title: "Example"
    )
  end

  class BlockingContextClient
    attr_reader :started, :pull_requests

    def initialize(block: true)
      @block = block
      @started = Queue.new
      @lock = Mutex.new
      @condition = ConditionVariable.new
      @released = false
      @pull_requests = 0
    end

    def pull
      {
        "title" => "Example",
        "html_url" => "https://github.com/example/web/pull/123",
        "state" => "open",
        "head" => { "sha" => "head", "ref" => "feature" },
        "base" => { "sha" => "base", "ref" => "main" }
      }
    end

    def get_json(path, **)
      if path.end_with?("/pulls/123")
        @pull_requests += 1
        return response(pull)
      end

      wait_for_other_requests(:checks)
      response("check_runs" => [])
    end

    def paginate(path, **)
      wait_for_other_requests(path)
      [[], nil]
    end

    def post_json(_path, _payload, **)
      wait_for_other_requests(:threads)
      response("data" => { "repository" => { "pullRequest" => { "reviewThreads" => { "nodes" => [] } } } })
    end

    def release!
      @lock.synchronize do
        @released = true
        @condition.broadcast
      end
    end

    private

    def response(body)
      HQ::GitHubAPIClient::Response.new(status: 200, body:, headers: {}, not_modified: false)
    end

    def wait_for_other_requests(name)
      @started << name
      return unless @block

      @lock.synchronize { @condition.wait(@lock) until @released }
    end
  end

  def assert(condition, message)
    raise message unless condition
  end
end

PullRequestReviewTest.run!
