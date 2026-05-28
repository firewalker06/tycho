# frozen_string_literal: true

require "rbconfig"
require "rubygems"

module TychoLipglossLoader
  module_function

  def compat_backend?
    backend = ENV["TYCHO_LIPGLOSS_BACKEND"].to_s.downcase
    return true if %w[compat pure ruby].include?(backend)
    return false if %w[native go].include?(backend)
    return true if ENV["TYCHO_PURE_RUBY_LIPGLOSS"] == "1"

    darwin_amd64?
  end

  def darwin_amd64?
    cpu = RbConfig::CONFIG["host_cpu"].to_s
    os = RbConfig::CONFIG["host_os"].to_s
    os.include?("darwin") && cpu.match?(/\A(?:x86_64|amd64)\z/)
  end

  def load_native
    spec = Gem::Specification.find_by_name("lipgloss")
    load File.join(spec.full_gem_path, "lib", "lipgloss.rb")
  end
end

if TychoLipglossLoader.compat_backend?
  require_relative "hq/lipgloss_compat"
else
  TychoLipglossLoader.load_native
end
