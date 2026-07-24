# frozen_string_literal: true

require_relative "../lib/hq/domain/openai_model_pricing"

module OpenAIModelPricingTest
  module_function

  def run!
    assert_prices_uncached_cached_and_output_tokens
    assert_ignores_reasoning_token_breakdown
    assert_resolves_aliases_and_snapshots
    assert_rejects_unknown_models_and_invalid_usage
    puts "openai_model_pricing_test: ok"
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
    assert(HQ::OpenAIModelPricing.price_model_for("gpt-5.5-2026-04-23") == "gpt-5.5",
           "expected dated snapshots to use their base model price")
  end

  def assert_rejects_unknown_models_and_invalid_usage
    unknown = HQ::OpenAIModelPricing.estimate(
      model: "codex-auto-review",
      tokens: { "input_tokens" => 10, "cached_input_tokens" => 0, "output_tokens" => 1 }
    )
    invalid = HQ::OpenAIModelPricing.estimate(
      model: "gpt-5.5",
      tokens: { "input_tokens" => 10, "cached_input_tokens" => 11, "output_tokens" => 1 }
    )

    assert(unknown["amount_usd"].nil?, "expected unknown internal models to remain unpriced")
    assert(unknown["reason_unavailable"].include?("No OpenAI list price"),
           "expected an explicit unknown-model reason")
    assert(invalid["amount_usd"].nil?, "expected inconsistent token usage to remain unpriced")
  end

  def assert(condition, message)
    raise message unless condition
  end
end

OpenAIModelPricingTest.run! if $PROGRAM_NAME == __FILE__
