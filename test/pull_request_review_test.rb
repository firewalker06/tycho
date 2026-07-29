# frozen_string_literal: true

require "tmpdir"

require_relative "../lib/hq/domain/pull_request_review"

module PullRequestReviewTest
  module_function

  def run!
    assert_occurrences_deduplicate_without_losing_owners
    assert_revision_change_invalidates_review_state
    assert_handoff_is_bound_to_snapshot
    assert_thousand_file_state_remains_bounded
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

  def assert(condition, message)
    raise message unless condition
  end
end

PullRequestReviewTest.run!
