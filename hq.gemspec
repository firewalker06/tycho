# frozen_string_literal: true

require_relative "lib/hq/version"

Gem::Specification.new do |spec|
  spec.name = "hq"
  spec.version = HQ::VERSION
  spec.authors = ["HQ contributors"]
  spec.summary = "Local-first dashboard for Kamal projects and managed coding agents."
  spec.description = "HQ provides a Ruby TUI and local Remote UI for monitoring Kamal projects and supervising managed coding agents."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.bindir = "bin"
  spec.executables = %w[tycho]
  spec.require_paths = ["lib"]
  spec.files = Dir.glob("lib/**/*.rb") +
               Dir.glob("lib/hq/remote_ui/**/*").select { |path| File.file?(path) } +
               Dir.glob("bin/*") +
               %w[
                 CHANGELOG.md
                 CODE_OF_CONDUCT.md
                 CONTRIBUTING.md
                 LICENSE
                 README.md
                 SECURITY.md
                 config/hooks.example.yml
                 config/hq.yml.example
                 config/schemas/agent_result.json
                 config/system_prompts.yml.example
               ]

  spec.add_dependency "bubbles"
  spec.add_dependency "bubbletea"
  spec.add_dependency "dry-cli"
  spec.add_dependency "glamour"
  spec.add_dependency "lipgloss"
  spec.add_dependency "logger"
  spec.add_dependency "net-http"
  spec.add_dependency "rqrcode"
  spec.add_dependency "uri"
  spec.add_dependency "web-push", "~> 3.1"
  spec.add_dependency "yaml"
end
