# frozen_string_literal: true

require_relative "constants"

module HQ
  module VersionLookup
    module_function

    def fetch_latest_gem_version(gem_name)
      uri = URI.parse("https://rubygems.org/api/v1/versions/#{gem_name}.json")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 2
      http.read_timeout = 3

      response = http.get(uri.request_uri)
      return nil unless response.code.to_s == "200"

      versions = JSON.parse(response.body)
      stable = versions.find { |version| !version["prerelease"] }
      stable&.dig("number")
    rescue StandardError
      nil
    end
  end
end
