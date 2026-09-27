# frozen_string_literal: true

module RetiredFeatureRemovalTest
  module_function

  ROOT = File.expand_path("..", __dir__)
  SCAN_ROOTS = %w[AGENTS.md CHANGELOG.md CLAUDE.md bin config docs hq.gemspec lib test].freeze

  def run!
    assert_dedicated_components_are_absent
    assert_maintained_tree_has_no_retired_identifiers
    puts "retired_feature_removal_test: ok"
  end

  def assert_dedicated_components_are_absent
    alias_words = [[112, 101, 114, 115, 111, 110, 97, 108], [97, 115, 115, 105, 115, 116, 97, 110, 116]]
      .map { |bytes| bytes.pack("C*") }
    alias_name = alias_words.join("_")
    brand_name = [102, 114, 101, 100].pack("C*")
    paths = [
      File.join("lib", "hq", "domain", "#{alias_name}.rb"),
      File.join("config", "schemas", "#{alias_name}_result.json"),
      File.join("docs", "#{alias_name.upcase}.md"),
      File.join("lib", "hq", "remote_ui", "assets", "#{brand_name}-avatar.png")
    ]
    present = paths.select { |path| File.exist?(File.join(ROOT, path)) }
    raise "retired components remain: #{present.join(", ")}" unless present.empty?
  end

  def assert_maintained_tree_has_no_retired_identifiers
    brand_name = [102, 114, 101, 100].pack("C*")
    alias_words = [[112, 101, 114, 115, 111, 110, 97, 108], [97, 115, 115, 105, 115, 116, 97, 110, 116]]
      .map { |bytes| bytes.pack("C*") }
    proposal_words = %w[action proposals]
    forbidden = [
      /#{Regexp.escape(brand_name)}/i,
      /#{alias_words.map { |word| Regexp.escape(word) }.join("[- _]?")}/i,
      /#{proposal_words.map { |word| Regexp.escape(word) }.join("_")}/i
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
end

RetiredFeatureRemovalTest.run!
