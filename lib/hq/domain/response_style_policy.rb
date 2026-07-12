# frozen_string_literal: true

require_relative "constants"

module HQ
  module ResponseStylePolicy
    module_function

    def resolve(override = nil, path: default_path)
      return "" if override == false

      custom = override.to_s.strip
      return custom unless custom.empty?

      File.read(path, mode: "r:UTF-8").strip
    rescue StandardError => e
      HQ.logger.warn("ResponseStylePolicy") { "Failed to load #{path}: #{e.class} - #{e.message}" }
      ""
    end

    def default_path
      configured = HQ.env_present("RESPONSE_STYLE_PATH")
      File.expand_path(configured || HQ.default_response_style_path)
    end

    def path
      configured = HQ.env_present("RESPONSE_STYLE_PATH")
      File.expand_path(configured || File.join(HQ::USER_CONFIG_DIR, "response_style.md"))
    end
  end
end
