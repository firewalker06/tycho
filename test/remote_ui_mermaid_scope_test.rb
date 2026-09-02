# frozen_string_literal: true

module RemoteUIMermaidScopeTest
  module_function

  APP_PATH = File.expand_path("../lib/hq/remote_ui/assets/app.js", __dir__)

  def run!
    javascript = File.read(APP_PATH)
    assert_mermaid_stays_code_until_preview(javascript)
    assert_mermaid_menu_offers_preview(javascript)
    assert_preview_targets_one_code_block(javascript)
    assert_preview_can_restore_code(javascript)
    puts "remote_ui_mermaid_scope_test: ok"
  end

  def assert_mermaid_stays_code_until_preview(javascript)
    renderer = function_source(javascript, "prepareMarkdownCodeBlocks")
    assert(!renderer.include?("allowMermaid"),
           "expected Mermaid fences to stay code on every Markdown surface")
    assert(renderer.include?("code.classList.contains(\"language-mermaid\")"),
           "expected Mermaid fences to be identified for code-block actions")
    assert(!renderer.include?("diagram.className = \"mermaid\""),
           "expected Markdown preparation not to render Mermaid automatically")
  end

  def assert_mermaid_menu_offers_preview(javascript)
    menu = function_source(javascript, "renderMarkdownCodeMenu")
    assert(menu.include?("Preview chart"), "expected Mermaid code menus to offer Preview chart")
    assert(menu.include?("data-preview-mermaid-code"), "expected a dedicated Mermaid preview action")
  end

  def assert_preview_targets_one_code_block(javascript)
    preview = function_source(javascript, "previewMermaidCodeBlock")
    assert(preview.include?("window.mermaid.run({ nodes: [diagram] })"),
           "expected Mermaid preview to render only the selected diagram")
    assert(!javascript.include?("queueMermaidRendering();"),
           "expected no global Mermaid rendering queue")
  end

  def assert_preview_can_restore_code(javascript)
    menu = function_source(javascript, "renderMarkdownCodeMenu")
    restore = function_source(javascript, "showMermaidCodeBlock")
    toggle = function_source(javascript, "toggleMarkdownCodeMenu")

    assert(menu.include?("Show code"), "expected previewed Mermaid menus to offer Show code")
    assert(restore.include?("pre.hidden = false"), "expected Show code to restore the source fence")
    assert(toggle.include?("popover.hidden = false"), "expected code menus to open without a full view render")
  end

  def function_source(javascript, name)
    source = javascript[/function #{Regexp.escape(name)}\b.*?^}/m]
    raise "missing #{name}" unless source

    source
  end

  def assert(condition, message)
    raise message unless condition
  end
end

RemoteUIMermaidScopeTest.run! if $PROGRAM_NAME == __FILE__
