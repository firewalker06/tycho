# frozen_string_literal: true

require_relative "../lib/hq/domain/openai_model_pricing"

module OpenAIModelPricingTest
  module_function

  def run!
    assert_prices_card_926_models_and_tiers
    assert_prices_uncached_cached_and_output_tokens
    assert_prices_gpt_6_astra_cache_writes
    assert_prices_current_gpt_6_catalog
    assert_ignores_reasoning_token_breakdown
    assert_resolves_aliases_and_snapshots
    assert_rejects_unknown_models_and_invalid_usage
    puts "openai_model_pricing_test: ok"
  end

  def assert_prices_card_926_models_and_tiers
    tokens = { "input_tokens" => 1_000, "cached_input_tokens" => 100,
               "cache_creation_input_tokens" => 200, "output_tokens" => 100 }
    {
      "gpt-6.2-sol" => [0.00291, 2.0, 0.1, 2.5, 10.0],
      "gpt-6.2-astra" => [0.01164, 8.0, 0.4, 10.0, 40.0],
      "gpt-6.1-terra" => [0.001455, 1.0, 0.05, 1.25, 5.0]
    }.each do |model, (amount, input, cached, write, output)|
      result = HQ::OpenAIModelPricing.estimate(model:, tokens:)
      assert((result["amount_usd"] - amount).abs < 1e-12, "expected #{model} cache-aware cost")
      assert(result["pricing"].values_at("input_usd_per_million", "cached_input_usd_per_million",
                                       "cache_write_usd_per_million", "output_usd_per_million") ==
             [input, cached, write, output], "expected all four #{model} rates")
      assert(result.dig("pricing", "as_of") == "2026-11-27", "expected verified date")
      assert(result.dig("pricing", "source").end_with?("/models/#{model}"), "expected model source")
      assert(result.dig("pricing", "assumptions").any? { |text| text.include?("Standard processing") },
             "expected missing tier assumption")
      %w[fast priority batch default].each do |tier|
        multiplier = { "fast" => 2, "priority" => 2, "batch" => 0.5, "default" => 1 }.fetch(tier)
        tiered = HQ::OpenAIModelPricing.estimate(model:, tokens:, pricing_context: { "service_tier" => tier })
        assert((tiered["amount_usd"] - amount * multiplier).abs < 1e-12, "expected #{model} #{tier} rate")
      end
      retained = HQ::OpenAIModelPricing.estimate(model:, tokens:,
                                                pricing_context: { "prompt_cache_retention" => "12h" })
      assert((retained["amount_usd"] - amount - 200 * write / 1_000_000).abs < 1e-12,
             "expected 12-hour writes to replace 30-minute writes")
      assert(HQ::OpenAIModelPricing.price_model_for("openai.#{model}-2026-11-27") == model,
             "expected qualified dated model resolution")
      no_cache = HQ::OpenAIModelPricing.estimate(model:, tokens: tokens.merge(
        "cached_input_tokens" => 0, "cache_creation_input_tokens" => 0))
      assert((no_cache["amount_usd"] - (1_000 * input + 100 * output) / 1_000_000).abs < 1e-12,
             "expected #{model} uncached cost")
    end
    %w[gpt-6.2-sol gpt-6.2-astra].each do |model|
      standard = HQ::OpenAIModelPricing.estimate(model:, tokens:)["amount_usd"]
      { "2027-03-01T07:59:59Z" => 3, "2027-03-01T08:00:00Z" => 6 }.each do |date, multiplier|
        result = HQ::OpenAIModelPricing.estimate(model:, tokens:, priced_at: date,
                                                pricing_context: { "service_tier" => "ultrafast" })
        assert((result["amount_usd"] - standard * multiplier).abs < 1e-12,
               "expected Ultrafast promotion boundary in Pacific time")
      end
    end
    flex = HQ::OpenAIModelPricing.estimate(model: "gpt-6.1-terra", tokens:,
                                          pricing_context: { "service_tier" => "flex" })
    assert((flex["amount_usd"] - 0.001455 / 2).abs < 1e-12, "expected Terra Flex rate")
    %w[flex ultrafast reserved unknown].each do |tier|
      result = HQ::OpenAIModelPricing.estimate(model: "gpt-6.2-sol", tokens:,
                                              pricing_context: { "service_tier" => tier })
      assert(result["amount_usd"].nil? && result["reason_unavailable"].include?(tier),
             "expected unsupported #{tier} to stay unpriced")
    end
    %w[gpt-6.1-astra gpt-6.2 gpt-6.2-private].each do |model|
      assert(HQ::OpenAIModelPricing.estimate(model:, tokens:)["amount_usd"].nil?,
             "expected unverified ID #{model} to stay unpriced")
    end
    bad_retention = HQ::OpenAIModelPricing.estimate(model: "gpt-6.2-sol", tokens:,
                                                  pricing_context: { "prompt_cache_retention" => "24h" })
    assert(bad_retention["amount_usd"].nil?, "expected unsupported retention to stay unpriced")
    nested = HQ::OpenAIModelPricing.pricing_context_for(
      "service_tier" => "priority", "usage" => { "service_tier" => "batch", "prompt_cache_retention" => "12h" }
    )
    assert(nested == { "service_tier" => "priority", "prompt_cache_retention" => "12h" },
           "expected top-level precedence with nested retention")
    result = HQ::OpenAIModelPricing.estimate(model: "gpt-5.5", tokens:)
    assert(result["amount_usd"].nil?, "expected unavailable legacy cache-write rate")
  end

  def assert_prices_gpt_6_astra_cache_writes
    estimate = HQ::OpenAIModelPricing.estimate(
      model: "gpt-6-astra",
      tokens: {
        "input_tokens" => 1_000,
        "cached_input_tokens" => 100,
        "cache_creation_input_tokens" => 200,
        "output_tokens" => 100
      }
    )

    assert((estimate["amount_usd"] - 0.0146).abs < 0.000_000_001,
           "expected Astra cache writes to replace the standard uncached-input rate")
    assert(estimate.dig("pricing", "input_usd_per_million") == 10.0,
           "expected the official Astra input price")
    assert(estimate.dig("pricing", "cached_input_usd_per_million") == 1.0,
           "expected the official Astra cached-input price")
    assert(estimate.dig("pricing", "cache_write_usd_per_million") == 12.5,
           "expected the official Astra cache-write price")
    assert(estimate.dig("pricing", "output_usd_per_million") == 50.0,
           "expected the official Astra output price")
    assert(estimate.dig("pricing", "source") == "https://developers.openai.com/api/docs/models/gpt-6-astra",
           "expected Astra's model-specific pricing provenance")
    assert(estimate.dig("pricing", "as_of") == "2026-09-07",
           "expected Astra's pricing date")
    assert(HQ::OpenAIModelPricing.price_model_for("gpt-6-astra-2026-09-07") == "gpt-6-astra",
           "expected dated Astra snapshots to use Astra pricing")
  end

  def assert_prices_current_gpt_6_catalog
    {
      "gpt-6-sol" => [2.0, 0.2, 2.5, 10.0, 0.00292],
      "gpt-6.1-sol" => [2.0, 0.1, 2.5, 10.0, 0.00291],
      "gpt-6-luna" => [0.1, 0.01, 0.125, 0.5, 0.000146]
    }.each do |model, (input_rate, cached_rate, cache_write_rate, output_rate, expected_amount)|
      estimate = HQ::OpenAIModelPricing.estimate(
        model:,
        tokens: {
          "input_tokens" => 1_000,
          "cached_input_tokens" => 100,
          "cache_creation_input_tokens" => 200,
          "output_tokens" => 100
        }
      )

      assert((estimate["amount_usd"] - expected_amount).abs < 0.000_000_001,
             "expected #{model} to price uncached, cached, cache-write, and output tokens")
      assert(estimate.dig("pricing", "input_usd_per_million") == input_rate,
             "expected the official #{model} input price")
      assert(estimate.dig("pricing", "cached_input_usd_per_million") == cached_rate,
             "expected the official #{model} cached-input price")
      assert(estimate.dig("pricing", "cache_write_usd_per_million") == cache_write_rate,
             "expected the official #{model} cache-write price")
      assert(estimate.dig("pricing", "output_usd_per_million") == output_rate,
             "expected the official #{model} output price")
      assert(estimate.dig("pricing", "source") ==
             "https://developers.openai.com/api/docs/models/#{model}",
             "expected #{model}'s model-specific pricing provenance")
      assert(estimate.dig("pricing", "as_of") == "2026-10-11",
             "expected #{model}'s pricing date")
      assert(HQ::OpenAIModelPricing.price_model_for("#{model}-2026-10-11") == model,
             "expected dated #{model} snapshots to use #{model} pricing")
    end

    assert(HQ::OpenAIModelPricing.price_model_for("gpt-reserve").nil?,
           "expected a catalog-only model without an official API price to remain unpriced")
  end

  def assert_prices_uncached_cached_and_output_tokens
    estimate = HQ::OpenAIModelPricing.estimate(
      model: "gpt-5.5",
      tokens: {
        "input_tokens" => 1_000,
        "cached_input_tokens" => 400,
        "output_tokens" => 100
      }
    )

    assert((estimate["amount_usd"] - 0.0062).abs < 0.000_000_001,
           "expected cached tokens to be removed from full-price input")
    assert(estimate.dig("pricing", "input_usd_per_million") == 5.0,
           "expected the official GPT-5.5 input price")
    assert(estimate.dig("pricing", "source") == HQ::OpenAIModelPricing::SOURCE_URL,
           "expected pricing provenance")
  end

  def assert_ignores_reasoning_token_breakdown
    base = {
      "input_tokens" => 100,
      "cached_input_tokens" => 20,
      "output_tokens" => 40
    }
    without_reasoning = HQ::OpenAIModelPricing.estimate(model: "gpt-5.4", tokens: base)
    with_reasoning = HQ::OpenAIModelPricing.estimate(
      model: "gpt-5.4",
      tokens: base.merge("reasoning_output_tokens" => 30)
    )

    assert(with_reasoning["amount_usd"] == without_reasoning["amount_usd"],
           "expected reasoning tokens to remain part of output_tokens rather than a second charge")
  end

  def assert_resolves_aliases_and_snapshots
    assert(HQ::OpenAIModelPricing.price_model_for("gpt-5.6") == "gpt-5.6-sol",
           "expected the GPT-5.6 alias to use Sol pricing")
    assert(HQ::OpenAIModelPricing.price_model_for("openai.gpt-5.6-sol") == "gpt-5.6-sol",
           "expected an OpenAI-qualified custom model to use the canonical price")
    assert(HQ::OpenAIModelPricing.price_model_for("openai.gpt-5.6") == "gpt-5.6-sol",
           "expected aliases to resolve after removing an OpenAI qualifier")
    assert(HQ::OpenAIModelPricing.price_model_for("gpt-5.5-2026-04-23") == "gpt-5.5",
           "expected dated snapshots to use their base model price")
  end

  def assert_rejects_unknown_models_and_invalid_usage
    unknown = HQ::OpenAIModelPricing.estimate(
      model: "codex-auto-review",
      tokens: { "input_tokens" => 10, "cached_input_tokens" => 0, "output_tokens" => 1 }
    )
    unknown_qualified = HQ::OpenAIModelPricing.estimate(
      model: "openai.private-model",
      tokens: { "input_tokens" => 10, "cached_input_tokens" => 0, "output_tokens" => 1 }
    )
    invalid = HQ::OpenAIModelPricing.estimate(
      model: "gpt-5.5",
      tokens: { "input_tokens" => 10, "cached_input_tokens" => 11, "output_tokens" => 1 }
    )

    assert(unknown["amount_usd"].nil?, "expected unknown internal models to remain unpriced")
    assert(unknown["reason_unavailable"].include?("No OpenAI list price"),
           "expected an explicit unknown-model reason")
    assert(unknown_qualified["amount_usd"].nil? &&
           unknown_qualified["reason_unavailable"].include?("openai.private-model"),
           "expected unknown qualified models to stay unpriced with their configured attribution")
    assert(invalid["amount_usd"].nil?, "expected inconsistent token usage to remain unpriced")
  end

  def assert(condition, message)
    raise message unless condition
  end
end

OpenAIModelPricingTest.run! if $PROGRAM_NAME == __FILE__
