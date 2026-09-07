# frozen_string_literal: true

module HQ
  module HarnessExecution
    RUBY_LOADER_ENVIRONMENT_KEYS = %w[
      BUNDLE_BIN_PATH
      BUNDLE_GEMFILE
      BUNDLER_SETUP
      BUNDLER_VERSION
      GEM_HOME
      GEM_PATH
      RUBYLIB
      RUBYOPT
    ].freeze
    SERVER_ONLY_ENVIRONMENT_KEYS = %w[
      TYCHO_GITHUB_TOKEN
      TYCHO_REMOTE_TOKEN
    ].freeze

    module_function

    def environment(overrides = {})
      sanitized = RUBY_LOADER_ENVIRONMENT_KEYS.to_h { |key| [key, nil] }
      sanitized.merge!(overrides.to_h)
      SERVER_ONLY_ENVIRONMENT_KEYS.each { |key| sanitized[key] = nil }
      sanitized
    end

    def command_environment(overrides = {})
      environment(overrides).reject { |_key, value| value.nil? }
    end
  end
end
