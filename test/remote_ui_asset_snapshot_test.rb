# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

module RemoteUIAssetSnapshotTest
  module_function

  ROOT = File.expand_path("..", __dir__)

  def run!
    assert_initial_loading_shell_contract
    assert_loaded_daemon_keeps_one_asset_build
    assert_delegation_ui_uses_typed_safe_references
    assert_delegation_callbacks_are_chronological_events
    assert_archived_agents_are_reference_only_and_read_only
    assert_personal_assistant_is_chat_first
    assert_agent_status_icons_use_lucide_without_badges
    puts "remote_ui_asset_snapshot_test: ok"
  end

  def assert_personal_assistant_is_chat_first
    javascript = File.read(File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.js"))
    css = File.read(File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.css"))
    required_javascript = [
      'function renderPersonalAssistantProposal(proposal)',
      'data-proposal-id=',
      'data-proposal-run=',
      'Action ready',
      'Technical details',
      'data-confirm-pa-proposal=',
      'data-reject-pa-proposal=',
      'personal-assistant-start-form',
      'What would you like to move forward?',
      'pendingPersonalAssistantProposalIds: new Set()',
      'state.pendingPersonalAssistantProposalIds.has(id)',
      'class="pa-tycho-nav"',
      'aria-label="Go to Tycho agents"',
      'src="/remote-logo.png?v=${escapeAttr(document.documentElement.dataset.assetVersion || "")}"'
    ]
    missing = required_javascript.reject { |fragment| javascript.include?(fragment) }
    raise "missing chat-first Personal Assistant contract: #{missing.join(", ")}" unless missing.empty?

    forbidden = ['aria-label="Action proposals"', '<h2>Action proposals</h2>', 'JSON.stringify({ type: proposal.type']
    present = forbidden.select { |fragment| javascript.include?(fragment) }
    raise "Personal Assistant still exposes permanent proposal clutter: #{present.join(", ")}" unless present.empty?

    required_css = [
      '.personal-assistant-page { display: grid; grid-template-rows: 56px minmax(0, 1fr) auto;',
      '.pa-conversation-scroll { min-height: 0; overflow-y: auto;',
      '.pa-composer-row',
      'env(safe-area-inset-bottom, 0px)'
    ]
    missing_css = required_css.reject { |fragment| css.include?(fragment) }
    raise "missing chat-first layout contract: #{missing_css.join(", ")}" unless missing_css.empty?
  end

  def assert_initial_loading_shell_contract
    template = File.read(File.join(ROOT, "lib", "hq", "remote_ui", "templates", "index.html.erb"))
    javascript = File.read(File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.js"))

    required_template = [
      'id="tycho-boot-shell"',
      'data-state="loading"',
      'role="status"',
      'aria-live="polite"',
      'class="tycho-boot-mark"',
      'id="tycho-boot-particles"',
      '.tycho-boot-particle',
      '@keyframes tycho-boot-particle',
      'rotate(360deg)',
      'animation: tycho-boot-orbit 2s ease-in-out infinite',
      '0%, 25% { transform: rotate(0deg); }',
      '@media (prefers-reduced-motion: reduce)',
      'id="app" class="app-shell" aria-busy="true"',
      'href="/manifest.webmanifest?v=<%= HQ::RemoteUI.asset_version %>"'
    ]
    missing_template = required_template.reject { |fragment| template.include?(fragment) }
    raise "missing initial loading shell contract: #{missing_template.join(", ")}" unless missing_template.empty?
    forbidden_template = [
      'class="tycho-boot-title"',
      'id="tycho-boot-message"',
      'id="tycho-boot-retry"'
    ]
    present_template = forbidden_template.select { |fragment| template.include?(fragment) }
    raise "text remains in initial loading shell: #{present_template.join(", ")}" unless present_template.empty?

    required_javascript = [
      "const BOOT_TIMEOUT_MS = 15_000;",
      "const count = 3 + Math.floor(Math.random() * 3);",
      "randomBootParticleValue(104, 184)",
      "randomBootParticleValue(4.5, 10.5)",
      "randomBootParticleValue(100, 200)",
      "function emitBootParticles()",
      "function stopBootParticles()",
      "particle.addEventListener(\"animationend\"",
      "stopBootParticles();",
      "emitBootParticles();",
      "function bootNetworkFailure(error)",
      "error?.bootFailureKind === \"offline\"",
      "error instanceof TypeError",
      "function scheduleBootTimeout()",
      "bootError(\"The server is taking longer than expected.\", \"timeout\")",
      "function dismissBootShell()",
      "function failBootShell(error)",
      "if (error.status === 401) dismissBootShell();",
      "else failBootShell(error);",
      "scheduleBootTimeout();",
      "window.addEventListener(\"offline\"",
      "window.addEventListener(\"online\""
    ]
    missing_javascript = required_javascript.reject { |fragment| javascript.include?(fragment) }
    raise "missing loading shell lifecycle contract: #{missing_javascript.join(", ")}" unless missing_javascript.empty?
  end

  def assert_agent_status_icons_use_lucide_without_badges
    javascript = File.read(File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.js"))
    css = File.read(File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.css"))
    helpers = File.read(File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app_helpers.js"))
    required = [
      "pause:",
      "check:",
      "ban:",
      "messageSquareDot:",
      "sportShoe:",
      '<rect width="4" height="16" x="14" y="4" rx="1"></rect>',
      '<path d="M20 6 9 17l-5-5"></path>',
      '<path d="m4.9 4.9 14.2 14.2"></path>',
      '<path d="M12.7 3H4a2 2 0 0 0-2 2v16.286a.71.71 0 0 0 1.212.502l2.202-2.202A2 2 0 0 1 6.828 19H20a2 2 0 0 0 2-2v-4.7"></path>',
      '<circle cx="19" cy="6" r="3"></circle>',
      '<path d="m15 10.42 4.8-5.07"></path>',
      'return "pause"',
      'return "check"',
      'return "ban"',
      'case "unread":',
      'return "messageSquareDot"',
      'case "running":',
      'return "sportShoe"',
      'case "awaiting-input":',
      'case "input-required":',
      'case "input_required":',
      'return "badgeQuestionMark"',
      'case "no_action_needed":',
      'case "partial":',
      'case "idle":',
      "function agentListStatusIcon(agent)",
      "const statusIcon = agentListStatusIcon(agent);",
      "function renderNow()",
      "const unreadSection = unread.length > 0",
      "const runningSection = running.length > 0",
      'label: "Scheduled agent", role: "scheduled"',
      ".agent-status-icon.done",
      ".agent-status-icon.running",
      ".agent-status-icon.fail",
      ".resource-stale :is(.agent-status-icon, .status-mark, .ui-status, .server-identity-badge)",
      "color: var(--muted);",
      "color: var(--accent);",
      'normalizedStatus === "unread" || inquiryStatus ? "need"',
      'normalizedStatus === "running" ? "running"',
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
    raise "status icon renderer must not emit visible status text" if icon_renderer.include?("escapeHtml(label)")

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
