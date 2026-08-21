# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

module RemoteUIAssetSnapshotTest
  module_function

  ROOT = File.expand_path("..", __dir__)

  def run!
    assert_loaded_daemon_keeps_one_asset_build
    assert_handoff_retry_key_is_cleared_after_success
    assert_delegation_ui_uses_typed_safe_references
    assert_delegation_callbacks_are_chronological_events
    assert_archived_agents_are_reference_only_and_read_only
    assert_agent_status_icons_use_lucide_without_badges
    puts "remote_ui_asset_snapshot_test: ok"
  end

  def assert_agent_status_icons_use_lucide_without_badges
    javascript = File.read(File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.js"))
    css = File.read(File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.css"))
    helpers = File.read(File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app_helpers.js"))
    required = [
      "pause:",
      "check:",
      "ban:",
      '<rect width="4" height="16" x="14" y="4" rx="1"></rect>',
      '<path d="M20 6 9 17l-5-5"></path>',
      '<path d="m4.9 4.9 14.2 14.2"></path>',
      'return "pause"',
      'return "check"',
      'return "ban"',
      'case "no_action_needed":',
      "function agentListStatusIcon(agent)",
      'label: "Scheduled agent", role: "scheduled"',
      ".agent-status-icon.done",
      ".agent-status-icon.fail",
      "color: var(--muted);",
      'role="img" aria-label="${escapeAttr(label)}" title="${escapeAttr(label)}"',
      "function agentStatusIcon(status, label",
      ".agent-status-icon {"
    ]
    missing = required.reject { |fragment| javascript.include?(fragment) || css.include?(fragment) }
    raise "missing exact Lucide status icon contract: #{missing.join(", ")}" unless missing.empty?

    forbidden = ["✅", "⏸️", "🚫"]
    present = forbidden.select { |emoji| javascript.include?(emoji) || helpers.include?(emoji) }
    raise "status icons must not use emoji: #{present.join(", ")}" unless present.empty?

    icon_renderer = javascript[/function agentStatusIcon\(status, label.*?^}/m]
    raise "missing agent status indicator renderer" unless icon_renderer
    raise "status icon renderer must not emit badge styling" if icon_renderer.include?("ui-badge")

    icon_styles = css[/\.agent-status-icon \{.*?^}/m]
    raise "missing standalone status icon styles" unless icon_styles
    forbidden_styles = %w[background border padding border-radius]
    styled = forbidden_styles.select { |property| icon_styles.include?(property) }
    raise "status icon styles must not create a badge: #{styled.join(", ")}" unless styled.empty?
  end

  def assert_delegation_callbacks_are_chronological_events
    javascript = File.read(File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.js"))
    css = File.read(File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.css"))
    required = [
      "block?.metadata?.delegation_callback === true",
      "renderDelegationCallbackBlock(block, index, options)",
      'class="message delegation-callback-event"',
      "Number(report.child_run_number)",
      'success: "succeeded"',
      "renderDelegationReferenceLink(reference)",
      'iconSvg("squareArrowOutUpRight")',
      'class="delegation-callback-excerpt"',
      'aria-label="Copy report details"',
      "Report details"
    ]
    missing = required.reject { |fragment| javascript.include?(fragment) }
    raise "missing chronological callback presentation: #{missing.join(", ")}" unless missing.empty?
    raise "missing callback event styling" unless css.include?(".delegation-callback-event")
    raise "missing three-line callback excerpt" unless css.include?("-webkit-line-clamp: 3")
    callback_source = javascript[/function renderDelegationCallbackBlock.*?^}/m]
    raise "missing callback renderer" unless callback_source
    raise "callback must not repeat the full agent card" if callback_source.include?("renderAgentReference(reference)")
  end

  def assert_archived_agents_are_reference_only_and_read_only
    javascript = File.read(File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.js"))
    required = [
      'if (!agent?.unread || agent.archived) return',
      'agent?.archived) return { dock: "", overlay: "" }'
    ]
    missing = required.reject { |fragment| javascript.include?(fragment) }
    raise "missing archived-agent read-only contracts: #{missing.join(", ")}" unless missing.empty?

    forbidden = ["data-filter-agent-state", "loadArchivedAgents", "/agents/archived?"]
    present = forbidden.select { |fragment| javascript.include?(fragment) }
    raise "archived agents must not be browsable from Agents: #{present.join(", ")}" unless present.empty?
  end

  def assert_delegation_ui_uses_typed_safe_references
    javascript = File.read(File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.js"))
    required = [
      'block?.metadata?.agent_reference',
      'escapeHtml(label)',
      'escapeAttr(reference.key)',
      'delegationOrderedAgents(agents)',
      'data-set-delegation-connection',
      'iconSvg(connected ? "unlink" : "link")',
      'renderAgentReference(reference, { embedded: true, relationshipRole })',
      'function updateDelegationConnection',
      '/delegation`, { connected: nextConnected }',
      'agent?.archived) return { dock: "", overlay: "" }'
    ]
    missing = required.reject { |fragment| javascript.include?(fragment) }
    raise "missing typed delegation UI safety contracts: #{missing.join(", ")}" unless missing.empty?

    raise "agent lookalike text must not be linkified" if javascript.include?("linkifyAgent")
  end

  def assert_handoff_retry_key_is_cleared_after_success
    javascript = File.read(File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.js"))
    response_index = javascript.index("const response = await apiPost(`/pull-requests/${encodeURIComponent(id)}/handoff`")
    clear_index = javascript.index("delete form.dataset.handoffIdempotencyKey", response_index)
    raise "expected a successful handoff to clear its retry key" unless response_index && clear_index && clear_index > response_index
  end

  def assert_loaded_daemon_keeps_one_asset_build
    Dir.mktmpdir("tycho-remote-ui-snapshot") do |dir|
      lib_dir = File.join(dir, "lib", "hq")
      FileUtils.mkdir_p(lib_dir)
      FileUtils.cp(File.join(ROOT, "lib", "hq", "remote_ui.rb"), lib_dir)
      FileUtils.cp_r(File.join(ROOT, "lib", "hq", "remote_ui"), lib_dir)

      script = <<~'RUBY'
        require "hq/remote_ui"

        loaded_js = HQ::RemoteUI.js
        loaded_version = HQ::RemoteUI.asset_version
        File.write(HQ::RemoteUI::JS_PATH, "#{loaded_js}\n// simulated update\n")

        abort "running daemon served JavaScript from a different build" unless HQ::RemoteUI.js == loaded_js
        abort "running daemon changed its asset version after startup" unless HQ::RemoteUI.asset_version == loaded_version
      RUBY
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        "-I#{File.join(dir, "lib")}",
        "-e",
        script
      )
      return if status.success?

      raise "asset snapshot regression failed: #{[stdout, stderr].join.strip}"
    end
  end
end

RemoteUIAssetSnapshotTest.run! if $PROGRAM_NAME == __FILE__
