# frozen_string_literal: true

require "time"

module HQ
  module OpenAIModelPricing
    SOURCE_URL = "https://developers.openai.com/api/docs/pricing"
    PRICE_DATE = "2026-07-22"
    DEFAULT_PRICING_METADATA = {
      "source" => SOURCE_URL,
      "as_of" => PRICE_DATE
    }.freeze
    MODEL_PRICING_METADATA = {
      "gpt-6-astra" => {
        "source" => "https://developers.openai.com/api/docs/models/gpt-6-astra",
        "as_of" => "2026-09-07"
      }.freeze,
      "gpt-6-sol" => {
        "source" => "https://developers.openai.com/api/docs/models/gpt-6-sol",
        "as_of" => "2026-10-11"
      }.freeze,
      "gpt-6.1-sol" => {
        "source" => "https://developers.openai.com/api/docs/models/gpt-6.1-sol",
        "as_of" => "2026-10-11"
      }.freeze,
      "gpt-6-luna" => {
        "source" => "https://developers.openai.com/api/docs/models/gpt-6-luna",
        "as_of" => "2026-10-11"
      }.freeze
    }.freeze
    CURRENT_MODELS = %w[gpt-6.2-sol gpt-6.2-astra gpt-6.1-terra].freeze
    CURRENT_PRICE_DATE = "2026-11-27"
    TOKENS_PER_MILLION = 1_000_000.0

    PRICES_USD_PER_MILLION = {
      "gpt-6.2-sol" => [2.0, 0.1, 10.0],
      "gpt-6.2-astra" => [8.0, 0.4, 40.0],
      "gpt-6.1-terra" => [1.0, 0.05, 5.0],
      "gpt-6-astra" => [10.0, 1.0, 50.0],
      "gpt-6-sol" => [2.0, 0.2, 10.0],
      "gpt-6.1-sol" => [2.0, 0.1, 10.0],
      "gpt-6-luna" => [0.1, 0.01, 0.5],
      "gpt-5.6-sol" => [5.0, 0.5, 30.0],
      "gpt-5.6-terra" => [2.5, 0.25, 15.0],
      "gpt-5.6-luna" => [1.0, 0.1, 6.0],
      "gpt-5.5" => [5.0, 0.5, 30.0],
      "gpt-5.4" => [2.5, 0.25, 15.0],
      "gpt-5.4-mini" => [0.75, 0.075, 4.5],
      "gpt-5.3-codex" => [1.75, 0.175, 14.0],
      "gpt-5.2" => [1.75, 0.175, 14.0],
      "gpt-5.2-codex" => [1.75, 0.175, 14.0],
      "gpt-5.1" => [1.25, 0.125, 10.0],
      "gpt-5.1-codex" => [1.25, 0.125, 10.0],
      "gpt-5.1-codex-max" => [1.25, 0.125, 10.0],
      "gpt-5.1-codex-mini" => [0.25, 0.025, 2.0],
      "gpt-5" => [1.25, 0.125, 10.0],
      "gpt-5-codex" => [1.25, 0.125, 10.0],
      "codex-mini-latest" => [1.5, 0.375, 6.0]
    }.transform_values(&:freeze).freeze

    CACHE_WRITE_PRICES_USD_PER_MILLION = {
      "gpt-6.2-sol" => 2.5,
      "gpt-6.2-astra" => 10.0,
      "gpt-6.1-terra" => 1.25,
      "gpt-6-astra" => 12.5,
      "gpt-6-sol" => 2.5,
      "gpt-6.1-sol" => 2.5,
      "gpt-6-luna" => 0.125
    }.freeze

    MODEL_ALIASES = {
      "gpt-5.6" => "gpt-5.6-sol"
    }.freeze
    OPENAI_MODEL_PREFIX = "openai."

    module_function

    def estimate(model:, tokens:, pricing_context: {}, priced_at: nil)
      requested_model = model.to_s.strip.downcase
      price_model = price_model_for(requested_model)
      return unavailable(requested_model, "No OpenAI list price is recorded for model #{requested_model.inspect}") unless price_model

      token_counts = normalized_token_counts(tokens)
      return unavailable(requested_model, "Codex token usage is incomplete") unless token_counts

      input_rate, cached_rate, output_rate = PRICES_USD_PER_MILLION.fetch(price_model)
      cache_write_rate = CACHE_WRITE_PRICES_USD_PER_MILLION[price_model]
      context = pricing_context.is_a?(Hash) ? pricing_context : {}
      tier = context["service_tier"].to_s.downcase
      tier = "standard" if tier.empty? || %w[default auto].include?(tier)
      multiplier = tier_multiplier(price_model, tier, priced_at:)
      return unavailable(requested_model, "No #{tier} price is recorded for model #{requested_model.inspect}") unless multiplier

      retention = context["prompt_cache_retention"].to_s
      if !retention.empty? && !%w[30m 12h].include?(retention)
        return unavailable(requested_model, "No #{retention} cache-retention price is recorded")
      end
      if retention == "12h" && !CURRENT_MODELS.include?(price_model)
        return unavailable(requested_model, "No 12h cache-write price is recorded for model #{requested_model.inspect}")
      end
      cache_write_rate *= 2 if cache_write_rate && retention == "12h"
      input_rate *= multiplier
      cached_rate *= multiplier
      output_rate *= multiplier
      cache_write_rate *= multiplier if cache_write_rate
      cache_write_tokens = token_counts.fetch("cache_creation_input_tokens", 0)
      if cache_write_tokens.positive? && cache_write_rate.nil?
        return unavailable(requested_model, "No cache-write price is recorded for model #{requested_model.inspect}")
      end

      uncached_input = token_counts.fetch("input_tokens") - token_counts.fetch("cached_input_tokens")
      standard_uncached_input = uncached_input - cache_write_tokens
      amount = (
        (standard_uncached_input * input_rate) +
        (token_counts.fetch("cached_input_tokens") * cached_rate) +
        (token_counts.fetch("output_tokens") * output_rate)
      ) / TOKENS_PER_MILLION
      amount += (cache_write_tokens * cache_write_rate) / TOKENS_PER_MILLION if cache_write_rate

      pricing_metadata = pricing_metadata_for(price_model)
      pricing = {
        "model" => price_model,
        "input_usd_per_million" => input_rate,
        "cached_input_usd_per_million" => cached_rate,
        "output_usd_per_million" => output_rate,
        "source" => pricing_metadata.fetch("source"),
        "as_of" => pricing_metadata.fetch("as_of")
      }
      pricing["service_tier"] = tier
      pricing["assumptions"] = [
        "Short-context rates; cumulative usage does not identify per-request context length",
        "No regional uplift, background-window discount, or tool fees"
      ]
      if context["service_tier"].to_s.empty? || tier == "standard" && context["service_tier"].to_s.downcase == "auto"
        pricing["assumptions"] << "Standard processing; no explicit service tier was reported"
      end
      if retention.empty? && cache_write_tokens.positive?
        pricing["assumptions"] << "30-minute cache writes; no retention was reported"
      end
      pricing["prompt_cache_retention"] = retention.empty? ? "30m" : retention if cache_write_rate
      pricing["cache_write_usd_per_million"] = cache_write_rate if cache_write_rate

      {
        "amount_usd" => amount,
        "model" => requested_model,
        "pricing" => pricing
      }
    end

    def price_model_for(model)
      normalized = model.to_s.strip.downcase
      normalized = normalized.delete_prefix(OPENAI_MODEL_PREFIX)
      normalized = MODEL_ALIASES.fetch(normalized, normalized)
      return normalized if PRICES_USD_PER_MILLION.key?(normalized)

      base = normalized.sub(/-\d{4}-\d{2}-\d{2}\z/, "")
      base if PRICES_USD_PER_MILLION.key?(base)
    end

    def normalized_token_counts(tokens)
      return nil unless tokens.is_a?(Hash)

      values = %w[input_tokens cached_input_tokens output_tokens].to_h do |key|
        value = tokens[key]
        return nil unless value.is_a?(Numeric) && value.finite? && value >= 0

        [key, value]
      end
      cache_write_tokens = tokens["cache_creation_input_tokens"]
      unless cache_write_tokens.nil?
        return nil unless cache_write_tokens.is_a?(Numeric) && cache_write_tokens.finite? && cache_write_tokens >= 0

        values["cache_creation_input_tokens"] = cache_write_tokens
      end

      input_tokens = values.fetch("input_tokens")
      cached_input_tokens = values.fetch("cached_input_tokens")
      return nil if cached_input_tokens > input_tokens
      return nil if values.fetch("cache_creation_input_tokens", 0) > input_tokens - cached_input_tokens

      values
    end
    private_class_method :normalized_token_counts

    def tier_multiplier(model, tier, priced_at:)
      return 1.0 if tier == "standard"
      return nil unless CURRENT_MODELS.include?(model)

      if tier == "ultrafast" && model.start_with?("gpt-6.2-")
        timestamp = priced_at.is_a?(Time) ? priced_at : Time.iso8601(priced_at.to_s)
        return timestamp < Time.utc(2027, 3, 1, 8) ? 3.0 : 6.0
      end
      return 2.0 if %w[fast priority].include?(tier)
      return 0.5 if tier == "batch" || (tier == "flex" && model == "gpt-6.1-terra")

      nil
    rescue ArgumentError
      nil
    end
    private_class_method :tier_multiplier

    def pricing_context_for(metadata)
      values = metadata.is_a?(Hash) ? metadata : {}
      usage = values["usage"].is_a?(Hash) ? values["usage"] : {}
      %w[service_tier prompt_cache_retention].each_with_object({}) do |key, result|
        value = values[key] || usage[key]
        result[key] = value unless value.nil?
      end
    end

    def pricing_metadata_for(model)
      if CURRENT_MODELS.include?(model)
        return { "source" => "https://developers.openai.com/api/docs/models/#{model}", "as_of" => CURRENT_PRICE_DATE }
      end

      MODEL_PRICING_METADATA.fetch(model, DEFAULT_PRICING_METADATA)
    end
    private_class_method :pricing_metadata_for

    def unavailable(model, reason)
      { "amount_usd" => nil, "model" => model, "reason_unavailable" => reason }
    end
    private_class_method :unavailable
  end
end
