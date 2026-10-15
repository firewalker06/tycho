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
  VISUAL_BRAND_DOCS = %w[AGENTS.md docs/CONVERSATION_ANIMATIONS.md docs/PROJECT_STATUS.md].freeze
  VISUAL_BRAND_ASSETS = %w[lib/hq/remote_ui/assets/app.js lib/hq/remote_ui/assets/app.css].freeze

  def run!
    assert_dedicated_components_are_absent
    assert_legacy_agents_remain_hidden
    assert_visual_brand_exception_is_narrow
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
    matches = maintained_files.filter_map do |path|
      content = File.binread(path).encode("UTF-8", invalid: :replace, undef: :replace)
      relative_path = path.delete_prefix("#{ROOT}/")
      relative_path if retired_identifiers?(content, relative_path)
    end
    raise "retired identifiers remain in maintained files: #{matches.join(", ")}" unless matches.empty?
  end

  def retired_identifiers?(content, relative_path)
    forbidden = [
      /#{Regexp.escape(RETIRED_BRAND_NAME)}/i,
      /#{RETIRED_FEATURE_WORDS.map { |word| Regexp.escape(word) }.join("[- _]?")}/i,
      /#{RETIRED_RESULT_FIELD_WORDS.map { |word| Regexp.escape(word) }.join("_")}/i
    ]
    # Card 320 reuses only the historical face, not the removed assistant.
    brand_content = content
    if VISUAL_BRAND_DOCS.include?(relative_path)
      brand_content = content.gsub(RETIRED_BRAND_NAME.upcase, "").gsub("#{RETIRED_BRAND_NAME}-avatar.png", "")
    elsif VISUAL_BRAND_ASSETS.include?(relative_path)
      brand_content = content.gsub(/\b(?:conversation-#{RETIRED_BRAND_NAME}|#{RETIRED_BRAND_NAME}-(?:face|eyes|smile|glint|signal|scan|nod))\b/, "")
      brand_content = brand_content.gsub("#{RETIRED_BRAND_NAME.upcase}'s content palette", "")
    end
    brand_content.match?(forbidden.first) || forbidden.drop(1).any? { |pattern| content.match?(pattern) }
  end

  def assert_visual_brand_exception_is_narrow
    asset = VISUAL_BRAND_ASSETS.first
    assert(!retired_identifiers?("conversation-#{RETIRED_BRAND_NAME} #{RETIRED_BRAND_NAME}-face", asset), "expected visual identifiers to be permitted")
    assert(retired_identifiers?("/api/#{RETIRED_BRAND_NAME}/sessions", asset), "retired routes must remain forbidden")
    assert(retired_identifiers?(RETIRED_FEATURE_ALIAS, VISUAL_BRAND_DOCS.first), "retired feature identifiers must remain forbidden in visual docs")
    assert(retired_identifiers?(RETIRED_BRAND_NAME, "lib/hq/domain/example.rb"), "brand exception must not reach domain code")
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
