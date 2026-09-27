# frozen_string_literal: true

require_relative "../lib/hq/domain/visibility"

module RetiredFeatureRemovalTest
  module_function

  ROOT = File.expand_path("..", __dir__)
  SCAN_ROOTS = %w[AGENTS.md CHANGELOG.md CLAUDE.md bin config docs hq.gemspec lib test].freeze
  RETIRED_FEATURE_WORDS = [[112, 101, 114, 115, 111, 110, 97, 108], [97, 115, 115, 105, 115, 116, 97, 110, 116]]
    .map { |bytes| bytes.pack("C*") }
    .freeze
  RETIRED_FEATURE_ALIAS = RETIRED_FEATURE_WORDS.join("_").freeze
  RETIRED_BRAND_NAME = [102, 114, 101, 100].pack("C*").freeze
  RETIRED_RESULT_FIELD_WORDS = %w[action proposals].freeze

  def run!
    assert_dedicated_components_are_absent
    assert_legacy_agents_remain_hidden
    assert_maintained_tree_has_no_retired_identifiers
    puts "retired_feature_removal_test: ok"
  end

  def assert_dedicated_components_are_absent
    paths = [
      File.join("lib", "hq", "domain", "#{RETIRED_FEATURE_ALIAS}.rb"),
      File.join("config", "schemas", "#{RETIRED_FEATURE_ALIAS}_result.json"),
      File.join("docs", "#{RETIRED_FEATURE_ALIAS.upcase}.md"),
      File.join("lib", "hq", "remote_ui", "assets", "#{RETIRED_BRAND_NAME}-avatar.png")
    ]
    present = paths.select { |path| File.exist?(File.join(ROOT, path)) }
    raise "retired components remain: #{present.join(", ")}" unless present.empty?
  end

  def assert_legacy_agents_remain_hidden
    agent = Struct.new(:project_key, :role).new("legacy", "#{RETIRED_FEATURE_ALIAS}_daily")
    assert(HQ::Visibility.visible_agents([agent], []).empty?, "expected retired agent records to stay hidden")
    assert(!HQ::Visibility.agent_visible?(agent, []), "expected retired agent record to remain inaccessible")
  end

  def assert_maintained_tree_has_no_retired_identifiers
    forbidden = [
      /#{Regexp.escape(RETIRED_BRAND_NAME)}/i,
      /#{RETIRED_FEATURE_WORDS.map { |word| Regexp.escape(word) }.join("[- _]?")}/i,
      /#{RETIRED_RESULT_FIELD_WORDS.map { |word| Regexp.escape(word) }.join("_")}/i
    ]
    matches = maintained_files.filter_map do |path|
      content = File.binread(path).encode("UTF-8", invalid: :replace, undef: :replace)
      next unless forbidden.any? { |pattern| content.match?(pattern) }

      path.delete_prefix("#{ROOT}/")
    end
    raise "retired identifiers remain in maintained files: #{matches.join(", ")}" unless matches.empty?
  end

  def maintained_files
    SCAN_ROOTS.flat_map do |entry|
      path = File.join(ROOT, entry)
      File.file?(path) ? [path] : Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).select { |candidate| File.file?(candidate) }
    end
  end

  def assert(condition, message)
    raise message unless condition
  end
end

RetiredFeatureRemovalTest.run!
