# frozen_string_literal: true

module GitHubReviewCleanupTest
  module_function

  ROOT = File.expand_path("..", __dir__)
  RETIRED_REFERENCES = %w[
    PullRequestReview
    pull_request_review_store
    /github/auth
    TYCHO_GITHUB_APP_CLIENT_ID
    TYCHO_GITHUB_APP_SLUG
    TYCHO_GITHUB_APP_INSTALL_URL
    TYCHO_GITHUB_AUTH_PATH
    TYCHO_GITHUB_WRITE_ENABLED
    GithubLogin
    GithubStatus
    GithubLogout
  ].freeze

  def run!
    paths = %w[lib bin docs README.md .env.sample].flat_map do |entry|
      path = File.join(ROOT, entry)
      File.directory?(path) ? Dir.glob(File.join(path, "**", "*")) : [path]
    end.select { |path| File.file?(path) }

    matches = RETIRED_REFERENCES.flat_map do |reference|
      paths.filter_map do |path|
        next unless File.read(path).include?(reference)

        "#{reference}: #{path.delete_prefix("#{ROOT}/")}"
      end
    end
    raise "Retired GitHub App/review references remain:\n#{matches.join("\n")}" unless matches.empty?

    puts "github_review_cleanup_test: ok"
  end
end

GitHubReviewCleanupTest.run! if $PROGRAM_NAME == __FILE__
