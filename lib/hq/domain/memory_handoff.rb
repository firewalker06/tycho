# frozen_string_literal: true

module HQ
  # The semantic part of a successful run's Second Brain record. Provenance
  # remains on AgentRun so consumers cannot mistake agent-declared data for it.
  class MemoryHandoff
    REQUIRED_FIELDS = %w[outcome decisions continuing_context references].freeze
    OPTIONAL_FIELDS = %w[lessons promotion_candidates].freeze
    FIELDS = (REQUIRED_FIELDS + OPTIONAL_FIELDS).freeze

    def self.normalize(value)
      return nil unless value.is_a?(Hash)
      return nil unless (value.keys - FIELDS).empty? && (REQUIRED_FIELDS - value.keys).empty?

      outcome = value["outcome"]
      continuing_context = value["continuing_context"]
      return nil unless outcome.is_a?(String) && !outcome.strip.empty? && continuing_context.is_a?(String)

      result = {
        "outcome" => outcome.strip,
        "decisions" => string_list(value["decisions"]),
        "continuing_context" => continuing_context.strip,
        "references" => string_list(value["references"])
      }
      return nil if result.values_at("decisions", "references").any?(&:nil?)

      OPTIONAL_FIELDS.each do |field|
        next unless value.key?(field)

        result[field] = string_list(value[field])
        return nil unless result[field]
      end
      result
    end

    def self.valid?(value)
      !normalize(value).nil?
    end

    def self.string_list(value)
      return nil unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) }

      value.map(&:strip)
    end
    private_class_method :string_list
  end
end
