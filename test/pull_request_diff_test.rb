# frozen_string_literal: true

require_relative "../lib/hq/domain/pull_request_diff"

module PullRequestDiffTest
  module_function

  def run!
    assert_github_provider_fetches_current_diff_not_commit_patch
    assert_previous_diff_snapshots_are_not_fresh
    assert_legacy_snapshots_are_not_fresh
    puts "pull_request_diff_test: ok"
  end

  def assert_github_provider_fetches_current_diff_not_commit_patch
    provider = Class.new(HQ::PullRequestDiff::GitHubProvider) do
      attr_reader :commands

      def initialize
        super
        @commands = []
      end

      private

      def gh_output(*args)
        @commands << args
        <<~DIFF
          diff --git a/app/example.rb b/app/example.rb
          index 1111111..2222222 100644
          --- a/app/example.rb
          +++ b/app/example.rb
          @@ -1,2 +1,2 @@
          -old
          +new
        DIFF
      end
    end.new

    reference = HQ::PullRequestDiff::Reference.new(repository: "example/web", number: 123)
    diff, truncated = provider.patch(reference)

    assert(!truncated, "expected small diff payload to stay untruncated")
    assert(diff.include?("diff --git"), "expected provider to return diff text")
    assert(provider.commands.first == ["pr", "diff", "123", "--repo", "example/web", "--color", "never"],
           "expected GitHub provider to request the current PR diff, not per-commit patch output")
  end

  def assert_previous_diff_snapshots_are_not_fresh
    previous = {
      "diff_format" => "github_diff_v1",
      "head_sha" => "abc123",
      "remote_updated_at" => "2026-06-29T07:43:31Z"
    }
    metadata = {
      "head_sha" => "abc123",
      "remote_updated_at" => "2026-06-29T07:43:31Z"
    }

    assert(!HQ::PullRequestDiff.snapshot_summary(previous, metadata:)["fresh"],
           "expected previous diff-format snapshots to be stale so bad cached patch snapshots refetch")
  end

  def assert_legacy_snapshots_are_not_fresh
    legacy = {
      "head_sha" => "abc123",
      "remote_updated_at" => "2026-06-29T07:43:31Z"
    }
    current = legacy.merge("diff_format" => HQ::PullRequestDiff::DIFF_FORMAT)
    metadata = {
      "head_sha" => "abc123",
      "remote_updated_at" => "2026-06-29T07:43:31Z"
    }

    assert(!HQ::PullRequestDiff.snapshot_summary(legacy, metadata:)["fresh"],
           "expected unversioned snapshots to be stale because old PR patch snapshots overcounted commit diffs")
    assert(HQ::PullRequestDiff.snapshot_summary(current, metadata:)["fresh"],
           "expected current diff-format snapshots to be fresh when metadata matches")
  end

  def assert(condition, message)
    raise message unless condition
  end
end

PullRequestDiffTest.run!
